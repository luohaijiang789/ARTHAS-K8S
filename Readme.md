# Arthas-K8s

**用 Arthas 在运行时实证确认 Java 微服务的漏洞是否真实可达、真实可触发——不是静态扫代码，是在真实 JVM 上看真相。**

对自有 K8s 上的 Java 微服务，attach 进真实运行的进程，看到的是**真实加载的代码、真实配置、真实数据流**：
- `jad`/`sc -d` 线上实际加载的字节码（补丁到底生效没，不是源码仓库说了算）
- `watch`/`trace` 污点是否真流到 sink、鉴权 filter 实际走哪条分支
- `getstatic` 运行时开关、硬编码 key（静态看不到的动态配置）
- `ognl`/`redefine` 动态触发 PoC、打补丁验证修复
- `heapdump` 内存里泄露的凭据 / 未脱敏 PII

## 定位

夹在两类安全工具中间，专做"实证确认"这一步：

| 工具 | 能力 | 局限 |
|---|---|---|
| 静态审计（tabby/CodeQL） | 找嫌疑路径 | 回答不了"实际加载哪个版本""运行时开关""filter 真走哪条""污点真到了没"，误报多 |
| 常驻 IAST agent（DongTai） | 运行时追踪 | 改部署、长期 hook、侵入重 |
| **本项目** | **临时 attach、零侵入、看完即走** | 需目标 pod 可 attach（本工具负责解决这个前置） |

**作用对象**：自有 Java 微服务（Spring Boot / 自研 / 二开），跑在 K8s 上，自查漏洞。
**授权范围**：自有服务 / 自建测试环境，合法的防御性安全工作。

---

## 目录

