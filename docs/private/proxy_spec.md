# Proxy Spec

本文档定义 `ios-use proxy` 的目标能力、实现边界与推荐架构。

结论先行：

- 正式方案改为 **`Mac proxy + Driver 端 orchestration`**。
- 真正抓包发生在 **Mac 端代理进程**，不是 Driver 端。
- Driver 端负责 **设备引导、证书安装辅助、打开安装页面、会话编排**。
- CLI 端对外暴露统一的 `proxy` 命令面。

---

## 一、目标

### 1.1 用户目标

我们的目标体验是：

1. 用户在真机上首次安装并信任 `ios-use` CA。
2. 用户执行：

```bash
bun run src/cli.ts proxy start --stream
```

3. CLI 端立即开始实时输出 `jsonl` 抓包结果。
4. `Ctrl+C` 后停止实时流，并同时停止本次 proxy session。
5. 后续可通过 `proxy read` 读取最近一次 proxy session 的抓包结果。

### 1.2 产品目标

`proxy` 仍然是 `ios-use` 的正式能力，而不是让用户手工操作 `mitmproxy` 的外部脚本。

因此产品面应满足：

- `ios-use` CLI 端统一暴露命令。
- Driver 端负责设备引导与辅助操作。
- 抓包结果统一落到 `~/.ios-use/`。
- 日志、产物、错误语义遵循现有 `ios-use` 口径。

### 1.3 非目标

以下内容不在当前方案目标内：

- 设备侧 Network Extension / Network Filter。
- 严格的 `bundle-scoped capture`。
- 自动绕过 certificate pinning。
- 保证所有 App 都能抓到 HTTPS 明文。
- 支持除 `jsonl` 外的其他导出格式。
- 做完整的重放、改包、断点注入平台。

---

## 二、前提与约束

### 2.1 明确假设

本文档基于以下假设：

- 目标平台先只考虑 **真机**。
- 目标协议先只考虑 **HTTP/1.1、HTTP/2 over TLS/TCP**。
- 用户允许在手机上进行少量手工确认操作。
- 设备通过 **USB** 连接 Mac（已有 usbmux 通道）。

### 2.2 必须正视的系统约束

当前方案绕不过去的约束有 3 个：

1. **HTTPS 明文解密必须建立 CA 信任链。**
   - 只要要看 HTTPS 明文，就必须让设备信任 `ios-use` 的根证书。
   - 对手动安装的证书，iOS 仍要求用户在“证书信任设置”里手动打开 full trust。

2. **普通真机上，Mac 端显式代理无法提供严格的 App 级源头过滤。**
   - 设备把流量转发给 Mac 代理时，代理看到的是连接和 HTTP 请求。
   - 代理无法天然知道“这条请求属于哪个 iOS App”。

3. **显式代理意味着设备侧仍需安装代理配置。**
   - 不能再声称”只需要信任 CA 就行”。
   - 更准确的说法是：用户只需要做一次”安装 CA + 安装代理 profile”，之后日常使用尽量一键。

4. **iOS 不接受 127.0.0.1 作为系统代理地址。**
   - iOS 系级代理设置不允许 loopback 地址。
   - 解决方案：设备端代理监听 `0.0.0.0:9090`，代理 profile 填设备自身局域网 IP。

5. **USB 代理方案：设备通过 usbmux 隧道转发到 Mac mitmdump。**
   - 设备端运行轻量 HTTP proxy，Mac 通过 usbmux 连接到设备代理端口。
   - Mac 端桥接 usbmux 到 mitmdump，实现流量中转。
   - 优势：不需要设备和 Mac 同 WiFi，不需要知道 Mac IP，复用已有 USB 连接。

### 2.3 方案口径

因此本 spec 采用如下口径：

- **抓包在 Mac 端完成**
- **Driver 端不抓包，只做 orchestration**
- **设备侧通过安装 profile 把 HTTP/HTTPS 流量显式代理到 Mac**
- **当前方案不绑定 `bundleId`**

---

## 三、实现口径

### 3.1 正式方案

本文档的正式方案为：

```text
CLI 端
  -> proxy command orchestration
  -> Mac proxy process (mitmproxy / mitmdump)
  -> local capture store
  -> Driver 端
      -> openURL / activateApp / UI guidance
      -> device-side install assistance
```

