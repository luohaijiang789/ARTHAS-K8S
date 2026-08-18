# 脚本详解

4 个脚本的内部机制、关键实现决策、边界处理。每个脚本先讲做什么，再讲怎么跑，最后讲关键决策的理由（很多决策是踩坑后定的）。

---

## fetch.sh — 装底座

**做什么**：幂等下载 arthas 4.3.4（boot.jar + dist）+ 8 个 JDK（4 版本 × 2 架构），全部校验，解压，生成 MANIFEST。

### 流程

```
依赖检查 → 下 arthas dist zip（sha256 校验）→ 解压 dist
        → 下 arthas-boot.jar（与 dist 内的同名 jar 字节比对）
        → 循环 8 个 JDK：取 Adoptium API 元数据 → 下 tar（sha256 校验）→ 解压 → ELF 架构确认
        → 清理旧 json → 生成 MANIFEST → 自检输出
```

### 关键决策

**依赖检查**（开头）：`curl jq tar unzip sha256sum readelf` 缺一即报具体名退出。旧版无检查，缺失时报原始错不友好。

**json 元数据防中毒**：Adoptium API 结果缓存到 `cache/jdk<v>-<arch>.json`，但**启动时用 `jq -e` 校验有效性**。API 限流/错误页会缓存坏 json → 后续 sha/link 全空 → 下错路径。校验失败自动重拉，仍无效则跳过该 JDK（不静默下错）。

**arthas-boot.jar 交叉校验**：CDN 的 boot.jar 不提供 `.sha256`，maven central 的 arthas-boot artifact 与 CDN fat jar 可能不同构建。改用与**已 sha256 校验的 dist 内的 arthas-boot.jar 字节比对**（`cmp -s`）——dist zip 整体校验过，其内文件可信。不一致时打警告但记录实测 sha。

**sha 源失败降级**：maven central 的 `.sha256` 临时不可达时，`set -e + pipefail` 下旧版会直接退出（即使主 zip 已缓存校验过）。改为 sha 源失败时用缓存 zip + `unzip -t` 完整性检查降级，不阻塞。

**ELF 架构确认**：每个 JDK 解压后 `readelf -h bin/java` 读 `Machine` 字段，校验为预期架构（`Advanced Micro Devices X86-64`→x64 / `AArch64`→aarch64）。sha256 已保证内容正确，ELF 是二次确认（json 错乱下错架构包时 sha 会拦，ELF 兜底）。

**tar 缓存时效**：attach 脚本里 `[ -f X ] || tar -czf` 只在不存在时打包——fetch 升级后旧 tar 仍被复用。改为 `find <src> -newer <tar>`：源比 tar 新就重打。当前 fetch 不直接产 cp 用 tar（attach 脚本按需生成），但同款时效逻辑用在 attach 里。

**清理旧 json**：早期 fetch.sh 用无 arch 后缀的 `jdk8.json` 等，现版用 `jdk<v>-<arch>.json`。末尾清理无 arch 后缀的旧文件，避免混淆。

### MANIFEST 格式

```
arthas  boot      4.3.4               <sha256>
arthas  dist-zip  4.3.4               <sha256>
jdk     8         x64    1.8.0_502-b07  <sha256>  OpenJDK8U-jdk_x64_linux_hotspot_8u502b07.tar.gz
...
```

10 行（arthas 2 + JDK 8），是版本锚点——底座不入 git，MANIFEST 入 git，clone 后 fetch 重建的底座可对照 MANIFEST 确认版本一致。

---

## probe-k8s.sh — 摸底

**做什么**：对每个候选 pod 探 6 项加固条件，输出 attach 路径建议。

### 流程

```
取候选 pod（awk 匹配 ns/pod 名）→ 对每个 pod：
  一次 get pod -o json（jq 提取所有 spec 字段，减少 round-trip）
  一次 exec 探测 shell + java + JDK/JRE（合并，旧版分 3 次）
  试探 ephemeral（带 --profile=sysadmin，已有则跳过）
  → 综合判定路径 → 输出（普通/CSV）+ 路径分布汇总
```

### 关键决策

**awk 取列 + index 子串匹配**（不用 `grep $FLAG`）：`kubectl get po -A -o wide` 输出含 NAMESPACE NAME READY STATUS IP NODE 等列，`grep $FLAG` 匹配整行会误命中 NODE 名或 IP。改用 `awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"'` 只匹配 ns（$1）或 pod 名（$2），且明确限定 STATUS=Running（$4）。

**单次 get pod -o json + jq**：旧版每个字段（rootfs/runAs/command/args）单独 `kubectl get pod -o jsonpath`，每 pod 6+ 次 round-trip。改为一次 `get pod -o json` 存到变量，jq 提取所有字段——每 pod 降到 3 次 round-trip（get json + 合并 exec + ephemeral 试探）。批量摸底快一倍。

