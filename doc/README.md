# Arthas-K8s 文档

本目录是项目的深入文档。主 [Readme](../Readme.md) 是精炼门面，这里讲透每个部分——为什么这么设计、脚本内部怎么跑、加固怎么处理、arthas 怎么用于漏洞验证、坏了怎么查、怎么扩展。

## 按需阅读

| 你想 | 看这个 |
|---|---|
| 理解项目为什么存在、设计哲学、和同类工具的区别 | [架构与设计](architecture.md) |
| 搞懂 4 个脚本内部怎么跑、关键实现决策 | [脚本详解](scripts.md) |
| 处理加固 pod（distroless/JRE-only/jlink/禁 attach） | [加固场景处理](hardening.md) |
| 用 arthas 验证某个具体漏洞（SQLi/反序列化/鉴权绕过…） | [Arthas 漏洞验证实战](arthas-commands.md) |
| 跑挂了怎么排查 | [排查手册](troubleshooting.md) |
| 多人协作 / 退出 stop 清理 / arthas 残留处理 | [多人协作与退出清理](multi-user.md) |
| 加 JDK 版本、写 playbook、批量编排、tunnel 取舍 | [扩展与路线图](development.md) |

## 推荐路径

- **新人**：架构 → 脚本 → 加固，建立整体认知，再按需查实战/排查
- **要验证漏洞**：直接看 arthas 实战，遇到加固问题跳到加固处理
- **要改项目**：脚本详解 → 扩展与路线图

## 文档与代码的对应

| 文档 | 对应代码 |
|---|---|
| [脚本详解](scripts.md) | `tools/fetch.sh` `tools/probe-k8s.sh` `tools/attach-k8s.sh` `tools/attach-ephemeral.sh` `tools/stop-arthas.sh` |
| [加固场景处理](hardening.md) | 两 attach 脚本的架构判定 + 版本探测段；probe 的 6 项探测 |
| [Arthas 实战](arthas-commands.md) | 不对应代码，是 arthas 控制台内的命令用法 |
| [多人协作与退出清理](multi-user.md) | `tools/stop-arthas.sh` + 两 attach 脚本的端口透传/stop 提示 |
| [排查手册](troubleshooting.md) | 跨所有脚本的症状 |
