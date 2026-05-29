# Proxy 抓包操作手册

## 1. 完整流程

```bash
# 0. 确保 mitmdump 已安装
pip install mitmproxy

# 1. 一次性：安装并信任 CA（HTTPS 解密所需，HTTP 抓包可跳过）
ios-use proxy configca

# 2. 启动抓包（后台运行，立即返回）
ios-use proxy start

# 3. （操作设备，产生流量...）

# 4. 停止抓包
ios-use proxy stop

# 5. 查看抓包数据（读取最近一次 proxy start 写入的 last capture）
ios-use proxy read [--filter <表达式>] [--raw] [--last N]
```

## 2. 抓包文件

`proxy start` 成功后会输出抓包文件路径，格式为：

```
ℹ Capture: /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.mitm
ℹ View with: mitmweb -r /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.mitm
ℹ Read with: ios-use proxy read
```

文件保存在 `~/.ios-use/artifacts/`，命名格式 `proxy-<ISO-timestamp>.mitm`。`proxy start` 会把本次文件写为 last capture；`proxy stop` 不会删除 last capture，stop 后仍可继续用 `ios-use proxy read` 读取。

## 3. 查看抓包

### 3.1 ios-use proxy read

```bash
# 摘要
ios-use proxy read

# 完整 headers + body
ios-use proxy read --raw

# 过滤
ios-use proxy read --filter "~d example.com"
ios-use proxy read --filter "~m POST"

# 只看最后 N 行
ios-use proxy read --last 20
```

`proxy read` 只读取最近一次 `proxy start` 记录的 last capture。`--last` 必须大于 0。没有 last capture 或文件已删除时，先运行 `ios-use proxy start`。

### 3.2 需要 mitmproxy 工具链时

默认先用 `ios-use proxy read`。只有需要 GUI、HAR 导出或 `proxy read` 无法满足的高级过滤时，才直接使用 mitmproxy 工具链。

```bash
mitmweb -n -r file.mitm
mitmdump -n -r file.mitm "~d example.com & ~m POST"
mitmdump -n -r file.mitm --set hardump=output.har
```

## 4. 命令参考

| 命令 | 说明 |
|------|------|
| `proxy configca` | 安装并信任 mitmproxy CA；若需要设备密码或手动信任证书，完成后用 `--mark-trusted` 记录人工确认 |
| `proxy configca --mark-trusted` | 不 push CA、不执行安装 flow，只在已有当前 CA 文件时记录人工确认 |
| `proxy start [--server] [-i <interface>]` | 默认启动抓包 + 配置设备 Wi-Fi 代理，并记录 last capture；`--server` 只启动本机 mitmdump |
| `proxy read [--filter <expression>] [--raw] [--last N]` | 读取最近一次 `proxy start` 记录的 last capture，`proxy stop` 后仍可读 |
| `proxy stop [--server]` | 默认清除设备 Wi-Fi 代理 + 停止抓包；`--server` 只停止本机 mitmdump |
| `proxy doctor` | 诊断 proxy 环境 |

### proxy start 选项

- `-i, --interface <iface>` — 指定 Mac 网卡（默认自动选 Wi-Fi）
- `--server` — 只启动本机 mitmdump server，不配置设备 Wi-Fi 代理；后续仍可用 `proxy read` 读取 last capture

### proxy start 行为

1. 检测 Mac Wi-Fi 网卡和局域网 IP
2. 启动本地抓包进程，抓包保存为 `.mitm` 文件
3. 自动把设备当前 Wi-Fi 的 HTTP 代理指向 Mac
4. 输出抓包文件路径，命令立即返回（mitmdump 在后台持续运行）

网络前提：设备与 Mac 需要在同一 Wi-Fi/LAN，且设备能访问 Mac 的抓包端口。VPN、防火墙或隔离 Wi-Fi 可能导致抓不到流量或设备断网。排障先运行 `ios-use proxy doctor`，再检查 Mac 网卡/IP、防火墙和设备网络。

### proxy stop 行为

默认必须先清除设备代理再停 mitmdump，否则设备断网。顺序：

1. 自动关闭设备 Wi-Fi 代理
2. 停止本地抓包进程

`proxy stop --server` 只停止本机 mitmdump，不清设备 Wi-Fi 代理；只有明确知道设备代理已手动关闭或只想保留设备设置时才使用。
