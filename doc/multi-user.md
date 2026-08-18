# 多人协作与退出清理

两三个人一起用 Arthas——**实测结论:什么都不用协调,大家直接各跑 attach 脚本,arthas 自动共享 agent**。

## 实测结论(arthas 4.3.4)

本地起目标 JVM 实测 arthas 多次 attach 行为:

```
第 1 次 attach（默认 3658）   → 成功，agent 绑 3658，得到控制台
第 2 次 attach 同一 JVM（默认）→ 成功！"Process already using port 3658, skip attach"
                                 → 连到已有 agent，得到新控制台
stop                          → "Arthas Server is going to shutdown"，干净卸载
```

**arthas 的真实模型**:
- 同一 JVM 只有一个 agent（首次 attach 创建，绑 3658）
- 后续 attach **自动检测已有 agent 并复用**（连到它的 3658），每人各得一个独立控制台
- 不存在"端口冲突导致下次 attach 失败"——4.3.4 优雅复用

所以多人协作根本不需要端口协调、port-forward、telnet——**大家各跑 `attach-ephemeral.sh <pod>` 或 `attach-k8s.sh <pod>`，arthas 自己共享**。

## 为什么不用随机端口

曾经设想过"每次 attach 随机端口避免冲突",**实测证明这是错的**:

```
已有 agent（在 3658）+ 指定 --telnet-port=39287 再 attach
→ "Process already using port 8563"（检测到已有 agent）
→ "arthas-client connect 127.0.0.1 39287" → Connection refused
```

指定端口时,arthas client 会连指定端口,但已有 agent 在原端口 → 连接失败。**随机端口反而破坏复用机制**。默认端口(不指定)才正确——arthas 自动检测并连到已有 agent。

## 两种协作场景

### 场景 1:各自排查不同服务（最常见）

```bash
# 用户 A
bash tools/attach-ephemeral.sh order-service
# 用户 B
bash tools/attach-ephemeral.sh payment-service
```

不同 pod = 不同 JVM = 不同 agent,互不干扰。各自独立,退出各自 `stop`。

### 场景 2:多人看同一个服务（协同排查）

```bash
# 用户 A 先 attach
bash tools/attach-ephemeral.sh order-service
# A 进入 arthas 控制台

# 用户 B 也跑同一条命令（不用问 A 任何信息）
bash tools/attach-ephemeral.sh order-service
# B 也进入 arthas 控制台——arthas 检测到 A 的 agent，连上去，给 B 独立 session
```

- A 和 B 各有独立控制台、独立 session（各自 SESSION_ID），共享同一个 agent 实例
- **watch/trace 的输出是 session 私有的**：A 跑 watch 的命中结果只输出到 A 的控制台，B 看不到（实测：A 命中 3 次、B 命中 0 次，B 只看到自己的 session 信息）
- 但 A 注册 watch/trace 的**字节码增强是 agent 级共享**：A watch 了某方法后目标方法被插桩，B 连上时 `jad` 看到的是被 A 增强过的字节码；B 自己也 watch 同方法会叠加 listener（B 能看到自己的命中，看不到 A 的）
- A `stop`/watch 超时后增强移除，B 再看就是原始字节码
- 不需要 port-forward、telnet、端口约定——**零协调**
- 路径 C 同理:即使 A 的 ephemeral 容器销毁了,A attach 时注入目标 JVM 的 agent 还在,B attach 自动连上复用

> Pod 内多容器共享网络 namespace,agent 的 3658 在 pod 网络空间,ephemeral 容器里的 arthas-boot 连 127.0.0.1:3658 就是目标 JVM 的 agent。

## stop / quit / exit 的区别

| 命令 | 作用 | agent | 下次 attach |
|---|---|---|---|
| `stop` | **完全卸载 agent**，释放所有增强 | 移除 | 全新 attach（新 agent） |
| `quit` / `exit` | 退当前 session | **保留** | 复用（连到保留的 agent） |
| Ctrl+C | 退 arthas-boot | 通常保留 | 复用 |

**关键修正**:4.3.4 下 `quit`/Ctrl+C 残留的 agent **不会阻塞**下次 attach（arthas 自动复用）。但残留 agent 会**保留之前的增强**（watch/trace 拦截还在、redefine 字节码还在），可能干扰新会话。所以:

- **只是退出、待会还回来用**:`quit`（agent 留着,下次复用,增强延续）
- **彻底结束、要干净**:`stop`（卸载 agent,释放所有增强,下次全新）

## 什么时候必须 stop

不是"每次退出都要 stop"(残留不阻塞 attach),而是这些情况必须 stop:

1. **做过 `redefine`/`watch`/`trace` 等增强后想干净退出**:stop 释放增强,避免字节码/拦截残留影响服务
2. **想强制重置 agent**(如 agent 状态异常):stop 卸载,下次全新 attach
3. **服务要重启前**:stop 干净卸载,避免 agent 随 JVM 非正常退出留下脏状态
4. **路径 C 最后一个人用完**:stop 卸载目标 JVM 的 agent(ephemeral 销毁不会卸载它)

只是临时退出喝口水:`quit` 即可,回来复用。

## stop-arthas.sh:清理残留 agent

`tools/stop-arthas.sh <pod-flag>` 非交互卸载目标 JVM 的 arthas agent:

```bash
bash tools/stop-arthas.sh order-service
```

流程:attach 目标 → `-c stop` 非交互卸载 → 清理。适用:
- agent 残留了增强(watch/trace/redefine 还在),想释放
- agent 状态异常,想重置
- 路径 C 的 ephemeral 销毁后,想清理目标 JVM 里留下的 agent

> 不需要为"怕下次 attach 失败"而 stop——4.3.4 复用机制下下次 attach 自动连上。stop 是为**干净释放增强**,不是为"解锁端口"。

> ⚠ stop-arthas.sh 的 `-c stop` 对残留 agent 的清理有效性,依赖 arthas "attach 到已有 agent 的 JVM 会连上它"——已实测确认(default 端口二次 attach 连到已有 agent 并成功 stop)。容器有 java 走路径 A 风格;无 java 提示走 attach-ephemeral 手动 stop 或重启 pod。

## 协作 checklist（极简）

- [ ] 各跑 attach 脚本即可,不用问别人端口/状态
- [ ] 临时退出用 `quit`(回来复用),彻底结束用 `stop`(释放增强)
- [ ] 做过 redefine/watch/trace 后,结束前 `stop` 释放增强
- [ ] agent 状态异常/想重置:`bash tools/stop-arthas.sh <pod>`