这里的“Driver 端 orchestration”定义为：

- `proxy` 命令由 CLI 端发起。
- Mac 端负责启动和停止代理进程。
- Driver 端负责辅助设备完成 CA/profile 安装与后续引导。
- CLI 端统一消费抓包结果并输出 `jsonl`。

### 3.2 关于 App 归属

结论先行：

- 在当前方案里，**不能把任何单个 App 作为严格抓包边界**。
- 当前方案默认抓“经过设备显式代理的 HTTP/HTTPS 流量”。
- 如需强调某个目标 App，只能靠：
  - CLI 端在抓包前激活目标 App
  - 展示层按时间窗口、host、path 做 best-effort 观察
  - 用户自己结合当前操作上下文判断

---

## 四、推荐架构

### 4.1 总体架构

```text
CLI 端 (Bun)
  -> proxy command layer
  -> Mac proxy supervisor
      -> mitmdump (Mac 本地)
      -> usbmux bridge (Mac ↔ 设备代理端口)
      -> local HTTP file server
      -> local capture store
  -> Driver 端 client
      -> Driver 端
          -> HTTP proxy (0.0.0.0:9090, 设备本地)
          -> openURL / activateApp / UI assist
```

**USB 代理数据流：**

```text
iOS 系统流量
  → 设备代理 (0.0.0.0:9090)
  → usbmux 隧道
  → Mac 端 bridge
  → mitmdump (解密/抓包)
  → 目标服务器
```

职责边界：

- `src/cli.ts`
  - 命令入口、参数解析、结果展示。
- `src/commands/proxy.ts`
  - proxy 语义编排。
- `src/driver-client/`
  - 调 Driver 端的辅助命令，比如 `openURL`、`activateApp`。
- `driver`
  - 不抓包。
  - 只负责设备引导动作。
- Mac proxy supervisor
  - 启动/停止 `mitmdump`
  - 提供 CA/profile 下载入口
  - 维护最近一次 proxy session 状态
  - 把抓包结果转换为 `jsonl`

### 4.2 控制面 / 数据面分离

必须明确区分两类链路：

- **控制面**
  - `proxy start`
  - `proxy stop`
  - `proxy read`
  - Driver 辅助动作

- **数据面**
  - `mitmdump` 输出
  - 本地抓包缓存
  - 实时 `jsonl` 流

控制面由 CLI 驱动。

数据面由 Mac 端 proxy 进程产生与落盘。

### 4.3 为什么保留 Driver

即使抓包不在 Driver 里，Driver 仍然有价值：

- 可以直接在设备上打开 CA/profile 安装页。
- 可以在安装完成后自动拉起目标 App。
- 可以把“配置代理”从手工输入地址，收敛成受控引导流程。
- 后续可以用 UI 自动化辅助用户完成安装后的系统跳转。

---

## 五、Mac Proxy 设计

### 5.1 组件拆分

Mac 端至少需要以下 4 个模块：

#### A. Proxy Supervisor

职责：

- 启动和停止 `mitmdump`
- 管理本次 proxy session 状态
  - 记录 pid、端口、开始时间、目标设备

#### B. Profile Server

职责：

- 提供 CA 文件下载
- 提供代理配置 profile 下载
- 提供一个稳定的本地 HTTP 入口，供设备打开安装页

#### C. Capture Store

职责：

- 保存最近一次 proxy session 状态
- 保存实时事件缓存
- 保存 `jsonl` 产物
- 保存错误日志

建议目录：

- `~/.ios-use/state/proxy-session.json`
- `~/.ios-use/state/proxy-events.jsonl`
- `~/.ios-use/artifacts/proxy-*.jsonl`
- `~/.ios-use/logs/proxy.log`

#### D. JSONL Adapter

职责：

- 将 `mitmdump` 事件转换为统一的 `jsonl`
- 供 `proxy start --stream` 实时输出
- 供 `proxy read` 读取最近结果

### 5.2 CA 设计

根证书必须长期稳定，否则用户每次重新安装都要重新信任。

因此推荐：

- 首次 `proxy start` 时，在 Mac 本地生成一套长期 CA。
- 私钥保存在 `~/.ios-use/` 下。
- 公钥导出为设备可安装的 `.cer` 或 profile 资源。
- 后续所有 proxy session 复用同一套 CA。

