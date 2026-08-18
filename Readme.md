# Arthas-k8s

运行时漏洞验证工具底座。用 Arthas 对 Java 微服务做远程监控/调试，在**真实部署的代码、真实配置、真实数据流**上确认代码里怀疑的漏洞是否真的可达、真的可触发——不是静态扫代码，而是**运行时实证**。

- **作用对象**：自有 Java 微服务（Spring Boot / 自研 / 二开，约百来个），跑在 K8s 上，自查漏洞
- **授权范围**：自有服务 / 自建测试环境，合法的防御性安全工作
- **覆盖 JDK**：8 / 11 / 17 / 21 × x64 / aarch64 双架构，attach 时自动匹配目标 JVM 的版本与架构

---

## 目录结构

```
Arthas-k8s/
├── Readme.md
└── tools/
    ├── fetch.sh                         # 幂等下载/校验/解压脚本，可重跑更新
    ├── probe-k8s.sh                     # 摸底 pod 加固情况，判定走哪条 attach 路径
    ├── attach-k8s.sh                    # 路径 A：kubectl exec 模式 attach（未加固/轻加固 pod）
    ├── attach-ephemeral.sh              # 路径 C：kubectl debug 临时容器 attach（加固 pod 主力）
    ├── MANIFEST.txt                     # 版本 + sha256 清单（fetch.sh 自动生成）
    │
    ├── arthas/
    │   ├── arthas-boot.jar              # Arthas 启动入口（官方 CDN，~145KB）
    │   └── dist/                        # 完整发布包解压，内含：
    │       ├── arthas-boot.jar              #   启动器
    │       ├── arthas-agent.jar             #   attach agent
    │       ├── arthas-core.jar              #   核心
    │       ├── arthas-spy.jar               #   字节码 spy
    │       ├── arthas-client.jar            #   tunnel client
    │       ├── async-profiler/              #   async-profiler（profiler 命令用）
    │       ├── math-game.jar                #   官方 demo（练习用）
    │       ├── as.sh / install-local.sh     #   启动/安装脚本
    │       ├── arthas.properties            #   默认配置
    │       └── lib/                         #   依赖
    │
    ├── jdk/                             # 8 个 JDK，4 版本 × 2 架构
    │   ├── jdk-8-x64/                    # Temurin 8u502      x86-64   （遗留 Spring Boot 1.x/2.x）
    │   ├── jdk-8-aarch64/                # Temurin 8u502      ARM64
    │   ├── jdk-11-x64/                   # Temurin 11.0.32    x86-64   （Spring Boot 2.x 主流）
    │   ├── jdk-11-aarch64/               # Temurin 11.0.32    ARM64
    │   ├── jdk-17-x64/                   # Temurin 17.0.20    x86-64   （Spring Boot 3.x，模块化封装）
    │   ├── jdk-17-aarch64/               # Temurin 17.0.20    ARM64
    │   ├── jdk-21-x64/                   # Temurin 21.0.12    x86-64   （Spring Boot 3.2+，虚拟线程）
    │   └── jdk-21-aarch64/               # Temurin 21.0.12    ARM64
    │
    └── cache/                           # 原始下载包 + 按需生成的 cp 用 tar
        ├── arthas-bin.zip                   # arthas dist 原始 zip
        ├── arthas-dist.tar.gz               # 按需生成：dist 目录打包，~17M，attach 时 cp 进容器
        ├── jdk-<v>-<arch>.tar.gz            # 按需生成：attach 脚本首次 cp 时打包（源更新自动重打，非预存在）
        ├── OpenJDK*-jdk_*.tar.gz            # JDK 原始下载包（8 个）
        ├── jdk<v>-<arch>.json               # Adoptium API 元数据缓存（fetch 启动校验有效性）
        └── fetch.log                        # 上次 fetch.sh 输出
```

> 工具底座约 **3.7G**：jdk/ 2.3G + cache/ 1.4G + arthas 20M。可随项目整体拷到 K8s 调试节点，不依赖外部 JDK/SDKMAN。

---

## 快速启动 Arthas

