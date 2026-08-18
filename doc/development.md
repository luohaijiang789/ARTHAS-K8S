# 扩展与路线图

怎么扩展项目、接下来做什么、为什么某些功能暂缓。

## 扩展：加一个 JDK 版本

比如要加 JDK 23。

### fetch.sh

```sh
for v in 8 11 17 21 23; do   # 加 23
```

Adoptium API 支持 23 就能下。`MANIFEST` 会多 2 行（x64 + aarch64）。

### attach 脚本版本探测

三道探测的版本映射要加 23：

- 道次 ① release 文件：`JAVA_VERSION="23"` → case 加 `*23.*) use_jdk=23`
- 道次 ② class major version：JDK 23 的 major 是 69 → case 加 `69) echo "MAJOR:23"`
- 道次 ③ bin -version：`*23.*` 匹配

两脚本（attach-k8s fallback + attach-ephemeral）都要改。

### 校验

fetch 的 ELF 确认、sha256 自动覆盖。无需额外改。

## 扩展：写漏洞验证 playbook

playbook 是一组 arthas 命令脚本，attach 后用 `arthas-boot -f playbook.as` 非交互执行。

### playbook 格式

`.as` 文件，每行一条 arthas 命令，`#` 注释：

```as
# sqli.as — SQLi 验证
sc -d com.x.OrderService
jad com.x.OrderService createOrder
stack com.x.OrderMapper queryByOrder
watch com.x.OrderMapper queryByOrder '{params}' -x 1
```

### 非交互执行

```
kubectl exec ... -- java -jar /tmp/dist/arthas-boot.jar <pid> -f /tmp/playbook.as
```

`-f` 批量执行脚本，`-c "cmd1\n cmd2"` 执行多条。适合批量取证——不用人盯交互控制台。

### 设计原则

- **只读优先**：playbook 默认用 `sc`/`jad`/`watch`/`trace`/`stack`/`getstatic`（观察类），不碰 `ognl`/`redefine`/`heapdump`（改状态类）
- **触发类单独**：ognl 触发 PoC 的命令单独成 playbook，明确标注风险，手动指定跑
- **可归档**：`-f` 输出重定向到文件，按 `reports/<date>/<ns>-<pod>.log` 归档

## 路线图：批量编排

**核心待做项**。把单条手工 attach 变成百来个服务批量实证闭环。

### 设计

```
probe --csv <flag> → 清单按 path 分类
  → exec-direct 列表：批量 attach-k8s 跑选定 playbook
  → ephemeral 列表：批量 attach-ephemeral 跑 playbook
  → blocked 列表：输出需协调重启的清单
→ 输出归档 reports/<date>/<ns>-<pod>.log
→ 清理（attach 脚本已有 trap）
```

一个 `batch-verify.sh` + `playbooks/` 目录：

```
tools/
├── batch-verify.sh          # probe 清单 → 按 path 批量 attach → 跑 playbook → 归档
└── playbooks/
    ├── sqli.as              # sc/jad 找 DAO → watch execute sink
    ├── deserialization.as   # sc 找 readObject → watch
    ├── auth-bypass.as       # getstatic 鉴权开关 → trace filter
    └── secrets.as           # getstatic 硬编码 key → heapdump（按需）
```

### 为什么用编排不用 tunnel