注意：

- Driver 端无法可靠判断“设备上是否已经真正信任该 CA”。
- 更现实的做法是：
  - 本地记录“是否已生成 CA / 是否已完成安装引导”
  - 若用户反馈抓不到 HTTPS，再提示检查证书信任状态

### 5.3 代理配置设计

显式代理需要把设备流量导向 Mac，因此还需要设备侧代理配置。

推荐方式：

- 由 Mac 端动态生成代理 profile
- profile 中写入：
  - Mac IP
  - proxy port
  - profile identifier
- 通过本地 HTTP server 提供下载
- Driver 端用 `openURL` 在设备上直接打开安装页

这意味着：

- 首次使用不只是“信任 CA”
- 还包括一次“安装代理 profile”

---

## 六、CLI 端 / Driver 端 API 设计

### 6.1 CLI 端命令面

推荐命令：

```bash
bun run src/cli.ts proxy start
bun run src/cli.ts proxy start --stream
bun run src/cli.ts proxy read
bun run src/cli.ts proxy read --count 20
bun run src/cli.ts proxy read --duration 5s
bun run src/cli.ts proxy read --save latest
bun run src/cli.ts proxy stop
```

说明：

- `start`
  - 依赖已有 session（需要 driver 才能运行 proxy）
  - 启动 Mac 端 proxy session
  - 确保 CA/profile server 就绪
  - 必要时触发设备安装引导
  - `--stream` 时建立实时 `jsonl` 输出
  - **重复调用报错**（不幂等）
- `read`
  - 从最近一次 proxy session 读取
  - 默认读取最近 `10` 个请求
  - 支持 `--count <n>`
  - 支持 `--duration 5s`
  - 支持 `--save [name]`
- `stop`
  - 停止 Mac 端 proxy session

### 6.2 Driver 端命令面

Driver 端只保留辅助类 command：

| command | args | 说明 |
|---------|------|------|
| `openURL` | `url` | 在设备上打开 CA/profile 安装页 |
| `activateApp` | `bundleId` | 安装完成后拉起目标 App |

当前方案下，不建议新增 `proxyStart` / `proxyRead` / `proxyStop` 到 Driver 端协议。

### 6.3 `proxy start` 行为细节

`proxy start` 的前置条件：

- **必须已有活跃 session**（proxy 依赖 driver 运行设备端代理）
- 若无 session，报错提示先执行 `session start`

执行顺序：

1. 检查是否有活跃 session，无则报错
2. 检查是否已有 running 的 proxy session，有则报错（不幂等）
3. CLI 端检查本地是否已有可复用 CA
4. CLI 端检查本地 profile server 是否可启动
5. 通过 driver 启动设备端 HTTP proxy（`proxyStart` 命令）
6. CLI 端启动 Mac proxy 进程 + usbmux bridge
7. CLI 端生成或刷新代理 profile
8. CLI 端通过 Driver 端触发 `openURL`
9. 用户在设备上完成 CA / profile 安装
10. CLI 端确认本地 proxy session 进入 running
11. 若传 `--stream`，开始实时输出 `jsonl`

**安全要求**：proxy session 必须保证正常清理。若 proxy 异常退出但设备端代理 profile 未移除，设备将无法上网。`proxy stop` 必须：
- 停止设备端 proxy（`proxyStop` 命令）
- 停止 Mac 端 mitmdump
- 清理 session 状态文件

失败时的回滚要求：

- 若 `mitmdump` 启动失败，必须清理本次 session 状态
- 若 profile 生成失败，必须停止本次 proxy 进程
- 若 `openURL` 失败，不应删除已生成的 CA，但应中止本次 start

### 6.4 `proxy start --stream` 响应示意

实时模式输出 `jsonl`（每个请求-响应对一行）：

```jsonl
{"id":"req-1","method":"GET","url":"https://example.com/feed","host":"example.com","status":200,"contentType":"application/json","bodyBytes":1024,"startedAt":1714980000000,"finishedAt":1714980000100}
```

约束：

- 每行必须是单独一个合法 JSON 对象
- 不输出其他非 JSON 行
- `Ctrl+C` 后 CLI 端必须补发 `proxy stop`