企业级加固环境下不能假设 attach 路径——distroless 无 shell、JRE-only 无 attach API、readOnlyRootFS、非 root、`-XX:+DisableAttachMechanism`、准入策略禁 exec/ephemeral……任何一条都让"用容器 java 跑 arthas"失效。**正确流程：先装底座 → 摸底 → 按结果选路**。

### 第 1 步：装好工具底座

```bash
cd Arthas-k8s
bash tools/fetch.sh
```

`fetch.sh` 做的事：下载 arthas 4.3.4（boot.jar + dist）+ 8 个 JDK（4 版本 × 2 架构），全部 sha256 校验，解压到 `tools/arthas/dist/` 和 `tools/jdk/jdk-<v>-<arch>/`，生成 `MANIFEST.txt`。**幂等**：重跑会校验已有下载、跳过完整的、只补缺失的，也能用来更新 patch 版本。

依赖：`curl tar unzip jq sha256sum readelf`（fetch/attach 启动时自检，缺失即报具体依赖名；Kali/Debian 一般自带）。K8s attach 另需 `kubectl` 且能访问目标集群。

**装完自检（确认底座可用）**：

```bash
# 1. 看 MANIFEST 是否 10 行（arthas 2 + JDK 8）
cat tools/MANIFEST.txt

# 2. 4 个 x64 JDK 跑 java -version（aarch64 本机非 arm 只能靠 ELF/sha256 确认）
for v in 8 11 17 21; do tools/jdk/jdk-$v-x64/bin/java -version 2>&1 | head -1; done

# 3. 本机起 arthas（路径 B，不需要 K8s，验证 arthas-boot 能正常加载）
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar   # 不带 pid 会列出本机 Java 进程
```

第 3 步看到 arthas 横幅（自报 4.3.3，功能为 4.3.4）和进程列表即底座就绪。

### 第 2 步：摸底加固情况（必做）

`tools/probe-k8s.sh` 对每个候选 pod 探测 6 个条件，输出每 pod 的 attach 路径建议：

```bash
bash tools/probe-k8s.sh <pod-flag>             # 摸底匹配的 Running pod
bash tools/probe-k8s.sh <pod-flag> --all       # 含非 Running
bash tools/probe-k8s.sh --csv <pod-flag>       # CSV 清单（百来个服务批量排序筛选）
```

`<pod-flag>` 是能定位目标 pod 的关键字（服务名 / app 标签片段），如 `order-service`。多 pod 命中会列出让你选号。多容器 pod 仅探 `containers[0]`，sidecar 需 attach 时用 `--container=` 指定。

探测项与判定：

| 探测项 | 方法 | 判定意义 |
|---|---|---|
| 有无 shell | `command -v bash/sh/ash` | distroless 无 shell → exec 模式废，必须 ephemeral |
| JDK 还是 JRE | 查 `lib/tools.jar`(JDK8) / `bin/jcmd`(9+) | JRE-only 无 attach API |
| readOnlyRootFilesystem | Pod spec `securityContext` | 只读 → /tmp 写不了，cp 要换 emptyDir |
| runAsNonRoot / runAsUser | Pod spec `securityContext` | 非 root → /proc 读取、文件权限受限 |
| 是否禁 attach | command/args 查 `-XX:+DisableAttachMechanism` | 应用层禁 attach → 只能重启去参数 |
| ephemeral 是否允许 | 试探性 `kubectl debug` 后清理 | 被准入禁 → 两条路都断，需重启改镜像 |

每 pod 输出 `→ 建议路径`，三类之一：

- **exec-direct**：有 shell + JDK + 未禁 attach + rootFS 可写 → 走**路径 A**
- **ephemeral-container**：distroless 或 JRE-only，但 ephemeral 允许 → 走**路径 C**
- **blocked**：ephemeral 被禁 或 应用层禁 attach → 协调重启改镜像/参数

百来个服务摸完，得到一张「哪些直接 attach、哪些要 ephemeral、哪些要重启」的清单，再批量操作。

### 第 3 步：按摸底结果选 attach 路径

#### 路径 A：kubectl exec 直接 attach（适用 exec-direct 的 pod）

