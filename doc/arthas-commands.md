# Arthas 漏洞验证实战

主 Readme 有命令速查，这里讲**怎么用这些命令做漏洞验证**——不是 arthas man page，是面向"确认这个漏洞真实可达"的实战用法。

## 核心思路

漏洞验证要回答几个问题，每个对应一类 arthas 命令：

| 要确认 | 命令 | 看什么 |
|---|---|---|
| 线上加载的真是这个类/版本吗 | `sc -d` `jad` | ClassLoader、字节码、版本 |
| 污点真的流到 sink 了吗 | `watch` | 方法入参/返回/异常 |
| 实际走的哪条分支 | `trace` | 调用链 + 分支 |
| 入口到 sink 可达吗 | `stack` | 反向调用栈 |
| 运行时开关/配置是什么 | `getstatic` | 静态字段值 |
| 能动态触发 PoC 吗 | `ognl` | 运行时调方法 |
| 内存里有泄露的凭据吗 | `heapdump` | 堆转储 |
| 补丁真的生效了吗 | `jad` `redefine` | 改后字节码 |

顺序一般是：先 `sc -d`/`jad` 确认加载的版本 → `stack`/`trace` 确认可达性 → `watch` 确认污点到 sink → 必要时 `ognl` 触发 PoC → 修复后 `jad` 确认补丁。

---

## sc -d / jad：确认线上真实加载的代码

静态审计基于源码仓库，但线上加载的可能不同——补丁没上、依赖版本不对、二开改过、热修复过。

### sc -d 定位类

```
sc -d com.x.OrderService
```

输出含 ClassLoader、加载来源（jar 路径）、是否被增强。**关键看加载来源 jar 路径**——确认是预期的版本，不是旧 jar 残留。

多个版本同时加载（JarHell、不同 ClassLoader）时 `sc -d` 会列出全部，逐个看来源。

### jad 反编译已加载字节码

```
jad com.x.OrderService createOrder
```

反编译的是**真实加载进 JVM 的字节码**，不是源码仓库。看：
- 方法体是不是补丁后的版本（修复了吗）
- 有没有被字节码增强（各种 agent 改过）
- 私有方法/内部类的真实实现

> `jad` 反编译可能和源码有差异（编译器优化、字节码增强），但那是真实运行的。

---

## watch：污点到 sink

验证 SQLi/RCE/SSRF/反序列化的核心——看污点（用户输入）是否真的流到危险 sink。

### SQLi 验证

怀疑 `OrderService.createOrder` 的 `orderId` 参数拼进了 SQL：

```
watch com.x.OrderService createOrder '{params, returnObj, throwExp}' -x 2
```

触发请求后看 `params[0]`（orderId）的值。但 watch 只看到入参，要看是否拼进 SQL 要往下追：

```
watch com.x.OrderMapper queryByOrder '{params}' -x 1
```

看 mapper 收到的 SQL 参数。如果 `params[0]` 是带注入 payload 的原始字符串（没参数化），sink 被污染确认。

### 反序列化验证

怀疑某 endpoint 触发 `ObjectInputStream.readObject`：

```
watch java.io.ObjectInputStream readObject '{params, returnObj}' -x 1
```

触发请求后，如果 watch 命中且 `returnObj` 是可疑 gadget 类，反序列化 sink 真实可达确认。

### 条件过滤

只看特定条件（减小噪音）：

```
watch com.x.OrderService createOrder '{params[0]}' 'params[0].length() > 100' -x 1
```

条件表达式为 true 时才输出。

### 注意

- `watch` 默认只看一次匹配就输出，高并发服务会刷屏，用条件过滤
- `-x N` 控制展开深度，对象深时调大
- `watch` 会拦截方法执行，有微量开销，看完用 `watch com.x.X stop` 或 Ctrl+C 停

---

## trace：实际走的分支

鉴权/WAF/限流 filter 的分支由运行时配置和请求决定，静态只看到所有分支存在。`trace` 看实际走哪条。

### 鉴权绕过验证

怀疑 `/admin/**` 路径的鉴权 filter 在某条件下绕过：

```
trace com.x.AuthFilter doFilter
```

发请求看 trace 输出的调用链——实际走了 `checkToken` → `pass` 还是 `skipCheck` → `pass`。如果某请求走了 `skipCheck` 分支，绕过确认。

### 耗时定位

trace 同时输出每步耗时，顺便看性能瓶颈。

---

## stack：反向可达性

`trace` 是正向（方法往下调了谁），`stack` 是反向（这个 sink 被谁调用了）。看 sink 的入口可达性。

```
stack com.x.OrderMapper executeUpdate
```

输出所有调用 `executeUpdate` 的调用栈。看：
- 哪些入口（Controller/RPC）能到这个 sink
- 中间有没有鉴权/校验环节
- 是不是有预期外的入口能到（绕过路径）

