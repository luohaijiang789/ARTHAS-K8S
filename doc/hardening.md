# 加固场景处理

这是项目的核心技术含量。企业级加固 K8s 下，"用容器自己的 java 跑 arthas"的假设大面积失效，本项目要解决的就是"在加固环境下还能把 arthas 送进真实 JVM"。

## 加固矩阵

每一条加固都对 attach 有具体影响。`probe-k8s.sh` 探的就是这些：

| 加固项 | 探测方法 | 对 attach 的影响 | 处理 |
|---|---|---|---|
| distroless（无 shell） | `command -v bash/sh/ash` | exec 模式废（没法 `kubectl exec -- sh`） | 路径 C（ephemeral 容器有 shell） |
| JRE-only（无 attach API） | `lib/tools.jar`(8) / `bin/jcmd`(9+) | 容器 java 跑不起 arthas（缺 attach 模块） | **有 shell→路径 A fallback 传完整 JDK**；无 shell（distroless）才路径 C |
| readOnlyRootFilesystem | Pod spec `securityContext` | /tmp 写不了，cp 的工具落不了地 | **参与选路**：true→路径 C（临时容器 rootFS 可写）；false/未设→路径 A |
| runAsNonRoot / runAsUser | Pod spec `securityContext` | 非 root 读 /proc、文件权限受限 | 路径 C 用 `--profile=sysadmin` 提权读 /proc |
| 禁 attach 参数 | command/args 查 `-XX:+DisableAttachMechanism` | 应用层禁，attach 直接被拒 | 只能重启去参数（blocked） |
| 准入禁 ephemeral | 试探性 `kubectl debug` | 路径 C 也废 | 无 shell / 只读 rootFS 时退回 exec-direct 标风险；否则协调准入或重启改镜像（blocked） |

## 路径决策

probe 综合 6 项给出三类建议。**优先 exec-direct**——有 shell + rootFS 可写就走 exec，JRE-only 靠 fallback 传本地 JDK，不必起 ephemeral。只有无 shell（distroless）或 readOnlyRootFS 才退到 ephemeral：

```
禁 attach 参数?
  └─ 是 → blocked（重启去参数，脚本帮不了）
无 shell（distroless）?
  ├─ ephemeral 允许 → ephemeral-container（路径 C）
  └─ ephemeral 禁   → blocked（重启改镜像）
有 shell + readOnlyRootFS?
  ├─ ephemeral 允许 → ephemeral-container（路径 C，临时容器 rootFS 可写）
  └─ ephemeral 禁   → exec-direct（标风险：/tmp 写不了，attach socket 可能失败）
有 shell + rootFS 可写 → exec-direct（路径 A）
  ├─ 容器有 JDK    → 用容器自己的 java 跑 arthas-boot
  └─ 容器是 JRE/无 → fallback 传匹配本地 JDK 进去跑（JRE 缺 attach API）
```

- **exec-direct**：有 shell + rootFS 可写 + 未禁 attach → 路径 A。容器有 JDK 用容器 java；JRE-only / 无 java 靠 fallback 传匹配本地 JDK（**JRE 也要走 exec，不推 ephemeral**——JRE 缺 attach API，但传完整 JDK 进去就能 attach）
- **ephemeral-container**：无 shell（distroless）或 readOnlyRootFS，且 ephemeral 允许 → 路径 C，外部传 JDK
- **blocked**：应用层禁 attach；或无 shell / readOnlyRootFS 且 ephemeral 被禁 → 协调重启改镜像/参数（脚本帮不了，要改部署）

> **为什么 JRE-only 不推 ephemeral**：JRE 缺 attach API（8 无 `tools.jar`、9+ 无 `jdk.attach` 模块），用 JRE 的 java 跑 arthas 会失败——但只要容器有 shell，传一个完整的匹配 JDK 进去跑就行，不必起 ephemeral。ephemeral 的成本（残留 `debugger-XXXX`、需 sysadmin profile、受限集群常被拒）只在该花时才花：无 shell 时。