`tools/attach-k8s.sh` —— 交互选 pod、用容器自己的 java 跑 arthas-boot、传 17M dist。

```bash
bash tools/attach-k8s.sh <pod-flag>
```

流程：依赖检查 → 选 pod → `uname -m` 识别架构（归一为 `x64`/`aarch64`）→ 探测容器内 java（`command -v java`，不在 PATH 则从 `/proc/<pid>/cmdline` 找）→ `kubectl cp` 传 arthas dist（17M）→ 用容器 java 跑 `arthas-boot.jar`。退出时 `trap` 清理容器内 `/tmp` 残留。

> 不再强制 root：kubectl 靠 `~/.kube/config`，sudo 反而丢失 KUBECONFIG 连错集群。

> 容器无 java 在 PATH 时（JRE-only 或 java 不在 PATH），脚本自动 fallback：在容器内用三道探测（release → class major version → bin -version，与路径 C 同款）定目标版本，`kubectl cp` 传匹配 `jdk-<v>-<arch>` 进去跑。探测失败默认 jdk-17（打 FALLBACK 日志）。distroless（无 shell）不适用本路径，走路径 C。

> ⚠ **仅适用 probe 判定 exec-direct 的 pod**。加固 pod（distroless/JRE-only/readOnlyRootFS/禁 attach/准入禁 exec）走路径 C 或重启。此路径升级自旧版 arthas 3.6.9 + 单 JDK8 脚本，覆盖范围相同（未加固/轻加固 pod），不是加固环境主力。

| 维度 | 旧脚本 (3.6.9) | attach-k8s.sh (4.3.4) |
|---|---|---|
| 目标 JDK | 仅 8 | 8/11/17/21 自动匹配 |
| 跑 boot 的 java | 传固定 huaweijdk8u272 | 容器自己的 java（版本架构天然对） |
| 传输量 | ~100M+（JDK+arthas） | ~17M（仅 arthas dist），fallback 时才传 JDK |
| 架构 | 仅 x64 | x64 + aarch64（fallback 按 `uname -m` 选） |
| 加固适用性 | 不适用加固 pod | 同样不适用加固 pod（需先 probe） |

#### 路径 B：本地或已知 pid 直接 attach

不走 K8s，适合目标进程在本机或可直连的场景（本机 x86-64）：

```bash
# 用与目标 JVM 同 major 版本的本地 x64 JDK 跑 arthas-boot
tools/jdk/jdk-8-x64/bin/java  -jar tools/arthas/arthas-boot.jar <pid>
tools/jdk/jdk-11-x64/bin/java -jar tools/arthas/arthas-boot.jar <pid>
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar <pid>
tools/jdk/jdk-21-x64/bin/java -jar tools/arthas/arthas-boot.jar <pid>

# 不带 pid → arthas 列出所有 Java 进程让你选
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar
```

#### 路径 C：kubectl debug 临时容器 attach（加固场景主力）

`tools/attach-ephemeral.sh` —— `kubectl debug` 起最小基础镜像的临时容器，通过 `--target` 共享目标 pod 的 process namespace，`kubectl cp` 把匹配版本+架构 JDK + arthas dist 传进去跑 arthas-boot。不改目标 pod、退出自动清理。

```bash
bash tools/attach-ephemeral.sh <pod-flag>
bash tools/attach-ephemeral.sh <pod-flag> --image=alpine:3.20   # 指定基础镜像（默认 busybox:1.36）
bash tools/attach-ephemeral.sh <pod-flag> --jdk=17               # 强制 JDK 版本，跳过自动探测
bash tools/attach-ephemeral.sh <pod-flag> --container=sidecar    # 多容器 pod 指定目标容器（默认 containers[0]）
```

不依赖预制调试镜像：临时容器用 `busybox`/`alpine` 等轻量镜像，工具按需 cp 传入（arthas dist ~17M + 单个匹配 JDK ~200-350M）。流程：