详见 [tunnel-server 为什么暂缓](#tunnel-server-为什么暂缓)。零侵入约束下，tunnel 的常驻 client 被否决，批量靠编排脚本而非常驻服务。arthas 的 `-f`/`-c` 非交互执行是技术基础（已验证 arthas-boot 支持）。

### 对比 tunnel 的收益

| tunnel 的卖点 | 编排能否达到 |
|---|---|
| 批量 | ✅ 对列表逐个跑，比 Web UI 点选快 |
| 持久会话 | ❌ 但漏洞验证多是"跑一组命令看结果"，不需要长会话 |
| 多人共享 | ✅ 输出归档成报告，比 Web UI 会话更易传阅复现 |
| 审计留痕 | ✅ 脚本日志 + playbook 本身就是审计记录 |
| 跨 pod 对比 | ✅ 同一 playbook 批量跑，输出并排归档 |

唯一换不回的是"实时多人进同一会话"——漏洞验证场景这个需求弱。

## tunnel-server 为什么暂缓

[架构设计](architecture.md#设计哲学零侵入)讲了零侵入哲学。tunnel-server 的两大核心卖点在零侵入约束下直接失效：

- **常驻持久会话** → 被否决（client 常驻 pod 就不是零侵入了）
- **省重复 cp 工具** → 不成立（ephemeral 临时起 client 连 tunnel，每次还是要传 17M dist + 200M JDK）

残值只剩 Web UI / 多人共享 / 留痕。而为这三个搭一个能 attach 任意 pod 的中枢服务（自身高价值目标、要暴露端口、要做访问控制、要运维 HA），代价和收益不成比例。

### client 部署方式的三难

即便要做 tunnel，client 怎么进 pod 是核心问题：

| 方式 | 侵入性 | 问题 |
|---|---|---|
| 打进镜像 | 最高 | 改所有服务 Dockerfile/构建流水线，违背零侵入 |
| init/sidecar 注入 | 中 | 受准入限制（probe 第 6 项探的就是这个，加固集群常拒） |
| ephemeral 临时起 client | 低 | 保留零侵入，但每次还是要 cp 工具，只多 Web UI 层——收益打折 |

第三种是唯一不违背零侵入的，但等于"现有路径 C + Web 前端"，收益不足以支撑 tunnel server 的运维成本。

→ **结论：零侵入下跳过 tunnel，用批量编排替代。** tunnel 留到"长期、多人、批量自查"成熟期且愿意接受常驻 agent 时再考虑。

## 测试方法

项目无自动化测试（shell 脚本 + 真实集群依赖），靠本地模拟 + 真实集群试跑。

### 本地模拟（已做）

- **bash -n**：4 脚本语法检查
- **elf_arch_tag**：8 个 JDK 的 `readelf Machine` 实测
- **探测块端到端**：构造模拟 `/proc/<pid>/root` + release 文件 + jar，跑脚本里的 `sh -c '...'` 探测块，验证三道降级每道正确
- **jq 字段提取**：模拟 pod spec json，验证 jq 提取 + 默认值
- **json 中毒防护**：坏 json 验证 `jq -e` 拦截
- **版本 case 匹配**：各种版本字符串（纯数字、`1.8.0_502`、`openjdk version "..."`、UNKNOWN、空）验证匹配

### 待真实集群验证

本地模拟覆盖不了的（需真 K8s + 真 pod）：

- probe 6 项在常见加固组合下的准确性（尤其 ephemeral 试探清理）
- attach-ephemeral `--profile=sysadmin` 在受限集群可用性
- cp 大 JDK 耗时
- **跨容器 AttachListener UnixSocket 连通性**（attach 机制本身在跨 rootFS 下的行为，本地无法模拟）
- readOnlyRootFS 目标的 attach socket 写位置

这些在路线图标了，需真实加固 pod 试跑。

## 历史

### 旧脚本（arthas 3.6.9 + huaweijdk8u272）

前身是一个简单脚本：选 pod → `uname -m` 二选一预打包 tar（aarch64/x64 的 `arthas-3.6.9_huaweijdk8u272.tar.gz`）→ cp 整包（~100M+）→ 用打包的 huaweijdk8 跑 boot。

**致命局限**：固定用 jdk8 跑 arthas，**目标必须是 JDK8**。jdk9+ 移除 tools.jar、改 jdk.attach 模块、模块化封装——用 jdk8 的 arthas attach 11/17/21 根本起不来。在今天 jdk11/17/21 主流环境下大面积失效。

### 升级（4.3.4 + 多版本双架构）

核心改进：从"固定 jdk8 硬塞"变成"用容器自己的 java（天然匹配目标版本），只在容器没 java 时才传匹配版本+架构 JDK"。

- 目标 JDK：仅 8 → 8/11/17/21 自动匹配
- 跑 boot 的 java：传固定 huaweijdk8 → 容器自己的 java；无 java 才 fallback 传匹配 JDK
- 传输量：~100M+ → ~17M（仅 dist），fallback 才传 JDK
- 架构：仅 x64 → x64 + aarch64
- 加固：不考虑 → probe 摸底 + 路径 C ephemeral

旧脚本在新项目里无残留（依赖的包没了），功能被 `attach-k8s.sh` 完整覆盖并升级。详见 Readme 的路径 A 新旧对比表。
