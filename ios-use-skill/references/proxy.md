# Proxy 抓包完整指南

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
mitmdump -r <flow文件> [过滤表达式] --set flow_detail=<级别>
```

## 2. flow 文件

`proxy start` 成功后会输出抓包文件路径，格式为：

```
ℹ Capture: /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.flow
ℹ View with: mitmweb -r /Users/xxx/.ios-use/artifacts/proxy-2026-05-13T05-33-13-861Z.flow
```

文件保存在 `~/.ios-use/artifacts/`，命名格式 `proxy-<ISO-timestamp>.flow`。

也可以从 proxy session 状态获取：

```bash
cat ~/.ios-use/state/proxy-session.json | grep flowFile
```

## 3. mitmdump 查看抓包

### 3.1 flow_detail 级别

| 级别 | 内容 |
|------|------|
| `0` | 不输出 body |
| `1` | 每个请求一行摘要 |
| `2` | + 请求/响应 headers |
| `3` | + 完整 body（默认） |

### 3.2 列出所有请求

```bash
mitmdump -r file.flow
```

### 3.3 过滤语法

过滤表达式作为最后一个参数传入：

```bash
# 按域名
mitmdump -r file.flow "~d example.com"

# 按 URL 路径（子串匹配）
mitmdump -r file.flow "~u /api/"

# 按 HTTP method
mitmdump -r file.flow "~m POST"

# 按状态码
mitmdump -r file.flow "~c 404"

# 按请求 body 内容
mitmdump -r file.flow "~b password"

# 组合（AND 用 &，OR 用 |）
mitmdump -r file.flow "~d example.com & ~m POST"
mitmdump -r file.flow "~d a.com | ~d b.com"

# 取反
mitmdump -r file.flow "!~d apple.com"
```

### 3.4 查看单个请求完整详情

```bash
mitmdump -r file.flow --set flow_detail=3 "~d serverstatus.apple.com"
```

### 3.5 导出为 HAR

```bash
mitmdump -r file.flow --set hardump=output.har
```

## 4. 命令参考

| 命令 | 说明 |
|------|------|
| `proxy configca` | 安装并信任 mitmproxy CA（一次性） |
| `proxy start [-i <interface>]` | 启动抓包 + 配置设备 Wi-Fi 代理 |
| `proxy stop` | 清除设备 Wi-Fi 代理 + 停止抓包 |
| `proxy doctor` | 诊断 proxy 环境 |

### proxy start 选项

- `-i, --interface <iface>` — 指定 Mac 网卡（默认自动选 Wi-Fi）

### proxy start 行为

1. 检测 Mac Wi-Fi interface / LAN IP
2. 验证设备能访问 Mac LAN IP（probe server + Safari openURL）
3. 启动 mitmdump（后台 detached 进程），抓包保存为 `.flow` 文件
4. 通过 UI flow 配置设备当前 Wi-Fi 的 HTTP 代理指向 Mac
5. 输出 flow 文件路径，命令立即返回（mitmdump 在后台持续运行）

### proxy stop 行为

必须先清除设备代理再停 mitmdump，否则设备断网。顺序：

1. UI flow 关闭设备 Wi-Fi 代理
2. SIGTERM 停止 mitmdump