1. 选 pod、取目标容器名（`--target` 源，共享 process ns）
2. `kubectl debug --image=busybox --target=<容器> --profile=sysadmin --attach=false` 起临时容器，`sleep 3600` 保活
3. **探测目标架构**：节点 `kubernetes.io/arch` label（最可靠），兜底临时容器 `uname -m` → 归一为 `x64` / `aarch64`
4. **探测目标 JVM 版本（三道降级，都不执行目标 java）**：
   - ① `/proc/<pid>/root/<javahome>/release` 的 `JAVA_VERSION` —— 完整 JDK/JRE 有，最可靠
   - ② 目标 jar 里首个 `.class` 的 major version（`unzip -p | od` 读字节，52=8/55=11/61=17/65=21）—— **jlink 定制运行时无 release 文件时的兜底**
   - ③ 跨 ns 跑目标 `bin -version` —— 最后兜底，临时容器缺目标 libjli 时常失败
   - 三道都失败 → **FALLBACK 默认 jdk-17**（打日志提示，建议 `--jdk=` 强制）
5. 按架构+版本选本地 JDK（`jdk-<v>-<arch>`，8/11/17/21 × x64/aarch64，可 `--jdk=` 强制版本）
6. `kubectl cp` 传 arthas dist + 匹配架构版本 JDK 进临时容器
7. 在临时容器里解压、用传入的 JDK 跑 `arthas-boot.jar <target_pid>`
8. 退出后 `kubectl patch` 移除 `spec.ephemeralContainers`（trap EXIT 自动清理）

前置条件：

- K8s ≥ 1.25（ephemeral container GA）
- 准入允许 ephemeral（probe 第 6 项 = yes；若 no 走重启）
- 临时容器基础镜像在集群节点可达（busybox/alpine 一般已有缓存）
- `--profile=sysadmin` 授予读 `/proc`、ptrace 等（attach 必需）；若集群禁 sysadmin profile，需放宽或换 nsenter 方式

> **架构判定规则（确保 arm/x86 不混）**：脚本统一归一为两类——`amd64`/`x86_64` → `x64`，`arm64`/`aarch64` → `aarch64`。路径 C 优先用节点 `kubernetes.io/arch` label（K8s 权威值，几乎不会错），label 缺失才用临时容器 `uname -m` 兜底。路径 A 用容器内 `uname -m`（容器架构 = 节点架构）。两脚本选本地 JDK 时只认 `x64`/`aarch64` 两个目录名，杜绝 arm 误传 x64 包（反之亦然）。
>
> **版本探测是路径 C 的命门**：jlink 定制运行时（Spring Boot 3 常见）无 release 文件，旧实现会静默误判默认 17 → 用 17 attach JDK8 失败。三道探测里的 ② class major version 兜底专治这个（纯读文件不执行 java）。若仍担心误判，`--jdk=8|11|17|21` 可强制。

### 第 4 步：进 arthas 控制台后——漏洞验证常用命令

```
sc -d <类FQN>                              定位已加载类、ClassLoader、确认线上真实加载的版本
jad <类FQN>                                反编译已加载字节码，看真实运行的代码（不是源码仓库的）
watch <类> <方法> '{params,returnObj,throwExp}'  观察方法入参/返回/异常，确认污点是否流到 sink
  # 例：watch com.x.OrderService createOrder '{params[0],returnObj}' -x 2
trace <类> <方法>                          调用链 + 耗时，看 WAF/鉴权 filter 实际走的哪条分支
stack <类> <方法>                          反向：谁调用了这个 sink，看入口可达性
getstatic <类> <字段>                      读静态字段（鉴权开关、debug 开关、硬编码 key）
ognl '@类@方法(参数)'                       运行时调用任意方法，动态触发 PoC（自己环境内）
heapdump / dump                            dump 堆，找泄露的凭据 / token / 未脱敏 PII
dashboard                                  总览：线程、内存、GC（先看健康度）
thread -b                                  找阻塞线程 / 死锁
```

> ⚠ **ognl / redefine / heapdump 是敏感操作**：能改运行时状态、触发真实逻辑、dump 含凭据的堆。仅在自有/测试环境用；生产自查先评估影响（ognl 调用可能触发真实数据流或副作用，redefine 改字节码有风险）。建议先 `watch`/`trace` 观察确认可达，再决定是否 ognl 触发。

