# k8s-quick — K8s 日常高频操作快捷脚本

kubectl 裸命令记不住、敲太长？这几个脚本封装最高频操作：进 pod、看日志、看状态、
describe、切 ns、清死 pod。每个都是自包含 bash，依赖只有 kubectl（clean-failed 另需 jq）。

风格与 根目录 arthas 脚本一致：pod 用关键字匹配（服务名/app 标签片段），多 pod 选号，
彩色友好输出。不依赖别名或 shell 配置——直接 `bash k8s-quick/xxx.sh` 跑。

## 脚本一览

| 脚本 | 作用 | 示例 |
|---|---|---|
| `exec-pod-k8s.sh` | 一键进 pod 交互 shell | `bash k8s-quick/exec-pod-k8s.sh order-service` |
| `logs-pod-k8s.sh` | 看日志（单 pod -f / 多 pod 同时 tail，借鉴 kubetail；第二参数 grep 过滤） | `bash k8s-quick/logs-pod-k8s.sh order ERROR -i` |
| `status-k8s.sh` | pod 状态速览（非 Running 着色高亮 + 汇总） | `bash k8s-quick/status-k8s.sh default` |
| `events-k8s.sh` | 集群事件速览（倒序 + Warn/Error 着色） | `bash k8s-quick/events-k8s.sh --watch` |
| `top-k8s.sh` | 节点/pod 资源用量（无 metrics-server 时友好提示） | `bash k8s-quick/top-k8s.sh --nodes` |
| `pf-k8s.sh` | 一键 port-forward pod 端口到本地 | `bash k8s-quick/pf-k8s.sh order-service --local 18080` |
| `describe-pod-k8s.sh` | 一键 describe pod | `bash k8s-quick/describe-pod-k8s.sh order` |
| `ns-k8s.sh` | 列 / 切当前 namespace | `bash k8s-quick/ns-k8s.sh kube-system` |
| `clean-failed-k8s.sh` | 批量清 Failed/Evicted 死 pod | `bash k8s-quick/clean-failed-k8s.sh --yes` |

排障链路：`status-k8s`（哪些不健康）→ `events-k8s`（为什么起不来）→ `logs-pod`（报错）→ `top-k8s`（是不是 OOM/CPU 打满）→ `exec-pod` 进容器，需要深挖 Java 再上 `probe-k8s.sh` + `attach-*.sh`；本地直连服务用 `pf-k8s`。

## 设计取舍

- **为什么不直接用别名/插件**？别名要改 shell 配置、跨机器不跟随；kubectl 插件要装 krew。
  这几个脚本 clone 仓库就有，`bash` 直接跑，零配置。
- **为什么不抄大杂烩**（如 HariSekhon/DevOps-Bash-tools 1200+ 脚本）？太重、噪音多。
  这里只放真正高频的 6 个，每个都能背下来。
- **多 pod 选号**：同 `probe-k8s.sh` 的 `awk index` 匹配（避免旧版 grep 误命中 NODE/IP 列）。菜单走 stderr、选中结果走 stdout，可被 `$(select_pod)` 安全捕获。
- **distroless 无 shell**：`exec-pod` 探测到无 shell 会提示改用 `logs-pod` 或 arthas 路径 C（attach 不需要 shell）。
- **metrics-server 缺失**：`top-k8s` 先探 `metrics.k8s.io` API，缺了提示安装命令而不是甩 trace。
- **无声明端口**：`pf-k8s` 自动取声明的 containerPort，端口由启动参数决定（如 Spring `--server.port`）的 pod 用 `--port` 手动指定。

## 借鉴的 GitHub 项目

- [johanhaleby/kubetail](https://github.com/johanhaleby/kubetail)（3.4k★）— 多 pod 同时 tail 日志思路 → `logs-pod --all`
- [HariSekhon/DevOps-Bash-tools](https://github.com/HariSekhon/DevOps-Bash-tools)（8.4k★）— `kubectl_*.sh` 命名 + 友好封装风格
- [kvaps/kubectl-node-shell](https://github.com/kvaps/kubectl-node-shell)（1.8k★）— 进节点思路（本目录未实现，需要时单独装该插件）

## 与 arthas 脚本的关系

这些是**通用 k8s 运维快捷脚本**，与 arthas 漏洞验证无关——排查 Java 服务时先 `status-k8s` 看健康、
`logs-pod` 看报错、`exec-pod` 进容器，需要 arthas 深挖再上 `probe-k8s.sh` + `attach-*.sh`。