## 架构判定（确保 arm/x86 不混）

传本地 JDK 进容器时，JDK 架构必须等于目标节点架构，否则容器内跑不起来（x64 二进制在 arm 节点上 `exec format error`）。

### 归一规则

脚本统一归一为两类目录名：

```
amd64 / x86_64  →  x64       （选 jdk/jdk-<v>-x64/）
arm64 / aarch64 →  aarch64   （选 jdk/jdk-<v>-aarch64/）
```

两脚本选本地 JDK 时只认 `x64` / `aarch64` 这两个归一后的值，杜绝中间状态。

### 优先级

**路径 C**（最可靠）：
1. 节点 `kubernetes.io/arch` label —— K8s 权威值，节点注册时写死，几乎不会错
2. label 缺失才用临时容器 `uname -m` 兜底

**路径 A**：容器内 `uname -m`（容器架构 = 节点架构，因为容器跑在节点上）

### 为什么节点 label 最可靠

`uname -m` 在容器里返回的是**节点内核架构**（容器共享节点内核），理论上等价于节点 label。但两种边角情况会让 uname 失败或失真：
- distroless 无 `uname` 二进制（路径 A 探测会失败）
- 某些多架构节点或虚拟化层 uname 返回值不规范

节点 label 是 K8s 调度依据（Pod 只会被调到 arch 匹配的节点），是架构的**权威来源**。所以路径 C 优先用它。

## 版本探测（三道降级）

