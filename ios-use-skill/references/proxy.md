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

# 5. 查看抓包数据
ios-use proxy read [--filter <表达式>] [--raw] [--last N]
```

## 2. 抓包文件

`proxy start` 成功后会输出抓包文件路径，格式为：

```
ℹ Capture: /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.mitm
ℹ View with: mitmweb -r /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.mitm
ℹ Read with: ios-use proxy read
```

文件保存在 `~/.ios-use/artifacts/`，命名格式 `proxy-<ISO-timestamp>.mitm`。`proxy-session.json.lastCapture` 保存最近一次抓包，因此 `proxy stop` 后仍可继续读取历史文件。

也可以从 proxy session 状态获取：

```bash
cat ~/.ios-use/state/proxy-session.json | grep flowFile
```

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

`--last` 必须大于 0。没有最近一次抓包或文件已删除时，先运行 `ios-use proxy start`。

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
| `proxy configca` | 安装并信任 mitmproxy CA；若本地记录显示当前 CA 已安装并信任，会直接跳过安装 flow |
| `proxy start [-i <interface>]` | 启动抓包 + 配置设备 Wi-Fi 代理 |
| `proxy read [--filter <expression>] [--raw] [--last N]` | 读取最近一次抓包 |
| `proxy stop` | 清除设备 Wi-Fi 代理 + 停止抓包 |
| `proxy doctor` | 诊断 proxy 环境 |

### proxy start 选项

- `-i, --interface <iface>` — 指定 Mac 网卡（默认自动选 Wi-Fi）

### proxy start 行为

1. 检测 Mac Wi-Fi interface / LAN IP
2. 验证设备能访问 Mac LAN IP（probe server + Safari openURL）
3. 启动 mitmdump（后台 detached 进程），抓包保存为 `.mitm` 文件
4. 通过 UI flow 配置设备当前 Wi-Fi 的 HTTP 代理指向 Mac
5. 输出抓包文件路径，命令立即返回（mitmdump 在后台持续运行）

### proxy stop 行为

必须先清除设备代理再停 mitmdump，否则设备断网。顺序：

1. UI flow 关闭设备 Wi-Fi 代理
2. SIGTERM 停止 mitmdump