### 6.5 `proxy read` 参数约束

- 从最近一次 proxy session 读取
- 默认读取最近 `10` 个请求
- `--count <n>` 与默认值互斥，返回最近 N 个请求
- `--duration 5s` 按最近时间窗口读取
- `--save [name]` 将当前读取结果保存到 `~/.ios-use/artifacts/` 下的 `jsonl` 文件
- 只支持 `jsonl`

若当前不存在最近 proxy session，应直接报错。

### 6.6 `proxy read --save` 行为细节

- `--save` 不改变 stdout 返回内容
- `--save latest` 仅影响输出文件名
- 未传文件名时，CLI 端可使用时间戳命名
- 保存结果必须是标准 `jsonl`
- 保存路径统一为 `~/.ios-use/artifacts/`

### 6.7 Proxy Session 状态结构

CLI 端需要维护最近一次 proxy session 状态文件：

```json
{
  "sessionId": "proxy-20260507T120000Z",
  "status": "running",
  "startedAt": 1746580800000,
  "proxyHost": "192.168.1.10",
  "proxyPort": 9090,
  "profileUrl": "http://192.168.1.10:9089/proxy.mobileconfig",
  "caUrl": "http://192.168.1.10:9089/ca.cer",
  "eventsFile": "/Users/bytedance/.ios-use/state/proxy-events.jsonl",
  "logFile": "/Users/bytedance/.ios-use/logs/proxy.log",
  "mitmdumpPid": 12345
}
```

约束：

- 同时只维护一个“最近 proxy session”
- `proxy start` 会覆盖旧的 session 状态
- `proxy stop` 不删除历史 `jsonl` 产物
- `proxy read` 始终基于最近一次 session 状态读取

---

## 七、用户交互设计

### 7.1 首次使用

理想步骤：

1. 用户执行 `proxy start --stream`
2. CLI 检查本地 CA 和 proxy profile 是否已生成
3. 若未生成，则在 Mac 端生成 CA 与 profile
4. Driver 端在设备上打开安装页
5. 用户在设备上安装 CA 与代理 profile
6. 用户在系统里手动完成 CA trust
7. CLI 端启动本次抓包并开始实时输出

### 7.2 日常使用

```bash
bun run src/cli.ts proxy start --stream
```

CLI 端输出：

- 当前设备
- 当前 proxy 监听地址
- 持续输出 `jsonl`
- `Ctrl+C` 时停止 stream 并停止 Mac proxy

### 7.3 失败提示原则

错误必须说清楚是哪一层失败：

- CA 未生成
- CA 未信任
- 代理 profile 未安装
- 设备无法连接到 Mac proxy
- `mitmdump` 启动失败
- body 被截断
- 目标 App 使用 pinning，HTTPS 无法解密

不要统一报成“proxy failed”。

---

## 八、MVP 与演进阶段

### 8.1 Phase 1：Mac Proxy MVP

目标：

- 启动和停止 `mitmdump`
- 生成 CA 与代理 profile
- 通过 Driver 端打开安装页
- `proxy start --stream` 实时输出 `jsonl`
- `proxy read` 读取最近请求并支持保存为 `jsonl`

允许的妥协：

- 首版只支持 HTTP/1.1 / HTTP/2
- body 默认截断
- 只支持 `jsonl`
- `bundleId` 只做上下文，不做严格过滤

### 8.2 Phase 2：工程化增强

目标：

- 更稳定的 profile server
- 更好的 session 状态恢复
- 更细粒度的 host / path 展示过滤
- 更好的错误分类

### 8.3 Phase 3：高级能力

候选项：

- body 采样 / 截断策略
- URL / host / method filter
- 自动验证设备代理仍指向当前 Mac
- 更强的历史检索能力

---

## 九、风险与边界

### 9.1 Certificate Pinning

这是最重要的边界。

即使设备已信任 `ios-use` CA，某些 App 仍会因为 pinning 拒绝 MITM。

处理原则：

- 明确标记“连接建立失败 / 可能存在 pinning”
- 不承诺解密一定成功

### 9.2 HTTP/3 / QUIC

首版不承诺完整支持 QUIC/HTTP3。

建议口径：

- 首版只保证 HTTP/1.1 / HTTP/2
- QUIC/HTTP3 属于后续议题