- [快速开始](#快速开始)
- [目录结构](#目录结构)
- [版本与校验](#版本与校验)
- [为什么需要多版本 + 双架构 JDK](#为什么需要多版本--双架构-jdk)
- [加固场景如何处理](#加固场景如何处理)
- [attach 失败排查](#attach-失败排查)
- [路线图](#路线图)

> 📖 **深入文档**见 [doc/](doc/README.md)：架构设计、脚本内部机制、加固字节级处理、arthas 漏洞验证实战、排查手册、扩展路线。本 Readme 是精炼门面，doc/ 讲透每个部分。

---

## 快速开始

企业级加固环境不能假设 attach 路径——distroless 无 shell、JRE-only 无 attach API、readOnlyRootFS、非 root、`-XX:+DisableAttachMechanism`、准入禁 exec/ephemeral……任何一条都让"用容器 java 跑 arthas"失效。**流程：装底座 → 摸底 → 按结果选路**。

### 1. clone + 装底座

```bash
# SSH（已配 GitHub SSH key）
git clone git@github.com:luohaijiang789/ARTHAS-K8S.git
# 或 HTTPS（无需 SSH key）
git clone https://github.com/luohaijiang789/ARTHAS-K8S.git
cd ARTHAS-K8S
bash tools/fetch.sh
```

`fetch.sh` 幂等下载 arthas 4.3.4 + 8 个 JDK（4 版本 × 2 架构），全部 sha256 + ELF 架构双确认，解压生成 `MANIFEST.txt`。重跑只补缺失、可更新 patch 版本。

**装完自检**：
```bash
cat tools/MANIFEST.txt                                    # 10 行清单（arthas 2 + JDK 8）
for v in 8 11 17 21; do tools/jdk/jdk-$v-x64/bin/java -version 2>&1 | head -1; done
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar   # 起本机 arthas 验证（路径 B）
```
看到 arthas 横幅（自报 4.3.3，功能为 4.3.4）即底座就绪。

**依赖**：`curl tar unzip jq sha256sum readelf`（启动时自检，缺失即报具体名）。K8s attach 另需 `kubectl` 且能访问目标集群。

> 底座约 **3.7G**，不入 git（见[目录结构](#目录结构)）。clone 后 `fetch.sh` 重建。

> 🧪 **没有自有 K8s 集群？** 仓库自带 `lab/` 测试环境：一个 kind 单节点集群 + 4 个 Spring Boot 靶机 pod（覆盖正常/distroless/JRE-only/只读 4 种加固形态），`kind`/`docker` 装好即可一键起，照本 Readme 跑通 probe + 路径 A/C 全流程。见 [`lab/README.md`](lab/README.md)。

### 2. 摸底加固情况（必做）

```bash
bash tools/probe-k8s.sh <pod-flag>             # 摸底匹配的 Running pod
bash tools/probe-k8s.sh <pod-flag> --all       # 含非 Running
bash tools/probe-k8s.sh --csv <pod-flag>       # CSV 清单（百来个服务批量排序）
```

`<pod-flag>` 是定位 pod 的关键字（服务名 / app 标签片段），如 `order-service`。多 pod 命中列出选号。多容器 pod 仅探 `containers[0]`，sidecar 需 attach 时用 `--container=` 指定。

探测 6 项 → 输出每 pod 的建议路径，三类之一：

| 探测项 | 方法 | 判定意义 |
|---|---|---|
| 有无 shell | `command -v bash/sh/ash` | distroless 无 shell → exec 废，必须 ephemeral |
| JDK 还是 JRE | `lib/tools.jar`(8) / `bin/jcmd`(9+) | JRE-only 无 attach API |
| readOnlyRootFS | Pod spec | 只读 → /tmp 写不了 |
| runAsNonRoot/runAsUser | Pod spec | 非 root → /proc 受限 |
| 禁 attach | command/args 查 `-XX:+DisableAttachMechanism` | 应用层禁 → 只能重启去参数 |
| ephemeral 允许 | 试探性 `kubectl debug --profile=sysadmin` 后清理 | 被准入禁 → 两路都断 |

- **exec-direct**：有 shell + JDK + 未禁 attach + rootFS 可写 → 走**路径 A**
- **ephemeral-container**：distroless 或 JRE-only，但 ephemeral 允许 → 走**路径 C**
- **blocked**：ephemeral 被禁 或 应用层禁 attach → 协调重启改镜像/参数

百来个服务摸完得到一张清单，再批量操作。

### 3. 按摸底结果选 attach 路径

#### 路径 A：kubectl exec 直接 attach（exec-direct 的 pod）

```bash
bash tools/attach-k8s.sh <pod-flag>
```

用容器自己的 java 跑 arthas-boot，传 17M dist。流程：选 pod → `uname -m` 识别架构 → 探测容器内 java（`command -v java`，不在 PATH 则从 `/proc/<pid>/cmdline` 找）→ `kubectl cp` 传 dist → 用容器 java 跑 boot。退出 `trap` 清理 `/tmp` 残留。

> 容器无 java 时自动 fallback：三道探测版本 + 传匹配 `jdk-<v>-<arch>` 进去跑（见[加固场景](#加固场景如何处理)）。
> 不强制 root：kubectl 靠 `~/.kube/config`，sudo 反而丢上下文。

#### 路径 B：本机或已知 pid 直接 attach

不走 K8s，目标进程在本机或可直连（本机 x86-64）：
```bash
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar <pid>   # 用与目标同 major 版本的本地 x64 JDK
tools/jdk/jdk-17-x64/bin/java -jar tools/arthas/arthas-boot.jar         # 不带 pid → 列出所有 Java 进程
```

#### 路径 C：kubectl debug 临时容器 attach（加固 pod 主力）

```bash
bash tools/attach-ephemeral.sh <pod-flag>
bash tools/attach-ephemeral.sh <pod-flag> --image=debian:bookworm-slim  # 指定基础镜像（默认即此；须 glibc 系，busybox/alpine 跑不了 JDK）
bash tools/attach-ephemeral.sh <pod-flag> --jdk=17                # 强制 JDK 版本，跳过自动探测
bash tools/attach-ephemeral.sh <pod-flag> --container=sidecar     # 多容器 pod 指定目标容器
```

`kubectl debug --profile=sysadmin` 起最小镜像临时容器，`--target` 共享目标 pod 的 process namespace，`kubectl cp` 把匹配版本+架构 JDK + dist 传进去跑 arthas。**不改目标 pod 正式字段**（ephemeralContainers 是临时字段）。⚠ 临时容器无法原地删除（K8s 不允许 patch `spec.ephemeralContainers`）——退出前请 `stop` 卸载 agent；彻底清残留 `kubectl delete pod` 重建。

前置：K8s ≥ 1.25（ephemeral GA）、准入允许 ephemeral、临时容器镜像节点可达、`--profile=sysadmin` 可用。

### 4. 进 arthas 控制台后——漏洞验证常用命令

```
sc -d <类FQN>                              定位已加载类、ClassLoader、确认线上真实加载的版本
jad <类FQN>                                反编译已加载字节码，看真实运行的代码
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

> ⚠ **ognl / redefine / heapdump 是敏感操作**：能改运行时状态、触发真实逻辑、dump 含凭据的堆。仅在自有/测试环境用。建议先 `watch`/`trace` 观察确认可达，再决定是否 ognl 触发。

> **多人协作**：脚本自动随机端口 + 标记文件自动复用，不用提前商量端口。各跑 attach 脚本即可——同 pod 复用同一 agent（各 session 独立，watch 输出私有），不同 pod 天然隔离。退出 `stop` 释放增强，或 `bash tools/stop-arthas.sh <pod>` 清理。详见 [doc/multi-user.md](doc/multi-user.md)。

---

## 目录结构

```
ARTHAS-K8S/
├── Readme.md                             # 精炼门面
├── .gitignore                            # 排除 3.7G 底座 + 编辑器临时 + reports/
├── doc/                                  # 深入文档（架构/脚本/加固/实战/排查/协作/扩展）
│   ├── README.md                         # 文档索引 + 阅读路径
│   ├── architecture.md                   # 架构与设计
│   ├── scripts.md                        # 脚本内部机制详解
│   ├── hardening.md                      # 加固场景处理（架构判定 + 三道版本探测）
│   ├── arthas-commands.md                # Arthas 漏洞验证实战
│   ├── troubleshooting.md                # 排查手册
│   ├── multi-user.md                     # 多人协作与退出清理
│   └── development.md                    # 扩展与路线图
└── tools/
    ├── fetch.sh                          # 幂等下载/校验/解压，生成 MANIFEST
    ├── probe-k8s.sh                      # 摸底 pod 加固 6 项，判定 attach 路径
    ├── attach-k8s.sh                     # 路径 A：kubectl exec（未加固 pod）
    ├── attach-ephemeral.sh               # 路径 C：kubectl debug 临时容器（加固 pod 主力）
    ├── stop-arthas.sh                    # 清理残留 agent（读标记端口 + -c stop + 删标记）
    ├── MANIFEST.txt                      # 版本 + sha256 清单（fetch 自动生成，版本锚点）
    ├── arthas/                           # [gitignore] arthas 4.3.4 boot.jar + dist/
    ├── jdk/                              # [gitignore] 8 个 JDK：jdk-{8,11,17,21}-{x64,aarch64}
    └── cache/                            # [gitignore] 原始下载包 + 按需生成的 cp 用 tar
```

JDK 8 个（4 版本 × 2 架构）：

| | x64 (x86-64) | aarch64 (ARM64) |
|---|---|---|
| JDK 8 (8u502) | 遗留 Spring Boot 1.x/2.x | 同 |
| JDK 11 (11.0.32) | Spring Boot 2.x 主流 | 同 |
| JDK 17 (17.0.20) | Spring Boot 3.x，模块化封装 | 同 |
| JDK 21 (21.0.12) | Spring Boot 3.2+，虚拟线程 | 同 |

---

## 版本与校验

| 组件 | 版本 | 来源 |
|---|---|---|
| Arthas | 4.3.4 (release) | 阿里云 maven / arthas.aliyun.com CDN |
| JDK 8 / 11 / 17 / 21 | 8u502 / 11.0.32 / 17.0.20 / 21.0.12 | 清华 TUNA / Adoptium Temurin |

> arthas boot 启动横幅自报 4.3.3——release tag 与 jar 内部版本标记不一致，功能为 4.3.4。

完整 sha256 + ELF 架构确认见 [tools/MANIFEST.txt](tools/MANIFEST.txt)。MANIFEST 格式：`组件 版本/架构 ver sha256 文件名`，共 10 行。

**镜像策略**（为下载速度）：
- arthas dist → 阿里云 maven，`.sha256` 走 maven central 校验
- JDK → 清华 TUNA Adoptium 镜像，sha256 用官方 Adoptium API 校验（镜像内容与官方一致）
- `fetch.sh` 内置源回退：JDK 清华 TUNA 失败回退 Adoptium 官方链接（`api.adoptium.net` 返回的 `link`）；arthas sha 源失败降级用已缓存 zip（完整性 `unzip -t` 校验）

**校验强度**：8 个 JDK 均 sha256 + ELF 架构双确认（`readelf Machine` 校验 aarch64）；arthas-boot.jar 与已校验 dist 内的同名 jar 字节比对；json 元数据缓存启动时校验有效性（防 API 限流/错误页缓存中毒）。

---

## 为什么需要多版本 + 双架构 JDK

Arthas attach 时，跑 boot 的 JDK 与目标 JVM 必须匹配，否则：

- **JDK 8 目标**：需 JDK 8 的 `tools.jar`（9+ 已移除），用 17 跑 arthas attach 8 会失败
- **JDK 17/21 目标**：模块化封装（`sun.*` 默认不开放），attach 需 `--add-opens`，arthas 本身要跑在 17+ 上
- **字节码兼容**：`redefine`/`mc` 编译补丁字节码时，编译器版本要 ≥ 目标 class 版本
- **架构匹配**：传本地 JDK 进容器时，架构必须等于目标节点架构，否则跑不起来

规则：**用与目标 JVM 同 major 版本 + 同架构的 JDK 跑 arthas**。
- 路径 A 主路径：用容器自己的 java，版本+架构天然满足
- 路径 A fallback / 路径 C：从 `tools/jdk/jdk-<v>-<arch>/` 选，脚本自动选版本与架构
- 路径 B（本机）：从 `tools/jdk/jdk-<v>-x64/` 选

---

## 加固场景如何处理

这是项目的核心技术含量——不是"会跑 arthas"，是"在加固环境下还能把 arthas 送进去"。

### 架构判定（确保 arm/x86 不混）

脚本统一归一为两类：`amd64`/`x86_64` → `x64`，`arm64`/`aarch64` → `aarch64`。两脚本选本地 JDK 只认这两个目录名。
- 路径 C 优先节点 `kubernetes.io/arch` label（K8s 权威值，几乎不会错），label 缺失才用临时容器 `uname -m` 兜底
- 路径 A 用容器内 `uname -m`（容器架构 = 节点架构）

### 版本探测（三道降级，都不执行目标 java）

路径 A fallback 和路径 C 都用三道探测定目标 JVM 版本：

| 道次 | 方法 | 适用 | 可靠性 |
|---|---|---|---|
| ① | `/proc/<pid>/root/<javahome>/release` 的 `JAVA_VERSION` | 完整 JDK/JRE | 最可靠 |
| ② | 目标 jar 首个 `.class` 的 major version（`unzip -p \| od` 读字节，52=8/55=11/61=17/65=21） | **jlink 定制运行时无 release** | 纯读文件，可靠 |
| ③ | 跨 ns 跑目标 `bin -version` | 最后兜底 | 临时容器缺 libjli 时常失败 |
| 全失败 | **FALLBACK 默认 jdk-17** + 日志提示 `--jdk=` | 安全网 | — |

> **版本探测是路径 C 的命门**：jlink 定制运行时（Spring Boot 3 常见）无 release 文件，旧实现会静默误判默认 17 → 用 17 attach JDK8 失败。② class major version 兜底专治这个。若仍担心误判，`--jdk=8|11|17|21` 可强制。

### 路径选择（probe 摸底决定）

| pod 加固情况 | probe 判定 | 走哪条 |
|---|---|---|
| 有 shell + JDK + 未禁 attach + rootFS 可写 | exec-direct | 路径 A |
| distroless / JRE-only / readOnlyRootFS，但 ephemeral 允许 | ephemeral-container | 路径 C |
| ephemeral 被禁 或 应用层禁 attach | blocked | 协调重启改镜像/参数 |

---

## attach 失败排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `attach fail: tools.jar not found` | 容器是 JRE 不是 JDK（8 需 tools.jar） | 路径 A fallback 自动传匹配 JDK；或走路径 C |
| `Could not find tools.jar` / `No such file` (9+) | JRE 缺 `jdk.attach` 模块 | 同上，传完整 JDK |
| exec 报 `exec: bash: not found` | distroless 无 shell | 走路径 C |
| `attach timed out` | `Unattachable` 或加了 `-XX:+DisableAttachMechanism` | 重启去掉该参数（自管服务可做） |
| aarch64 pod 传本地 JDK | 需匹配架构 | 脚本按节点 arch label / `uname -m` 自动选 aarch64 |
| `kubectl cp` 慢/失败 | tar 缺失或权限 | 脚本按需生成并缓存 tar，确认容器有 tar |
| ephemeral 创建即被拒 | 准入禁 ephemeral | probe 第 6 项提前发现；协调准入或走重启 |
| 版本探测误判（用 17 attach 8 失败） | jlink 无 release 文件 | 三道探测有 class major 兜底；仍误判用 `--jdk=` 强制 |

---

## 路线图

**已实现**：
- ✅ fetch.sh 装底座（sha256 + ELF 双确认、json 防中毒）
- ✅ probe-k8s.sh 摸底 6 项 + 路径建议（CSV + 路径分布汇总）
- ✅ 路径 A：kubectl exec（容器 java + 三道版本探测 fallback）
- ✅ 路径 C：kubectl debug 临时容器（零侵入、三道探测 + class major 兜底）
- ✅ JDK 8/11/17/21 × x64/aarch64 全覆盖
- ✅ 本地 kind 集群试跑（`lab/`）：probe 矩阵 4 形态全命中、路径 A/C 端到端跑通、修 3 个路径 C bug（cp dest 写法 / 默认镜像无 glibc / cleanup patch 死代码）

**待做**：
- [ ] 受限托管集群（GKE/EKS + PSP）试跑 `--profile=sysadmin` 可用性
- [ ] aarch64 双架构真机试跑（本地 x64 测不了，需 ARM 节点）
- [ ] attach-k8s.sh fallback：readOnlyRootFS 走 emptyDir（当前只处理 JRE-only）
- [ ] 批量编排 + 逐类漏洞验证 playbook（probe 清单 → 批量 attach 跑 playbook → 归档报告）——把单条手工 attach 变成百来个服务批量实证闭环
- [ ] tunnel-server 集中管理（零侵入下收益有限，优先级低于批量编排）

---

## License

待定（公开仓库暂未设 LICENSE）。仅限自有服务 / 授权环境做防御性安全工作使用。