---

## 工具版本

| 组件 | 版本 | 来源 | 说明 |
|---|---|---|---|
| Arthas | 4.3.4 (release) | 阿里云 maven / arthas.aliyun.com CDN | boot.jar + 完整 dist；boot 启动横幅自报 4.3.3（arthas 的 release tag 与 jar 内部版本标记不一致，功能为 4.3.4） |
| JDK 8 | 8u502-b07 | 清华 TUNA / Adoptium Temurin | 遗留 Spring Boot 1.x/2.x。x64 + aarch64 双架构 |
| JDK 11 | 11.0.32+9 | 清华 TUNA / Adoptium Temurin | Spring Boot 2.x 主流。x64 + aarch64 双架构 |
| JDK 17 | 17.0.20+8 | 清华 TUNA / Adoptium Temurin | Spring Boot 3.x，模块化封装。x64 + aarch64 双架构 |
| JDK 21 | 21.0.12+8-LTS | 清华 TUNA / Adoptium Temurin | Spring Boot 3.2+，虚拟线程。x64 + aarch64 双架构 |
| tunnel-server | — | （未下） | 4.3.4 未发布 tunnel-server artifact；最新为 4.0.5，与 client 4.3.4 版本不匹配。待确定走 tunnel 集中管理模式时再决定（降级 client 至 4.0.5，或等 4.3.x tunnel 发布） |

完整 sha256 见 [tools/MANIFEST.txt](tools/MANIFEST.txt)。MANIFEST 格式：`组件  版本/架构  ver  sha256  文件名`，共 10 行（arthas 2 + JDK 8）。

**镜像策略**（为下载速度）：
- arthas dist → 阿里云 maven（~4.5MB/s），其 `.sha256` 阿里云未镜像、走 maven central 校验
- JDK → 清华 TUNA Adoptium 镜像（~3MB/s），sha256 仍用官方 Adoptium API 校验（镜像内容与官方一致）
- `fetch.sh` 内置官方源回退（清华失败回退 GitHub release）

**Smoke test 已通过**：4 个 x64 JDK（jdk-8/11/17/21-x64）各跑 `java -version` 正常。aarch64 4 个 sha256 + ELF 架构确认（`readelf Machine` 校验为 aarch64；本机 x86-64 无法跑 `java -version`）。8 个 JDK 在 fetch 时均做 sha256 + ELF 双确认，json 元数据缓存启动时校验有效性（防 API 限流/错误页缓存中毒）。

---

## 为什么要多版本 + 双架构 JDK

Arthas attach 目标 JVM 时，跑 boot 的 JDK 与目标 JVM 必须匹配，否则：

- **JDK 8 目标**：需 JDK 8 的 `tools.jar`（JDK 9+ 已移除），用 JDK 17 跑 arthas attach 8 的进程会失败
- **JDK 17/21 目标**：模块化封装（`jdk.internal.*`、`sun.*` 默认不开放），attach 需 `--add-opens`，且 arthas 本身要跑在 17+ 上才能正确处理
- **字节码兼容**：`redefine` / `mc`(compiler) 编译补丁字节码时，编译器版本要 ≥ 目标 class 版本
- **架构匹配**：传本地 JDK 进容器时，JDK 架构必须等于目标节点架构（x64 / aarch64），否则容器内跑不起来

规则：**用与目标 JVM 同 major 版本 + 同架构的 JDK 跑 arthas**。

- 路径 A 主路径：用容器自己的 java，版本+架构天然满足
- 路径 A fallback / 路径 C：从 `tools/jdk/jdk-<v>-<arch>/` 选，脚本按 `uname -m` / 节点 `kubernetes.io/arch` 自动选 x64 或 aarch64
- 路径 B（本机）：从 `tools/jdk/jdk-<v>-x64/` 选（本机 x86-64）

---