### 9.3 网络依赖

Mac proxy 方案对网络环境有明确要求：

- 设备必须能访问到 Mac 的 proxy/profile server
- Mac IP 变化后，旧 profile 可能失效
- 网络切换可能导致抓包中断

### 9.4 App 归属边界

在当前方案里，不能承诺严格的单 App 归属。

因此需要明确：

- 当前结果代表“经过显式代理的流量”
- 不代表“代理层只会抓某一个 App 的流量”
- Safari / 系统 WebView / 第三方跳转带来的流量都可能混入结果

### 9.5 Proxy 后端选型

当前主推荐仍然是 `mitmdump`，原因是：

- HTTPS MITM 能力成熟
- Python addon 机制稳定
- HTTP/2 / HTTP/3 / WebSocket 生态更完整
- 适合先快速交付 CLI 端 MVP

除 `mitmdump` 外，可考虑的路线有：

#### A. `go-mitmproxy`

特点：

- Go 实现
- 可直接作为源码或库导入
- 自带插件能力
- 证书目录与 `mitmproxy` 兼容

优点：

- 更容易做成单二进制
- 比 Python 进程更容易嵌入自定义控制逻辑

风险：

- 生态和成熟度明显弱于 `mitmproxy`
- 特性覆盖面没 `mitmproxy` 完整

#### B. 自研 Go / Rust HTTP CONNECT MITM

特点：

- 完全按 `ios-use` 的数据模型来实现
- 可以天然输出我们需要的 `jsonl`

优点：

- 最可控
- 最容易做到“CLI 端状态文件 + jsonl 输出”完全贴合产品语义

风险：

- HTTPS MITM、证书缓存、HTTP/2、异常兼容都要自己补
- 工程成本最高

#### C. 其他桌面代理框架

像 Sniper、RustGate 这类项目更像“现成桌面代理产品”或实验性 MITM proxy。

问题：

- 很多并不是为“作为库导入到 CLI 工程里”设计的
- API 稳定性、嵌入式能力、长期维护性都不如 `mitmdump`
- 更适合参考实现，不适合作为当前主方案

---

## 十、实现决策

当前建议的正式决策如下：

1. `proxy` 是 CLI 端正式能力。
2. 抓包在 Mac 端完成，Driver 端不承担抓包职责。
3. 正式实现采用：

```text
CLI 端 proxy command
  -> Mac proxy supervisor
  -> mitmdump
  -> local capture store
  -> Driver 端 orchestration
```

4. Driver 端只负责：
   - `openURL`
   - `activateApp`
   - 设备引导
5. 首版只承诺：
   - HTTP/1.1 / HTTP/2
   - CA 手动信任
   - 代理 profile 安装
   - `proxy start --stream` 实时 `jsonl`
   - `proxy read` 读取最近请求
   - `--save [name]` 保存为 `jsonl`
   - 只支持 `jsonl`
6. 首版不绑定 `bundleId`，也不承诺严格的单 App 抓包边界。
7. Proxy 后端首选 `mitmdump`，必要时再评估 `go-mitmproxy` 或自研实现。

---

## 十一、下一步

代码层第一步建议先完成：

- `src/commands/proxy.ts` 命令面
- Mac 端 proxy session 状态文件
- `mitmdump` 与 `jsonl` adapter
- profile 生成与本地 HTTP server
- Driver `openURL` 辅助链路

---

## 十二、USB 代理方案验证结论（2026-05-07）

已验证的关键假设：

| 假设 | 结论 | 备注 |
|------|------|------|
| 设备端 proxy 绑定 0.0.0.0:9090 | ✅ 成功 | 使用 GCD DispatchSource |
| Mac 通过 usbmux 连设备 9090 端口 | ✅ 成功 | 和连 8100 端口一样 |
| 设备 proxy 接收 HTTP 请求 | ✅ 成功 | 正确解析 GET/CONNECT |
| 设备 proxy 直连外网 | ❌ 失败 | 设备通过 USB 连接，无独立网络出口 |
| Mac 端 usbmux 桥接到 mitmdump | 待实现 | 需要 Mac 端 bridge 模块 |

**结论**：USB 代理方案可行。设备端 proxy + usbmux 隧道已打通，下一步实现 Mac 端 bridge 到 mitmdump。
