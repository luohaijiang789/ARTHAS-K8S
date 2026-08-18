# 多人协作与退出清理

两三个人一起用 Arthas 时要解决两个问题：**不互相打架**、**退出不残留**（残留会导致下次 attach 失败）。本文讲清机制和操作。

## 背景：arthas agent 的端口与 session

arthas attach 到目标 JVM 后，agent 在**目标 JVM 里**开两个端口：

| 端口 | 默认 | 用途 |
|---|---|---|
| telnet | 3658 | 命令行会话（`telnet 127.0.0.1 3658`） |
| http | 8563 | Web console |

- **本地连接免认证**（`arthas.properties`：`local connection non auth`）
- **支持多 session**（`sessionTimeout=10800` 即 3 小时）：多个人 telnet 连同一个 agent，各自独立 session，共享同一个 agent 的数据（谁触发的 `watch`/`trace`，大家都能看结果）
- 启动时可指定端口：`--telnet-port <N>` `--http-port <N>` `--session-timeout <s>`

**关键约束：同一个 JVM 只应有一个 arthas agent。** 不要在同一 JVM 上跑多个 agent（资源浪费、字节码增强冲突）。多人协作的正确方式是**共享一个 agent**，不是各开一个。

---

## 多人协作的两种模式

### 模式 1：各自 attach 不同 pod（独立）

每个人在自己的调试节点跑 attach 脚本，查不同的服务：

```bash
# 用户 A
bash tools/attach-ephemeral.sh order-service
# 用户 B
bash tools/attach-ephemeral.sh payment-service
```

- **完全不冲突**：不同 JVM 各自的 agent、各自的 3658
- 每个人独立操作自己的目标，互不干扰
- 唯一要求：**各自退出时 `stop`**（见下文）

适用：分工排查不同服务。最简单，推荐默认用这种。

### 模式 2：共享同一 pod 的 arthas agent（真正协作）

多人一起看同一个服务（比如一起排查一个可疑 pod）。一个人 attach 起来，其他人 `kubectl port-forward` + telnet 连同一个 agent：

**用户 A（attach 起来）**：

```bash
bash tools/attach-ephemeral.sh order-service   # 或 attach-k8s.sh
# arthas 起来后，agent 在目标 JVM 开 telnet 3658（目标容器 localhost）
```

**用户 B / C（连进去）**：

```bash
# 用户 B：port-forward 目标 pod 的 3658 到本地 3658
kubectl port-forward -n <ns> pod/<pod> 3658:3658
# 另开终端
telnet 127.0.0.1 3658

# 用户 C：用不同本地端口避免和 B 冲突
kubectl port-forward -n <ns> pod/<pod> 13658:3658
telnet 127.0.0.1 13658
```

- 每人 port-forward 到**不同本地端口**，连同一个目标 agent
- arthas 多 session：各自独立控制台，共享 agent 数据
- A 触发 `watch com.x.OrderService createOrder`，B/C 在自己 session 里 `watch` 也能看到命中结果
- 退出协议见下文

> port-forward 到 pod 的 3658：agent 的 telnet 监听在目标容器 localhost 3658，`kubectl port-forward pod/<pod> 3658:3658` 转发到目标容器的 3658，能连。

适用：多人协同排查同一个服务、教学演示、交接班。

---

## stop / quit / exit 的区别（核心）

| 命令 | 作用 | agent 状态 | 端口 3658 | 下次 attach |
|---|---|---|---|---|
| `stop` | **完全卸载 agent**，清理增强类 | 移除 | 关闭 | 干净，可正常 attach |
| `quit` / `exit` | 只退当前 session | **残留** | **仍占** | 可能报 port in use |
| Ctrl+C（arthas-boot） | 退出 client | 通常残留（同 quit） | 仍占 | 可能报 port in use |
| kill / ssh 断 | 异常终止 | **残留** | 仍占 | 很可能失败 |

**铁律：退出 arthas 用 `stop`，不要用 `quit`/`exit`/Ctrl+C。** 除非你是模式 2 的非最后一人（见退出协议）。

---

## 退出协议

### 模式 1（各自不同 pod）

每个人自己 attach、自己 `stop`：

```
arthas> stop
# 看到卸载提示后退出
```

### 模式 2（共享同一 pod）

