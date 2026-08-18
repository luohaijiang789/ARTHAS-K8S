# 多人协作与退出清理

两三个人一起用 Arthas——**脚本自动随机端口 + 标记文件自动复用，不用提前商量任何东西**。

## 实测结论（arthas 4.3.4）

本地起目标 JVM 实测 arthas 端口与 agent 行为：

```
首次指定 --telnet-port=39287 起 agent        → 成功，agent 绑 39287
已有 agent(39287) + 默认端口 3658 attach      → 失败（client 连 3658，agent 在 39287）
已有 agent(39287) + 指定 39287 attach         → 成功！"already using port 39287, skip attach" 复用
已有 agent(39287) + 指定 41983 attach         → 失败（同 JVM 起不了第二个 agent）
```

**arthas 4.3.4 的真实模型**：
- 同一 JVM **只能有一个 agent**（指定不同端口起第二个会失败，不是起新 agent）
- agent 绑在首次指定的端口，后续 attach **必须用同一端口**才能复用
- arthas **不把端口记录到可发现的地方**（`~/.arthas`、`/tmp`、`/proc` 都没有按 pid 记录端口）

→ 所以"自动复用"需要脚本自己记录端口，让后续用户能发现。本项目的方案：**随机端口 + 标记文件**。

## 路径 C 真集群实测（2026-08-18，kind v1.31 + distroless pod）

上面的端口/agent 行为是本地起 JVM 测的；路径 C（ephemeral 容器 attach distroless/JRE-only）的多用户在真集群首次验证。`lab/app-distroless`（无 shell，纯路径 C）上跑 A/B 两个用户，4 项断言全过：

| 断言 | 结果 | 证据 |
|---|---|---|
| 标记文件跨临时容器持久 | ✅ | A 写 `/proc/1/root/tmp/arthas-port-1=24486`，B 用**全新临时容器**（`debugger-kgkcv` ≠ A 的 `debugger-zddcx`）读到同值 |
| B 复用 A 的 agent（同端口） | ✅ | `reuse arthas agent on port 24486` + `The target process already listen port 24486, skip attach` |
| A quit 后 agent 不销毁 | ✅ | A `quit` 后 B 新建 ephemeral 连同一端口，`getstatic`/`jad` 正常工作 |
| watch 输出 session 私有 | ✅ | A 注册 watch + curl 触发 2 次，A 控制台 4 条命中，B 并发连命中 0 条（同 agent 不同 session） |

**关键差异**：路径 A 标记在容器 `/tmp`，路径 C 标记在**目标容器 rootFS** `/proc/<pid>/root/tmp/`——这是路径 C 能跨临时容器复用的根本（临时容器销毁重建，目标 rootFS 不变）。

### arthas `-c` 非交互模式的坑

自动化测试/脚本里用 `arthas-boot.jar --telnet-port=$PORT -c "cmd1; cmd2; quit" <pid>` 连**已有 agent** 会挂起——`-c` 发完命令不自动退出，`quit` 在 `-c` 里不被处理。两种情况要分清：

- **首次起 agent**：`-c stop` 能用（agent 是新建的，stop 让 agent shutdown，arthas 进程随之退出）
- **复用已有 agent**：`-c` 会卡死，必须用 pty 交互式（`script -qec '... -it ...'` 喂命令 + quit）

`stop-arthas.sh` 的 `-c stop` 能工作是因为它连已有 agent 发 stop（agent shutdown 后 arthas 退出），不是靠 quit。自动化做多人 watch 私有性等测试时，必须 pty 交互式，不能用 `-c`。

### 残留清理

路径 C 多用户每次 attach 留一个 `debugger-XXXX` ephemeral（K8s 不允许原地删 `spec.ephemeralContainers`，见 [troubleshooting](troubleshooting.md)）。多人多次跑会累积，彻底清 `kubectl delete pod` 重建。

## 方案：随机端口 + 标记文件自动复用

```
用户 A 首次 attach：
  /tmp/arthas-port-<pid> 不存在
  → 脚本选随机端口（20000-29999）→ arthas --telnet-port=$PORT 起 agent
  → 写标记文件 /tmp/arthas-port-<pid> = $PORT

用户 B 后续 attach 同一 pod：
  /tmp/arthas-port-<pid> 存在
  → 脚本读出端口 $PORT → arthas --telnet-port=$PORT attach
  → arthas 检测 "already using port $PORT, skip attach" → 连上已有 agent，得新 session

stop 清理：
  stop-arthas.sh 读标记端口 → -c stop 卸载 agent → 删标记文件
```

- **不用提前商量**：脚本自动选随机端口、自动记录、自动复用
- **同 pod 多人**：复用同一个 agent（arthas 单 JVM 单 agent 限制），各 session 独立
- **不同 pod**：各自独立 agent，天然隔离
- 标记文件路径：
  - 路径 A（容器内）：`/tmp/arthas-port-<pid>`
  - 路径 C（目标容器 rootFS，跨临时容器持久）：`/proc/<pid>/root/tmp/arthas-port-<pid>`

## 与 agent 的关系

```
你的终端                          目标 JVM（pod 里）
┌─────────────┐                  ┌──────────────────────────┐
│ arthas-boot │ ──attach 注入──→ │  arthas agent（只有一个） │
│ (客户端)    │                  │  ├─ TelnetServer :随机端口│
│ 你的控制台  │ ←─telnet 连────→ │  ├─ 字节码增强(Advice)    │
└─────────────┘                  │  └─ 多个 session          │
                                 └──────────────────────────┘
```