## attach 失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `attach fail: tools.jar not found` | 容器是 JRE 不是 JDK（JDK8 需 tools.jar） | attach-k8s.sh fallback 自动传匹配版本+架构 JDK；或走路径 C |
| `Could not find tools.jar` / `No such file` (9+) | 容器 JRE 缺 `jdk.attach` 模块 | 同上，传完整 JDK（路径 A fallback / 路径 C） |
| exec 报 `exec: bash: not found` | distroless 镜像无 shell | 走路径 C（ephemeral container） |
| `attach timed out` | 目标进程 `Unattachable` 或加了 `-XX:+DisableAttachMechanism` | 需重启去掉该参数（自管服务可做） |
| aarch64 pod 传本地 JDK | 需匹配架构 JDK | 已下双架构 `jdk-<v>-aarch64`，脚本按节点 arch label / `uname -m` 自动选 |
| `kubectl cp` 慢/失败 | tar 缺失或权限 | 脚本按需生成并缓存 `cache/arthas-dist.tar.gz` + `cache/jdk-<v>-<arch>.tar.gz`，确认容器有 tar |
| ephemeral 创建即被拒 | 准入策略禁 ephemeral | probe 第 6 项会提前发现；需协调准入或走重启 |

---

## K8s 部署模式

从轻到重，按场景选（先用 `probe-k8s.sh` 摸底决定走哪档）：

1. **kubectl exec + arthas dist** — 有 shell + JDK + 未禁 attach 的 pod。**已实现**：[tools/attach-k8s.sh](tools/attach-k8s.sh)（路径 A）。升级自旧版 arthas 3.6.9 + 单 JDK8 脚本。
2. **kubectl debug ephemeral container** — distroless / JRE-only / readOnlyRootFS 的 pod，临时容器 + process namespace sharing attach，不改目标 pod、退出即清理。**加固场景主力**。**已实现**：[tools/attach-ephemeral.sh](tools/attach-ephemeral.sh)（路径 C）。不依赖预制镜像，按需 cp 传工具。
3. **arthas-tunnel-server** — 多服务/长期，Web UI 集中 attach 各 pod。待落地（4.3.4 未发布 tunnel-server，见上）
4. **sidecar / init 注入 agent** — 自动化，改部署模板，侵入性最高，受准入策略限制。待落地

> 加固 pod 的现实：很多企业级服务落在第 2 档（distroless/JRE-only）或需要重启（应用层禁 attach）。第 1 档 `attach-k8s.sh` 只覆盖未加固/轻加固 pod——`probe-k8s.sh` 摸底是必做前置，按结果选 A 还是 C。

---

## 漏洞验证路线（规划）

| 验证目标 | 主用命令 | 状态 |
|---|---|---|
| 污点到达 sink（SQLi/RCE/SSRF/反序列化） | `watch` `trace` | 待落地 |
| 可达性 / 鉴权 filter 分支 | `trace` `stack` | 待落地 |
| 线上代码版本确认（补丁是否生效） | `jad` `sc -d` | 待落地 |
| 运行时配置/开关/硬编码密钥 | `getstatic` `ognl` | 待落地 |
| 内存泄露凭据/PII | `heapdump` | 待落地 |
| 动态 PoC / 修复验证 | `ognl` `redefine` | 待落地 |

---

## 后续

- [ ] probe-k8s.sh 真实集群试跑，验证 6 项探测在常见加固组合下的准确性（尤其 ephemeral 试探的清理）
- [x] attach 跨容器 JDK 版本探测：已实现三道降级（release → class major version → bin -version），jlink 无 release 场景有兜底；FALLBACK 默认 jdk-17 + 日志提示
- [ ] attach-ephemeral.sh 真实加固 pod 试跑：`--profile=sysadmin` 在受限集群可用性、cp 大 JDK 耗时、跨容器 AttachListener UnixSocket 连通性（本地能验的都验了，这三项需真实集群）
- [ ] attach-k8s.sh fallback：readOnlyRootFS 场景走 emptyDir（当前只处理 JRE-only）
- [ ] 逐类漏洞验证 playbook（SQLi / 反序列化 / SSRF / 鉴权绕过）+ 批量编排（probe 清单 → 批量 attach 跑 playbook → 归档）
- [ ] tunnel-server 集中管理部署（零侵入下收益有限，优先级低于批量编排）
