# 加固场景处理

这是项目的核心技术含量。企业级加固 K8s 下，"用容器自己的 java 跑 arthas"的假设大面积失效，本项目要解决的就是"在加固环境下还能把 arthas 送进真实 JVM"。

## 加固矩阵

每一条加固都对 attach 有具体影响。`probe-k8s.sh` 探的就是这些：

| 加固项 | 探测方法 | 对 attach 的影响 | 处理 |
|---|---|---|---|
| distroless（无 shell） | `command -v bash/sh/ash` | exec 模式废（没法 `kubectl exec -- sh`） | 路径 C（ephemeral 容器有 shell） |
| JRE-only（无 attach API） | `lib/tools.jar`(8) / `bin/jcmd`(9+) | 容器 java 跑不起 arthas（缺 attach 模块） | 路径 C 或路径 A fallback（传完整 JDK） |
| readOnlyRootFilesystem | Pod spec `securityContext` | /tmp 写不了，cp 的工具落不了地 | 路径 C（临时容器 rootFS 可写）；路径 A 待支持 emptyDir |
| runAsNonRoot / runAsUser | Pod spec `securityContext` | 非 root 读 /proc、文件权限受限 | 路径 C 用 `--profile=sysadmin` 提权读 /proc |
| 禁 attach 参数 | command/args 查 `-XX:+DisableAttachMechanism` | 应用层禁，attach 直接被拒 | 只能重启去参数（blocked） |
| 准入禁 ephemeral | 试探性 `kubectl debug` | 路径 C 也废 | 协调准入或重启改镜像（blocked） |

## 路径决策

probe 综合 6 项给出三类建议：

```
有 shell?
  ├─ 否 → ephemeral 允许?
  │        ├─ 是 → ephemeral-container（路径 C）
  │        └─ 否 → blocked（重启改镜像）
  └─ 是 → JDK 还是 JRE?
           ├─ JRE/none → ephemeral 允许?
           │             ├─ 是 → ephemeral-container（路径 C，传 JDK）
           │             └─ 否 → blocked（重启换 JDK）
           └─ JDK → 禁 attach?
                     ├─ 是 → blocked（重启去参数）
                     └─ 否 → exec-direct（路径 A）
```

- **exec-direct**：有 shell + JDK + 未禁 attach + rootFS 可写 → 路径 A，用容器自己的 java
- **ephemeral-container**：distroless 或 JRE-only，但 ephemeral 允许 → 路径 C，外部传 JDK
- **blocked**：ephemeral 被禁 或 应用层禁 attach → 协调重启改镜像/参数（脚本帮不了，要改部署）

## 架构判定（确保 arm/x86 不混）

传本地 JDK 进容器时，JDK 架构必须等于目标节点架构，否则容器内跑不起来（x64 二进制在 arm 节点上 `exec format error`）。

### 归一规则

脚本统一归一为两类目录名：

```
amd64 / x86_64  →  x64       （选 tools/jdk/jdk-<v>-x64/）
arm64 / aarch64 →  aarch64   （选 tools/jdk/jdk-<v>-aarch64/）
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

实现（busybox 1.36 含 unzip applet）：

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
- **常失败**：目标 java 在目标容器 rootfs，临时容器里执行它需要目标的动态链接库（libjli.so 等），临时容器（busybox）没有 → `No such file or directory` 或 segfault
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

probe 第 6 项（ephemeral 是否允许）会**真的创建一个 ephemeral 容器再删掉**来试探准入。两个安全措施：

1. **先查已有 ephemeral**：`spec.ephemeralContainers` 非空时跳过试探——避免在别人正在调试的 pod 上动手脚
2. **试探带 `--profile=sysadmin`**：和实战 attach-ephemeral 一致，避免"probe 不带 profile 判 yes、实战带 profile 被拒"的误判
3. **清理只删本次产生**：试探前 `pre_ephe=0` 保证数组原本为空，`remove /spec/ephemeralContainers` 只删本次试探产生的（不会误删他人的会话——因为前提是原本为空才试探）

批量 probe 百来个服务时，每个 pod 都会改一次 spec（创建+删除 ephemeral）。可能触发 webhook/告警，建议在低峰做。

## 跨容器 attach 的剩余限制

即便版本架构都对，跨容器 attach 还有两个只有真实集群能验的点：

1. **AttachListener UnixSocket**：arthas attach 走 `/tmp/.attach_pid<pid>` UnixSocket。临时容器和目标容器共享 process ns 但 rootFS 不同——socket 文件写在**谁的 /tmp**？readOnlyRootFS 目标写不了 /tmp 怎么办？这是待真实集群验证的点
2. **`--profile=sysadmin` 可用性**：受限集群可能禁 sysadmin profile，需放宽或换 nsenter 方式

这两个不在本地能验的范围内，路线图里标了待真实集群试跑。