- 你跑的 arthas-boot 是**客户端**，attach 时把 agent 注入目标 JVM，本地 telnet 连 agent 的端口
- **agent 在目标 JVM 里，只有一个**。你每次连 = agent 给你开一个新 session（独立 SESSION_ID）
- 端口是 agent 的监听口，不是"每人一个"——同 pod 多人连同一个 agent 的同一个端口

## 共享什么、不共享什么（实测）

| 东西 | 共享? | 说明 |
|---|---|---|
| agent 实例（一个） | ✅ | 同 pod 只有一个 |
| telnet 端口 | ✅ | 同一个端口，多人连 |
| 字节码增强 | ✅ | A watch 后方法被插桩，B jad 看到增强后的字节码 |
| **watch/trace 输出** | ❌ | **session 私有**：A 的命中只到 A 控制台，B 看不到（路径 A 本地实测 A 命中 3 次、B 0 次；路径 C 真集群实测 A 4 次、B 0 次，见上节） |
| 控制台/session | ❌ | 各自独立 SESSION_ID |

**关键**：A 跑 `watch` 的命中结果只输出到 A 的控制台，B 看不到。但 A 注册 watch 的字节码增强是 agent 级共享——B 自己也 watch 同方法会叠加 listener，能看到自己的命中。A `stop`/watch 超时后增强移除。

## 两种协作场景

### 场景 1：各自排查不同服务（最常见）

```bash
# 用户 A
bash tools/attach-ephemeral.sh order-service      # 随机端口起 agent
# 用户 B
bash tools/attach-ephemeral.sh payment-service    # 不同 pod，独立 agent
```

不同 pod = 不同 JVM = 不同 agent，完全隔离。各自随机端口，互不干扰。

### 场景 2：多人看同一个服务（协同排查）

```bash
# 用户 A 先 attach
bash tools/attach-ephemeral.sh order-service
# A 进 arthas 控制台（脚本选了随机端口，写了标记）

# 用户 B 也跑同一条命令（不用问 A 任何信息）
bash tools/attach-ephemeral.sh order-service
# B 的脚本读标记文件 → 用 A 的端口 attach → arthas 复用 A 的 agent → B 得独立 session
```

- A、B 各有独立控制台、独立 session
- watch 输出各自私有（A 看不到 B 的，B 看不到 A 的）
- 字节码增强共享（A watch 后 B jad 看到增强字节码；B 自己 watch 叠加 listener 看自己命中）
- 路径 C 同理：A 的 ephemeral 销毁后 agent 仍在 + 标记文件在目标 rootFS，B attach 自动复用

## stop / quit / exit 的区别

| 命令 | 作用 | agent | 标记文件 | 下次 attach |
|---|---|---|---|---|
| `stop` | **完全卸载 agent**，释放增强 | 移除 | stop-arthas.sh 会删 | 全新（新随机端口起 agent） |
| `quit`/`exit` | 退当前 session | 保留 | 保留 | 复用（读标记连同一 agent） |
| Ctrl+C | 退 arthas-boot | 通常保留 | 保留 | 复用 |

- **临时退出、待会还回来**：`quit`（agent 和标记都在，下次复用，增强延续）
- **彻底结束、要干净**：`stop`（卸载 agent，释放增强）；或 `bash tools/stop-arthas.sh <pod>`（非交互 stop + 删标记）
- **agent 状态异常想重置**：`bash tools/stop-arthas.sh <pod>`

## stop-arthas.sh：清理残留 agent + 标记

```bash
bash tools/stop-arthas.sh order-service
```

流程：读标记文件拿端口 → `--telnet-port=$PORT -c stop <pid>` 非交互卸载 → 删标记文件。适用：
- 做过 redefine/watch/trace 想干净释放增强
- agent 状态异常想重置
- 路径 A 的标记端口失效连不上时清理

> **边界**：stop-arthas.sh 只处理**容器有 java 的 pod + 路径 A 标记**（`/tmp/arthas-port-<pid>`）。**路径 C 的标记在 `/proc/<pid>/root/tmp/`（目标容器 rootFS），本脚本清不到**——路径 C 残留清理：用 `attach-ephemeral.sh` 重新 attach（它会读路径 C 标记、复用已有 agent），在 arthas 控制台手动 `stop`；或 `kubectl delete pod` 重启。distroless/JRE-only（容器无 java）同走这两条。

> ⚠ stop-arthas.sh 的 `-c stop` 对残留 agent 的清理有效性，依赖 arthas "attach 到已有 agent 的 JVM 会连上它"——已实测确认（同端口二次 attach 连到已有 agent 并成功 stop）。

## 标记文件残留处理

标记文件 `/tmp/arthas-port-<pid>` 可能残留（如 agent 已随 JVM 重启消失但标记没删）：
- attach 时读到标记端口但连不上 → arthas 报 "Connection refused" → 脚本提示用 `stop-arthas.sh` 清理或手动删标记
- `stop-arthas.sh` 即使 agent 已不存在也会删标记文件（幂等）

## 协作 checklist（极简）

- [ ] 各跑 attach 脚本即可，脚本自动随机端口 + 自动复用，不用问别人
- [ ] 临时退出用 `quit`（回来复用），彻底结束用 `stop`（释放增强）
- [ ] 做过 redefine/watch/trace 后，结束前 `stop` 释放增强
- [ ] agent 状态异常/想重置：`bash tools/stop-arthas.sh <pod>`（stop + 删标记）
- [ ] 连不上（标记端口失效）：`stop-arthas.sh` 清理后重 attach