---

## getstatic：运行时配置/开关/密钥

静态看不到的运行时状态。

### 鉴权开关

```
getstatic com.x.AuthConfig DEBUG_MODE
getstatic com.x.AuthConfig AUTH_DISABLED_PATHS
```

看运行时 debug 开关、绕过路径列表——这些可能由配置中心动态下发，源码里是默认值。

### 硬编码 key

```
getstatic com.x.CryptoUtil SECRET_KEY
```

源码里可能是占位符 `${secret.key}`，运行时由环境变量/配置中心注入真实值。`getstatic` 看到真实 key。

> ⚠ `getstatic` 读到真实密钥后，按数据保护规范处理，不要明文记录到共享日志。

---

## ognl：动态触发 PoC

运行时调用任意方法，动态触发 PoC（**仅自有/测试环境**）。

### 触发一个方法

```
ognl '@com.x.OrderService@createOrder("test-id")'
```

调静态方法。实例方法需先拿实例：

```
ognl '#context = @com.x.SpringContextHolder@getBean("orderService"), #context.createOrder("test-id")'
```

### 验证修复

补丁后，用 ognl 调修复后的方法，看是否还接受恶意输入：

```
ognl '@com.x.OrderService@sanitize("'; DROP TABLE--")'
```

看返回值是否还含恶意字符。

### 安全约束

> ⚠ **ognl 能改运行时状态、触发真实逻辑**。仅在自有/测试环境用：
> - 可能触发真实数据流（createOrder 真的建了订单）
> - 可能触发副作用（发消息、写库、调外部 API）
> - 生产自查先评估影响，建议先 `watch`/`trace` 被动观察确认可达，再决定是否 ognl 主动触发

---

## heapdump：内存里的凭据

dump 堆找泄露的凭据 / token / 未脱敏 PII。

```
heapdump /tmp/heap.hprof
```

拉回本地用 MAT/jvisualvm 分析：
- 搜 `password`/`token`/`secret` 字符串
- 看缓存的用户对象是否含未脱敏字段
- 看连接池里有没有带密码的连接对象

> ⚠ heapdump 含完整堆（凭据、PII、会话），是高敏感操作。仅在授权环境用，dump 文件按敏感数据处置。

---

## redefine：补丁验证

修复后确认补丁真的加载生效。

### 看 + 改

`jad` 看当前字节码 → 本地改 `.java` → `mc`（memory compiler）编译成 `.class` → `redefine` 热替换 → 再 `jad` 确认替换成功 → `watch` 确认 sink 不再被触发。

```
jad com.x.OrderService > /tmp/OrderService.java     # 导出当前
# 本地编辑 /tmp/OrderService.java 修复
mc /tmp/OrderService.java --classLoaderClass com.x.AppClassLoader   # 编译
redefine /tmp/com/x/OrderService.class               # 热替换
jad com.x.OrderService createOrder                   # 确认是新代码
```

> ⚠ `redefine` 改运行时字节码，有风险。仅验证用，验证完重启服务恢复（redefine 不持久，重启回原版）。

---

## 端到端案例：验证一个疑似 SQLi

**上游静态审计报告**：`OrderService.createOrder(orderId)` 的 `orderId` 疑似拼进 SQL，可能 SQLi。

**实证流程**：

1. **确认加载版本**：
   ```
   sc -d com.x.OrderService
   jad com.x.OrderService createOrder
   ```
   看 `createOrder` 字节码——确认是当前版本，看有没有参数化。

2. **确认 sink 存在**：
   ```
   sc -d com.x.OrderMapper
   jad com.x.OrderMapper queryByOrder
   ```
   看 mapper 的 SQL 是 `${orderId}`（拼接）还是 `#{orderId}`（参数化）。

3. **确认可达性**：
   ```
   stack com.x.OrderMapper queryByOrder
   ```
   看哪些入口能到 queryByOrder，中间有没有校验。

4. **确认污点到 sink**：
   ```
   watch com.x.OrderMapper queryByOrder '{params}' -x 1
   ```
   发一个带 payload 的请求（`orderId=1' OR '1'='1`），看 `params[0]` 是原始 payload 还是参数化后的。如果是原始字符串，**SQLi 真实可达确认**。

5. **（修复后）确认补丁**：
   ```
   jad com.x.OrderMapper queryByOrder
   ```
   看改成了 `#{orderId}`，`watch` 确认不再收到原始 payload。

**结论**：不是"代码里看着像 SQLi"，是"线上真实加载的代码、真实请求、污点真实到了拼接 sink"——实证。

---

## 退出 arthas

```
stop      # 停止 arthas（卸载 agent，路径 C 触发临时容器清理）
```

或 Ctrl+C。路径 A 退出后 `trap` 清理容器 /tmp；路径 C 退出后 `trap` 移除 ephemeral container。