**这是路径 C 的命门**。跑 boot 的 JDK 必须和目标 JVM 同 major 版本（见 [为什么多版本](../Readme.md#为什么需要多版本--双架构-jdk)），版本探测错了 → 用 17 attach JDK8 会失败。

路径 A fallback 和路径 C 都用三道探测，**都不执行目标 java**（执行目标 java 在跨容器场景常因动态库缺失失败）：

### 道次 ①：release 文件（最可靠）

```
/proc/<target_pid>/root/<javahome>/release
```

- `/proc/<pid>/root` 是 Linux process namespace 共享 + sysadmin profile 后，临时容器看到的**目标容器 rootfs**
- `<javahome>/release` 是 JDK/JRE 自带的纯文本元数据文件，含 `JAVA_VERSION="17.0.20"` 这样的字段
- 纯 `cat` 读文本，不执行任何二进制，跨容器不依赖目标动态库
- **覆盖**：完整 JDK、完整 JRE 都有 release 文件

提取：`awk -F= '/^JAVA_VERSION=/{gsub(/"/,"",$2);print $2;exit}'`

### 道次 ②：class major version（jlink 兜底）

**问题**：Spring Boot 3 常用 `jlink` 生成最小定制运行时，**没有 release 文件**。道次 ① 失效。旧实现会静默误判默认 17 → 用 17 attach JDK8 失败。

**方案**：从目标 java 进程的 cmdline 里找 `-jar`/`-cp` 指向的 jar，读里面**第一个 .class 的 major version 字节**：

```
.class 文件格式：magic(4) + minor(2) + major(2) + ...
magic = 0xCAFEBABE
major version 字节偏移 = 6（0 基索引），读 2 字节大端无符号整数
```

major version → JDK 版本映射：

| major | JDK |
|---|---|
| 52 | 8 |
| 55 | 11 |
| 61 | 17 |
| 65 | 21 |

实现（默认 debian:bookworm-slim，脚本探测前 apt-get 装 unzip）：

```sh
fc=$(unzip -Z1 "$jar" 2>/dev/null | grep '\.class$' | head -1)   # 列 jar 内容取首个 class
mj=$(unzip -p "$jar" "$fc" 2>/dev/null | od -An -tu1 -j6 -N2 | awk '{print $1*256+$2}')
```

- `unzip -Z1`：列 jar（zip）里的文件名
- `unzip -p`：提取到 stdout 不落盘
- `od -j6 -N2`：跳过前 6 字节读 2 字节
- 纯读文件，不执行 java，跨容器只要有 /proc 读权限就行

**为什么读首个 class 够**：jar 里所有 class 的 major version 通常一致（同一次编译产物）。首个就代表这个 jar 的编译目标版本，即目标 JVM 的 major。

### 道次 ③：跨 ns 跑 bin -version（最后兜底）

```sh
"$bin" -version 2>&1 | head -1
```

- `$bin` 是目标 java 二进制路径（从 cmdline 取）
- **常失败**：目标 java 在目标容器 rootfs，临时容器里执行它需要目标的动态链接库（libjli.so 等），临时容器可能没有 → `No such file or Directory` 或 segfault（glibc 基镜像能跑本地传的 JDK，但跑目标容器内的 java 仍可能缺其依赖）
- 失败时输出空或报错，外层 case 不匹配 → 走 FALLBACK

### FALLBACK：默认 jdk-17

三道都失败 → 默认 jdk-17，**打日志提示**：

```
版本探测失败（三道均未识别，tgt='UNKNOWN'），FALLBACK 默认 jdk-17；
若 attach 失败请用 --jdk=8|11|17|21 强制
```

选 17 作默认的理由：JDK 17+ 的 arthas 能处理模块化，且 17 是 Spring Boot 3 主流版本，覆盖面最广。**但这是安全网不是正确解**——目标若是 8 仍会失败，所以打日志提示用 `--jdk=` 强制。

### 强制覆盖

`--jdk=8|11|17|21` 跳过自动探测直接指定。适用：
- 探测误判（罕见，但 jlink + 无 jar 读不到时可能）
- 你明确知道目标版本，想省探测时间
- 排查时对照测试

## probe 的试探安全性

probe 第 6 项（ephemeral 是否允许）会**真的创建一个 ephemeral 容器**来试探准入。两个要点：

1. **先查已有 ephemeral**：`spec.ephemeralContainers` 非空时直接判 `yes(已有 N 个)`，不试探——避免在别人正在调试的 pod 上动手脚，也避免重复试探累积残留
2. **试探带 `--profile=sysadmin`**：和实战 attach-ephemeral 一致，避免"probe 不带 profile 判 yes、实战带 profile 被拒"的误判
3. **试探容器不原地删除**：K8s 不允许 patch 删 `spec.ephemeralContainers`（Forbidden），试探容器退出后 spec 字段残留但已 Completed，不影响后续 attach（脚本新建临时容器）。彻底清残留靠 `kubectl delete pod` 重建

批量 probe 百来个服务时，每个被试探的 pod 都会留下一个 Completed 的 `debugger-XXXX` 字段。可能触发 webhook/告警，建议在低峰做、或事后批量 rollout restart 清理。

## 跨容器 attach 的剩余限制

本地 kind 集群已验证跨容器 attach 机制本身可通（glibc debian 临时容器 → distroless 目标 JVM，`sc -d`/`jad`/`getstatic` 全部成功）。剩余待真集群验证：

1. **AttachListener UnixSocket 与 readOnlyRootFS**：arthas attach 走 `/tmp/.attach_pid<pid>` UnixSocket。readOnlyRootFS 目标写不了 /tmp——probe 已把这种情况判路径 C（临时容器 rootFS 可写，socket 写在临时容器）。但若 ephemeral 也被禁、被迫走 exec-direct（probe 会标风险），socket 写不了仍会失败。**空 emptyDir 挂载 /tmp** 能救这种情况（待支持）
2. **`--profile=sysadmin` 可用性**：本地 kind 节点 privileged 全过；受限托管集群（GKE/EKS + PSP/准入）可能禁 sysadmin profile，需放宽或换 nsenter 方式
3. **aarch64 双架构**：本地 x64 测不了，需 ARM 节点（如 Oracle Cloud 免费 ARM）