**合并 exec 探测**：shell + java 路径 + JDK/JRE 判定合并到一个 `sh -c '...'` 块，输出多行带标记（`shell=`/`java_path=`/`java_kind=`），外层 sed 解析。旧版 3 次 exec。

**JDK/JRE 判定**：
- JDK 8：`<javahome>/lib/tools.jar` 存在
- JDK 9+：`<javahome>/bin` 下有 `jcmd`/`jstack`/`jmap`
- 否则 JRE

**ephemeral 试探安全**：见 [加固处理 · probe 的试探安全性](hardening.md#probe-的试探安全性)——先查已有 ephemeral、带 sysadmin profile、清理只删本次产生。

**路径分布汇总**：旧版号称"路径分布"实际只统计 pod 名计数。改为 `paths[]` 数组 + `sort | uniq -c`，真显示 exec-direct / ephemeral / blocked 各多少。

**多容器 pod 提示**：`containers | length > 1` 时打 warn，提示仅探 containers[0]，sidecar 需 `-c`/`--container=` 指定。

---

## attach-k8s.sh — 路径 A

**做什么**：kubectl exec 模式，用容器自己的 java 跑 arthas-boot，传 17M dist。适用 exec-direct 的 pod。

### 流程

```
依赖检查 → 选 pod（awk 匹配 + 交互）→ tab 分隔取 ns/pod
→ uname -m 识别架构（归一 x64/aarch64）→ trap 清理 /tmp
→ 探测容器 java（command -v，不在 PATH 则 /proc/cmdline 找）
→ cp arthas dist（源比 tar 新则重打）→ 解压
→ 有 java：用容器 java 跑 boot
  无 java：三道探测版本 → cp 匹配 JDK → 用传入 JDK 跑 boot
→ 退出 trap 清理 /tmp 残留
```

### 关键决策

**不强制 root**：旧版强制 root 是历史遗留（旧脚本用 huaweijdk8u272 需 root 挂载）。kubectl 靠 kubeconfig（普通用户 `~/.kube/config`），sudo 反而丢失 KUBECONFIG 连错集群。移除 root 检查，与 attach-ephemeral 一致。

**tab 分隔取 ns/pod**（不用 `set --`）：pod 列表是 `ns\tpod` 格式，`${line%$'\t'*}` 取 ns、`${line#*$'\t'}` 取 pod。旧版 `IFS=$'\n'` 下 `set -- $line` 不分词（空格不是分隔符）会整体塞进 $1——这个 bug 让路径 C 之前完全不可用。

**sh -c 不用 bash -c**：alpine/busybox 等容器无 bash 只有 sh/ash。`bash -c` 在这些容器上失败 → 误走 fallback → 多传 200M JDK。probe 用 `sh -c`，这里对齐。

**/proc/<pid>/cmdline 找 java**：容器 java 不在 PATH 时，遍历 `/proc/[0-9]*/cmdline`，找含 `java` 的进程，取其 argv[0]（二进制路径）。cmdline 是 `\0` 分隔，`tr "\0" " "` 转空格后 `set -- $c; echo $1`。

**三道版本探测 fallback**：容器无 java（JRE-only 或不在 PATH）时，在容器内跑三道探测（release → class major → bin -version，见 [加固处理](hardening.md#版本探测三道降级)）定版本，cp 匹配 `jdk-<v>-<arch>` 进去跑。探测失败默认 17 + 日志。

**/tmp 清理 trap**：`trap cleanup_tmp EXIT` 退出时删容器内 `/tmp/arthas-dist.tar.gz` 和 `/tmp/jdk-fallback.tar.gz`。旧版无清理，可写 FS 残留 200M+。

**数字输入校验**：选 pod 时 `case "$idx" in ''|*[!0-9]*)` 校验是数字，避免非数字输入让 `$((idx-1))` 算术错误 + `set -e` 崩溃。

---

## attach-ephemeral.sh — 路径 C

**做什么**：kubectl debug 起临时容器，共享目标 pod process namespace，cp 匹配 JDK + dist 进去跑 arthas。**加固 pod 主力**。

### 流程

```
依赖检查 → 打包 arthas dist tar → 解析参数（--image/--jdk/--container）
→ 选 pod（awk + tab 分隔）→ 取目标容器名（--target 源）
→ trap 清理 ephemeral
→ kubectl debug --profile=sysadmin --attach=false -- sleep 3600 起临时容器
→ 等临时容器 Running → 取实际 ephemeral 容器名
→ 探测架构（节点 label 优先）→ 三道探测版本
→ 校验本地有对应版本+架构 JDK
→ cp arthas dist + cp 匹配 JDK 进临时容器
→ 临时容器内解压 + 找目标 pid（排除自己）+ exec arthas-boot <pid>
→ 退出 trap 移除 spec.ephemeralContainers
```

### 关键决策

**`-- sleep 3600` 不用 `false "sleep 3600"`**：旧版误写 `-- false "sleep 3600"`——`false` 是命令、忽略参数、返回 1，容器启动即退出，不是 sleep 保活。改为 `-- sleep 3600`（busybox 有 sleep applet）。这个 bug 让路径 C 之前完全不可用。

**`--profile=sysadmin`**：授予读 /proc、ptrace 等，attach 必需。与 probe 试探一致（避免探测和实战判定不一致）。受限集群若禁 sysadmin，需放宽或换 nsenter。

**`--attach=false`**：起容器但不进入，便于随后 kubectl cp。容器命令 `sleep 3600` 保活 1 小时够操作。

**等临时容器 Running**：`kubectl debug --attach=false` 返回后容器可能还在 ContainerCreating。循环 10 次查 `status.ephemeralContainerStatuses[0].state.running`，避免 cp 到未就绪容器失败。

**EPHE_CREATED 守卫清理**：trap 里 `[ "$EPHE_CREATED" = 1 ]` 才清理——避免 debug 创建失败时 trap 还去 patch（可能误操作）。

**架构用节点 label**：见 [加固处理 · 架构判定](hardening.md#架构判定确保-armx86-不混)。节点 `kubernetes.io/arch` 最可靠，label 缺失才 uname 兜底。

**三道版本探测 + 标记行**：探测块输出带标记（`REL:`/`MAJOR:`/裸串），外层 case 解析：
- `REL:*` → release 文件路径，awk 提取 JAVA_VERSION
- `MAJOR:*` → class major version，直接是版本号（8/11/17/21）
- 其他 → bin -version 串

详见 [加固处理 · 版本探测](hardening.md#版本探测三道降级)。

**找目标 pid 排除自己**：临时容器里跑 arthas 的 java 进程也在 /proc 里，cmdline 含 `arthas-boot.jar`。遍历时 `case "$c" in *arthas-boot.jar*) continue` 跳过自己，只 attach目标 java。

**跨容器读 /proc/<pid>/root**：process namespace 共享 + sysadmin 后，临时容器能看到目标容器的进程，`/proc/<target_pid>/root` 指向目标容器的 rootfs。这是道次 ①（release 文件）和 ②（class major）能跨容器读目标文件的基础。

**cp 用 `-c <ephemeral容器名>`**：`kubectl cp <file> <pod>:<ephemeral>:/tmp/x -c <ephemeral>` 指定拷到临时容器（不是默认的 containers[0]）。

### 退出清理

`trap cleanup_ephe EXIT`：退出时 `kubectl patch pod --type=json -p='[{"op":"remove","path":"/spec/ephemeralContainers"}]'`。移除整个 ephemeralContainers 数组——因为本次会话产生的 ephemeral 退出后无意义，且 probe 已保证试探时数组原本为空（本次创建的就是全部）。patch 失败时打手动清理命令。

> **注意**：trap 清理的是 ephemeral 容器，不是目标 JVM 的 arthas agent。路径 C 的 agent 注入目标 JVM，ephemeral 销毁后 agent 仍在——但 4.3.4 下次 attach 会自动复用它（不阻塞）。要做干净释放增强用 `stop`。详见 [多人协作与退出清理](multi-user.md)。

---

## stop-arthas.sh — 清理残留 agent

**做什么**：非交互卸载目标 JVM 的 arthas agent（`-c stop`），释放它残留的增强（watch/trace 拦截、redefine 字节码）。

> **修正一个误区**：4.3.4 实测，残留 agent **不会阻塞下次 attach**——arthas 自动检测已有 agent 并复用。所以 stop-arthas.sh 不是为"解锁端口让下次 attach 能成功"，而是为**干净释放增强 / 强制重置 agent**。残留的 watch/trace/redefine 会延续到下个会话甚至影响服务，stop 才彻底释放。

### 流程

```
选 pod → 探测容器 java + 目标 pid → cp arthas dist → arthas-boot -c stop <pid> → 清理 /tmp
```

### 关键决策

**`-c stop <pid>` 非交互**：与 arthas-boot 官方示例顺序一致（`-h` 里有 `java -jar arthas-boot.jar -c 'sysprop; thread' <pid>`）。实测：default 端口二次 attach 会连到已有 agent 并成功 stop（"Arthas Server is going to shutdown"）。

**仅处理容器有 java 的 pod**（路径 A 风格）：distroless/JRE-only 的 agent 走 `attach-ephemeral.sh` attach 后手动 stop，或重启 pod。

**何时用**：做过 redefine/watch/trace 想干净释放；agent 状态异常想重置；路径 C ephemeral 销毁后清理目标 JVM 的 agent。详见 [多人协作与退出清理](multi-user.md#什么时候必须-stop)。

> ⚠ `-c stop` 清理残留的有效性依赖 arthas 对"attach 到已有 agent 的 JVM"的复用/增强行为。`-c` 执行命令、`stop` 卸载 agent 已是 arthas 标准行为，但跨容器对残留 agent 发 stop 的实际行为需真实环境验证。若 `stop-arthas.sh` 无效，走重启 pod（`kubectl delete pod`）。
