# 排查手册

按阶段组织症状 → 原因 → 处理。先定位卡在哪一阶段（fetch / probe / attach-A / attach-C），再查对应表。

## 快速定位

| 现象 | 阶段 |
|---|---|
| 装底座失败 / 下载报错 / sha 校验不过 | [fetch](#fetch-阶段) |
| probe 没结果 / 判定不对 / 卡住 | [probe](#probe-阶段) |
| 路径 A attach 失败 | [attach A](#attach-a-阶段) |
| 路径 C ephemeral / cp / attach 失败 | [attach C](#attach-c-阶段) |
| arthas 起来了但命令报错 | [arthas 控制台](#arthas-控制台) |

---

## fetch 阶段

| 现象 | 原因 | 处理 |
|---|---|---|
| `missing dependency: X` | 缺依赖 | 装缺的（`apt install` / `dnf install`） |
| 下载卡住/超时 | 清华镜像或阿里云 maven 不可达 | 重跑（幂等，已下的跳过）；或检查网络代理 |
| JDK json 缓存中毒（jq 报错） | Adoptium API 限流/错误页缓存 | 删 `cache/jdk<v>-<arch>.json` 重跑，fetch 会重拉并校验 |
| `sha256: FAILED` | 下载不完整或镜像内容与官方不一致 | 删 `cache/<file>` 重跑；JDK 的 sha 用官方 Adoptium API 校验，不一致说明镜像有问题，换源 |
| sha 源不可达 | maven central `.sha256` 临时不可达 | fetch 自动降级用缓存 zip + `unzip -t`，不阻塞；确需校验等 sha 源恢复重跑 |
| `ELF 架构(unknown) ≠ 预期` | readelf 读不到 Machine 或包损坏 | 删该 JDK 的 cache tar + jdk 目录重跑；仍异常检查镜像源 |
| aarch64 JDK 本机跑不了 | 本机 x86-64 无法执行 arm 二进制 | 正常，aarch64 靠 sha256 + ELF 确认，不跑 `java -version` |
| MANIFEST 不足 10 行 | 部分 JDK 跳过（json 无效） | 看日志哪几个跳过，重跑补齐 |

## probe 阶段

| 现象 | 原因 | 处理 |
|---|---|---|
| `no pod matched: <flag>` | flag 没匹配到 Running pod | 换 flag 关键字；加 `--all` 看非 Running；确认 kubectl 上下文对 |
| `kubectl not found` / `jq not found` | 缺依赖 | 装缺的 |
| 误命中非目标 pod | flag 太宽（匹配了 ns 名或别的 pod） | 用更独特的 flag（服务名片段）；脚本已限定匹配 $1(ns)/$2(pod) 列不匹配 NODE/IP |
| 多容器 pod 探错容器 | 默认探 containers[0]，目标在 sidecar | 脚本会打 warn；attach 时用 `--container=<name>` 指定 |
| ephemeral 试探触发 webhook 告警 | 试探改 pod spec | 正常行为，低峰跑；已确保不误删他人会话（pre_ephe 检查） |
| probe 判 yes 但实战 ephemeral 被拒 | 试探和实战 profile 不一致 | 已统一带 `--profile=sysadmin`；若仍不一致是集群 profile 策略问题，需放宽 |
| 路径分布汇总为空 | CSV 模式不输出汇总 | 正常，CSV 自己有 path 列可排序统计；普通模式才输出汇总 |
| probe 慢 | 每 pod 3 次 round-trip 串行 | 正常，百来个服务需时间；批量用 `--csv` 导出后筛选 |

## attach A 阶段

| 现象 | 原因 | 处理 |
|---|---|---|
| `kubectl not found` / `arthas dist missing` | 缺依赖或没装底座 | 装依赖 / 跑 `bash tools/fetch.sh` |
| `no running pod matched` | flag 无 Running pod 命中 | 同 probe |
| `exec: bash: not found` | 容器无 bash（alpine/busybox） | 脚本已用 `sh -c`；若仍报说明容器连 sh 都没有（distroless），走路径 C |
| `arch=<X> 未识别，按 x64 处理` | `uname -m` 返回非标准值 | 确认节点真实架构；aarch64 节点被误判 x64 会 attach 失败，用路径 C（节点 label 更可靠） |
| `attach fail: tools.jar not found` | 容器是 JRE 不是 JDK（JDK8） | 脚本自动 fallback 传匹配 JDK；fallback 失败走路径 C |
| `Could not find tools.jar` / `No such file` (9+) | JRE 缺 `jdk.attach` 模块 | 同上，fallback 传完整 JDK |
| `无法识别目标 JVM 版本` 且容器无 java | 三道探测都失败（distroless 无 /proc 信息） | 走路径 C；或确认目标确实有 java 进程 |
| 版本探测误判（用 17 attach 8 失败） | jlink 无 release 文件 + 无可读 jar | 三道探测有 class major 兜底；仍误判用 `--jdk=8` 强制（路径 C 支持，路径 A 需走 C） |
| kubectl 连错集群 | sudo 丢 KUBECONFIG | 不用 sudo；或 `sudo -E` 保留环境；确认 `~/.kube/config` |
| 容器 /tmp 残留 | 旧版无清理 | 已修，`trap` 退出清理；若仍残留手动 `kubectl exec -- rm /tmp/arthas-*` |
| `attach timed out` | `Unattachable` 或 `-XX:+DisableAttachMechanism` | probe 第 5 项应提前发现；需重启去参数（blocked） |

## attach C 阶段

| 现象 | 原因 | 处理 |
|---|---|---|
| `ephemeral 容器未创建` | 准入禁 ephemeral 或镜像拉取失败 | probe 第 6 项应提前发现；检查准入策略、基础镜像节点可达性 |
| ephemeral 创建即退出 | `sleep` 缺失或镜像问题 | 默认 debian:bookworm-slim 有 sleep；若自定义 `--image=` 须含 sleep + glibc |
| `本地缺少 jdk-<v>-<arch>` | fetch 没下对应架构/版本 | 重跑 `bash tools/fetch.sh` 下双架构 8 个 JDK |
| cp 到 ephemeral 失败 | 容器未 Running 或 dest 写法错 | 脚本用 `pod:/tmp/file -c <ephem>` 写法（旧版 `pod:ephem:/tmp` 错误已修）；确认容器 Running |
| `libdl.so.2 not found` / `java 启动即 127` | 基础镜像无 glibc | `--image=` 用了 busybox(scratch) 或 alpine(musl)；须 glibc 系（debian/ubuntu/temurin 基） |
| 版本探测全失败→默认 17 | jlink + 无可读 jar + bin 跑不起来 | 默认 17 是安全网，目标若非 17 会 attach 失败；用 `--jdk=` 强制 |
| 架构误判（x64 传 aarch64 包） | 节点 label 缺失且 uname 失败 | 罕见；脚本会 warn 默认 x64，aarch64 节点用 `--jdk=` 也救不了架构——确认节点 label |
| `--profile=sysadmin` 被拒 | 集群禁 sysadmin profile | 需放宽 profile 或换 nsenter 方式（待支持） |
| 跨容器 attach 失败（socket） | AttachListener UnixSocket 跨 rootFS 问题 | 本地 kind 已验证可通；readOnlyRootFS 目标写不了 /tmp 是子情况，待 emptyDir 支持 |
| ephemeral 容器残留清不掉 | K8s 不允许 patch 删 `spec.ephemeralContainers` | 非故障——彻底清 `kubectl delete pod` 重建；agent 清理靠 `stop` 或 stop-arthas.sh |
| `no target java pid found in /proc` | process namespace 没共享或目标 java 名不匹配 | 确认 `--target` 容器名对；目标 java 进程 cmdline 是否真含 `java` |
| cp 大 JDK 慢 | 200-350M 传输 | 正常，首次慢；后续缓存 tar；网络差考虑换更近调试节点 |

## arthas 控制台

| 现象 | 原因 | 处理 |
|---|---|---|
| `No class found` | 类名错或没加载 | `sc -d *Xxx*` 模糊搜；确认类已加载（未触发加载的类 arthas 看不到） |
| `watch` 没输出 | 方法没被调到 / 条件太严 | 触发请求；放宽条件表达式；确认方法签名对 |
| `jad` 反编译不全 | 编译器优化/内部类/lambda | 正常，看能反编译的部分；内部类用 `jad com.x.Outer$Inner` |
| `ognl` 报 `No such property` | 表式错 / 上下文没该 bean | 先 `sc -d` 确认类，`getstatic` 看可用字段；实例方法要先拿 bean |
| `redefine` 失败 | class 版本不匹配 / ClassLoader 不对 | 用 `mc` 编译时指定正确 ClassLoader；class major 要 ≥ 目标 |
| 命令刷屏 | 高并发服务 | 加条件过滤；`-x` 降深度；看完及时 stop |

## 通用

| 现象 | 处理 |
|---|---|
| 不确定该走哪条路径 | 先 `bash tools/probe-k8s.sh <flag>` 摸底 |
| kubectl 连不上集群 | `kubectl config current-context` 确认上下文；`~/.kube/config` 权限 |
| 底座版本对不上 | `cat tools/MANIFEST.txt` 对照；重跑 `fetch.sh` |
| 权限被拒（非 attach 相关） | 确认 kubeconfig 对应账号有 exec/debug/patch 权限 |
