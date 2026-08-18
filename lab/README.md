# Arthas-K8s 测试集群（lab/）

本地 kind 集群 + 4 个 Spring Boot 靶机 pod，覆盖「标准矩阵」4 种加固形态，让 `tools/` 下的 probe/attach/stop 脚本端到端跑通。

## 前置

- Docker（已装）
- `kubectl` + `kind`（已在 `~/.local/bin`）
- `tools/` 底座已 `fetch.sh` 装齐（arthas + 8 JDK）

## 靶机矩阵

| pod | 镜像 | shell | java | rootFS | runAs | probe 路径 | attach |
|---|---|---|---|---|---|---|---|
| `app-normal` | arthas-lab/normal:17 | ✓ | JDK | 可写 | root | exec-direct | 路径 A |
| `app-distroless` | arthas-lab/distroless:17 | ✗ | — | — | — | ephemeral-container | 路径 C |
| `app-jre` | arthas-lab/jre:17 | ✓ | JRE | 可写 | root | ephemeral(传 JDK) | 路径 C |
| `app-readonly` | arthas-lab/normal:17 | ✓ | JDK | 只读+emptyDir/tmp | nonRoot 1000 | exec-direct | 路径 A(非root) |

## 一次性拉起

```bash
# 1. 起集群（写 ~/.kube/config）
kind create cluster --config lab/kind-config.yaml --name arthas-lab

# 2. 构 3 镜像（共享 build stage，首个慢、后两个复用缓存）
docker build --target normal     -t arthas-lab/normal:17     lab/app/
docker build --target distroless -t arthas-lab/distroless:17 lab/app/
docker build --target jre        -t arthas-lab/jre:17        lab/app/

# 3. 灌进 kind 节点
kind load docker-image arthas-lab/normal:17 arthas-lab/distroless:17 arthas-lab/jre:17 --name arthas-lab

# 4. 部署
kubectl apply -f lab/manifests/all.yaml
kubectl -n arthas-lab get po -w      # 等 4 个 Running
```

## 跑工具验证

```bash
# 摸底：应见 4 pod，路径分布 exec-direct×2 / ephemeral×2
bash tools/probe-k8s.sh app

# 路径 A（normal / readonly）
bash tools/attach-k8s.sh app-normal
bash tools/attach-k8s.sh app-readonly

# 路径 C（distroless / jre）
bash tools/attach-ephemeral.sh app-distroless
bash tools/attach-ephemeral.sh app-jre

# 清理残留 agent
bash tools/stop-arthas.sh app-normal
```

## 进 arthas 控制台后（靶机有真实目标）

```bash
# 另开终端触发，让 watch/trace 命中
kubectl -n arthas-lab port-forward svc/app-normal 8080:8080 &
curl 'localhost:8080/order?item=book'
curl 'localhost:8080/leak'
```

```
sc -d *OrderService                                  # 定位已加载类
jad com.arthaslab.OrderService                       # 反编译真实字节码
getstatic com.arthaslab.SecretConfig SECRET_TOKEN    # 读静态凭据
getstatic com.arthaslab.SecretConfig DEBUG_MODE      # 读运行时开关
watch com.arthaslab.OrderService createOrder '{params,returnObj}' -x 2
trace com.arthaslab.OrderService createOrder
stack com.arthaslab.OrderService saveOrder           # 谁调用了 sink
```
退出输 `stop`（非 Ctrl+C），卸载 agent 释放增强。

## 预期发现（测试要记录的缺口）

- **readOnlyRootFS 不参与 probe 选路**：`app-readonly` 的 probe 说 exec-direct。当前挂了 emptyDir:/tmp 所以路径 A 能 cp；若不挂，`kubectl cp /tmp/arthas-dist.tar.gz` 会失败。对应路线图 TODO「attach-k8s.sh fallback：readOnlyRootFS 走 emptyDir」。
- **distroless release 文件**：路径 C 第 1 道探测（release）可能 miss → 落第 2 道 class major version（=61→jdk17）。验证兜底。
- **cp 大 JDK 耗时**：路径 C 传 ~190M jdk-17-x64.tar.gz，记录耗时。

## 毁掉

```bash
kind delete cluster --name arthas-lab
```
