# Proxy Spec

## 结论先行

- **mobileconfig per-Wi-Fi proxy 不可行**：Wi-Fi payload 需要 SSID 和密码才能生效，放弃。
- **回退到最原始方案**：装 CA → 手动配当前 Wi-Fi HTTP proxy → mitmdump 抓包。
- **"手动配"由 flow 自动化完成**：中文环境提供内置 flow；其他语言环境由 AI agent 执行等效操作。
- 命令拆分为两步：`proxy configca`（一次性）和 `proxy start`（每次抓包）。

---

## 一、命令设计

### 1.1 `proxy configca`

**目的**：将 mitmproxy CA 安装到设备并完全信任。只需执行一次。

行为：

1. 确保本地 `~/.mitmproxy/mitmproxy-ca-cert.pem` 存在（不存在则启动一次 mitmdump 生成）。
2. 将 CA 证书传给 driver（通过 driver TCP 通道 push 文件）。
3. Driver 在设备上触发 CA 安装（通过 profile install 页面或 Safari 打开本地 profile URL）。
4. 执行 flow **安装 CA**：在"已下载描述文件"页面点击安装。
5. 执行 flow **信任 CA**：进入 `设置 → 通用 → 关于本机 → 证书信任设置`，打开 mitmproxy CA 的完全信任开关。

前置条件：

- 活跃 session。

产物：

- 设备已安装并完全信任 mitmproxy CA。
- `~/.ios-use/state/proxy-ca.json` 记录 CA 指纹、安装时间。

### 1.2 `proxy start [--stream]`

**目的**：启动 Mac 端 mitmdump，并通过 flow 自动配置设备当前 Wi-Fi 的 HTTP 代理指向 Mac。

行为：

1. 检测 Mac Wi-Fi interface、LAN IP。
2. 启动 mitmdump 监听 `0.0.0.0:<port>`（默认 9080）。
3. 执行 flow **配置 Wi-Fi 代理**：进入 `设置 → Wi-Fi → 当前网络(i) → 配置代理 → 手动`，填入 Mac LAN IP 和端口。
4. 验证代理生效（可选 probe）。
5. 状态写入 `~/.ios-use/state/proxy-session.json`。
6. 若 `--stream`，stdout 实时输出 jsonl。

前置条件：

- 活跃 session。
- CA 已安装信任（`proxy configca` 已执行过）。
- 设备与 Mac 在同一 Wi-Fi/LAN。

### 1.3 `proxy stop`

**目的**：关闭代理配置并停止 mitmdump。

行为：

1. 执行 flow **关闭 Wi-Fi 代理**：进入 `设置 → Wi-Fi → 当前网络(i) → 配置代理 → 关闭`。
2. 验证设备恢复直连。
3. 停止 mitmdump（SIGTERM）。
4. 更新 `proxy-session.json` 为 stopped。

关键约束：**必须先关闭代理再停 mitmdump**，否则设备断网。

### 1.4 `proxy read`

读取最近一次 proxy session 的抓包记录。

```bash
proxy read [--count <n>] [--duration <duration>] [--save [name]]
```

### 1.5 `proxy doctor`

诊断 proxy 环境：mitmdump 可执行、CA 已生成、Mac Wi-Fi/LAN IP、端口可监听、设备可达 Mac。

---

## 二、Flow 设计

所有 UI 自动化通过 flow yaml 实现。内置 flow 面向**中文 iOS 系统**；其他语言环境由 AI agent 根据同等语义执行。

### 2.1 `flows/proxy_install_ca.yaml`

安装 CA 描述文件（前提：driver 已将 profile 推送到设备，系统弹出"已下载描述文件"提示）。

关键步骤：
- 设置 → 通用 → VPN 与设备管理 → 已下载的描述文件 → 安装 → 输入密码（如有）→ 安装

### 2.2 `flows/proxy_trust_ca.yaml`

完全信任 CA 证书。

关键步骤：
- 设置 → 通用 → 关于本机 → 证书信任设置 → 打开 mitmproxy CA 开关 → 继续

### 2.3 `flows/proxy_set_wifi_proxy.yaml`

配置当前 Wi-Fi 的 HTTP 代理为手动模式。

关键步骤：
- 设置 → Wi-Fi → 当前连接网络的 (i) 按钮 → 配置代理 → 手动
- 填入服务器地址（Mac LAN IP）和端口
- 存储

参数化：`server` 和 `port` 从 CLI 传入 flow context。

### 2.4 `flows/proxy_clear_wifi_proxy.yaml`

关闭当前 Wi-Fi 代理。

关键步骤：
- 设置 → Wi-Fi → 当前连接网络的 (i) 按钮 → 配置代理 → 关闭
- 存储

---

## 三、架构