- **非最后一人**：`quit` 退自己的 session（agent 留着给其他人继续用）
- **最后一个人**：确认其他人都不用了，`stop` 卸载 agent

谁最后走谁 `stop`。如果不确定，沟通一下——`stop` 会让所有人的 session 都断。

---

## 残留问题（用户核心痛点）

### 什么情况会残留

1. **Ctrl+C 退出 arthas-boot**（最常见）：默认 detach，agent 留在目标 JVM
2. **ssh 断开 / 终端关闭**：arthas-boot 进程死，agent 残留
3. **`quit`/`exit` 退出**：agent 残留
4. **路径 C 的特殊隐患**：见下

### 路径 C 的特殊隐患（重要）

路径 C 在**临时容器**里跑 arthas-boot，但 attach 的是**目标 JVM**——arthas agent 被注入到**目标 JVM**，不是临时容器。

```
临时容器（跑 arthas-boot，退出即销毁）
        │ attach
        ▼
目标 JVM ← arthas agent 注入这里，telnet 3658 开在这里
```

→ **临时容器销毁 ≠ 目标 JVM 的 agent 清理。** 如果你退出路径 C 时没 `stop`，脚本 trap 会清理临时容器（ephemeral），但**目标 JVM 的 arthas agent 残留**，3658 仍占，下次 attach 该 pod 会失败。

所以路径 C 退出时 `stop` 更关键——必须在临时容器销毁前、在 arthas 控制台里 `stop` 卸载目标 JVM 的 agent。

### 残留的症状

下次 attach 同一 pod 时：
- `port 3658 already in use`
- 或 arthas 报 agent 已存在 / attach 异常
- 或 attach 成功但行为怪异（增强冲突）

### 残留清理方法

**方法 1（首选）：重新 attach 后 stop**

```bash
# 用 tools/stop-arthas.sh（见下）一键清理
bash tools/stop-arthas.sh <pod-flag>
```

或手动：attach 起来 → `stop` → 退出。

**方法 2：换端口绕过（临时）**

```bash
bash tools/attach-ephemeral.sh <pod-flag> --telnet-port=3659 --http-port=8564
```

临时绕过残留 agent，但残留还在（占资源），事后还是要方法 1 清理。不推荐长期用。

**方法 3（最后手段）：重启目标 pod**

```bash
kubectl delete pod -n <ns> <pod>   # 让 Deployment 重建
```

agent 随 JVM 一起没了。最可靠但有副作用（服务重启）。自管测试环境可用。

---

## attach 脚本的协作支持

`attach-k8s.sh` 和 `attach-ephemeral.sh` 已加：

1. **启动前提示**：退出用 `stop`，避免残留
2. **端口透传**：`--telnet-port=N` `--http-port=N` 传给 arthas-boot（共享模式指定端口、或残留时换端口绕过）
3. **退出后检测**：提示若未 stop 该怎么清理

### stop-arthas.sh：清理残留

`tools/stop-arthas.sh <pod-flag>` 专门清理残留 arthas agent：

```bash
bash tools/stop-arthas.sh order-service
```

流程：选 pod → 探测目标 java/pid → `arthas-boot <pid> -c stop`（非交互发 stop 命令）→ 清理。对残留 agent，会连上残留 agent 并 stop 卸载。

> ⚠ `-c stop` 清理残留的有效性依赖 arthas 对"attach 到已有 agent 的 JVM"的复用/增强行为——本地能验的参数已确认（`-c` 执行命令、`stop` 卸载），但跨容器对残留 agent 发 stop 的实际行为需真实环境验证。若 `stop-arthas.sh` 无效，走方法 3 重启 pod。

---

## 协作 checklist

- [ ] 分工明确：各自不同 pod（模式 1）还是共享同一 pod（模式 2）
- [ ] 模式 2：约定谁 attach、谁 port-forward、本地端口分配（3658 / 13658 / 23658…）
- [ ] 退出前确认：模式 2 非最后一人 `quit`，最后一人 `stop`
- [ ] 异常退出（ssh 断 / Ctrl+C）后：用 `stop-arthas.sh` 清理残留再重 attach
- [ ] 路径 C：特别注意在 ephemeral 销毁前 `stop`，否则目标 JVM agent 残留