```text
CLI (Bun)
  ├─ proxy configca
  │    ├─ 确保 mitmproxy CA 存在
  │    ├─ push CA 到 driver
  │    ├─ driver 触发 profile 安装页
  │    └─ 执行 flow: install_ca + trust_ca
  │
  ├─ proxy start
  │    ├─ 检测 Mac Wi-Fi SSID / LAN IP
  │    ├─ 启动 mitmdump (0.0.0.0:9080)
  │    ├─ 执行 flow: set_wifi_proxy(server, port)
  │    └─ 实时输出 jsonl (--stream)
  │
  └─ proxy stop
       ├─ 执行 flow: clear_wifi_proxy
       └─ 停止 mitmdump

数据面:
  iOS App/Safari → Wi-Fi HTTP Proxy (手动) → Mac LAN IP:9080 → mitmdump → Internet
```

控制面通过 USB（driver TCP），数据面通过 Wi-Fi（HTTP proxy）。

---

## 四、Mac 端组件

### 4.1 Wi-Fi Detector

- SSID：`networksetup -getairportnetwork <device>`
- LAN IP：`ipconfig getifaddr <iface>`
- Interface：`networksetup -listallhardwareports` 找 Wi-Fi

### 4.2 mitmdump

- 监听 `0.0.0.0:<port>`，forward proxy mode。
- 复用 `~/.mitmproxy/` CA。
- jsonl addon 输出到 stdout + `~/.ios-use/state/proxy-events.jsonl`。

### 4.3 存储

- `~/.ios-use/state/proxy-session.json` — session 状态（含 CA 安装状态）
- `~/.ios-use/state/proxy-events.jsonl` — 抓包事件流

---

## 五、多语言策略

| 环境 | 策略 |
|------|------|
| 中文 iOS | 使用内置 flow yaml，全自动 |
| 其他语言 | CLI 输出操作指引，由 AI agent 基于 dom + tap/input 执行等效操作 |

内置 flow 中的 UI 文本（如"设置"、"通用"、"Wi-Fi"等）硬编码中文。AI agent 模式下通过 `dom` 查找对应元素再操作，不依赖文本匹配。

---

## 六、抓包数据格式

### 6.1 `--stream` 实时输出

stdout 每行一个合法 JSON：

```jsonl
{"id":"req-1","method":"GET","url":"https://example.com/feed","host":"example.com","status":200,"contentType":"application/json","requestHeaders":{"Accept":"*/*"},"responseHeaders":{"Content-Type":"application/json"},"requestBody":null,"responseBody":"{\"ok\":true}","bodyBytes":1024,"startedAt":1714980000000,"finishedAt":1714980000100}
```

### 6.2 Body 策略

- 默认包含完整 request/response body（文本类型：json、xml、html、text）。
- 二进制 body（image、octet-stream 等）只输出 `"<binary N bytes>"`。
- `--body-limit <bytes>`：截断超过指定大小的 body，默认 100KB。
- `--no-body`：只输出 metadata，不含 body。

### 6.3 jsonl 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| id | string | 请求唯一 ID |
| method | string | HTTP method |
| url | string | 完整 URL |
| host | string | 目标 host |
| status | number | 响应状态码 |
| contentType | string | 响应 Content-Type |
| requestHeaders | object | 请求头 |
| responseHeaders | object | 响应头 |
| requestBody | string\|null | 请求 body（文本）或 null |
| responseBody | string\|null | 响应 body（文本）或 null |
| bodyBytes | number | 原始响应 body 字节数 |
| truncated | boolean | body 是否被截断 |
| startedAt | number | 请求开始时间戳 ms |
| finishedAt | number | 响应完成时间戳 ms |

- 非 JSON 内容（状态、警告）输出到 stderr。
- `Ctrl+C` 触发 `proxy stop` 完整流程。

---

## 七、错误语义

- `MITMDUMP_NOT_FOUND` — mitmdump 未安装
- `CA_NOT_GENERATED` — CA 证书未生成
- `CA_NOT_INSTALLED` — 设备未安装 CA
- `WIFI_SSID_NOT_FOUND` — Mac 未连接 Wi-Fi
- `MAC_LAN_IP_NOT_FOUND` — 获取 LAN IP 失败
- `MAC_PROXY_PORT_BLOCKED` — 端口被占用
- `DEVICE_CANNOT_REACH_MAC` — 设备无法访问 Mac 代理端口
- `FLOW_FAILED` — UI 自动化 flow 执行失败
- `PROXY_NOT_RUNNING` — 无活跃 proxy session

---

## 八、非目标

- mobileconfig / Wi-Fi payload 自动配代理（已验证不可行）
- NetworkExtension / VPN / Supervised / MDM
- Certificate pinning bypass
- HTTP/3 / QUIC
- 严格 per-app 抓包
- 非 Wi-Fi 场景

---

## 九、实现顺序

### Phase 1：核心链路

1. Mac Wi-Fi 检测 + mitmdump 启动/停止
2. CA push 到 driver 的通道
3. 4 个 flow yaml（install_ca、trust_ca、set_wifi_proxy、clear_wifi_proxy）
4. `proxy configca` / `proxy start` / `proxy stop` 命令串联
5. jsonl addon + `--stream` 输出

### Phase 2：完善

- `proxy read` / `proxy doctor`
- flow 失败重试 / 错误恢复
- AI agent 模式（非中文环境）
- probe 验证代理生效
