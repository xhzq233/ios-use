---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices via CLI. Primary scope: device/session setup, DOM-first UI inspection, tap/swipe/input actions, app lifecycle, and log collection. For YAML Flow authoring route to references/flow.md; for HTTP/HTTPS proxy capture route to references/proxy.md."
---

# ios-use Skill

## 1. 职责边界

这个 Skill 的主文件只负责给 agent 一个稳定的操作口径：

- 如何准备设备和选择当前目标设备
- 如何用 `dom` / `find` 先确认页面，再串行执行 UI 操作
- 常用单步命令、日志命令和排障入口
- 什么时候转去专门 reference

不要把所有子系统教程都塞进本文件：

- 写或维护 YAML Flow：看 `references/flow.md`
- 抓 HTTP/HTTPS 包、证书、mitmdump、过滤表达式：看 `references/proxy.md`
- 当前 CLI/Flow/API 的完整用户可见契约：以项目内 `docs/private/design/cli/command_api.md` 为准

## 2. 前置要求

先安装 `ios-use`：

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

安装完成后，命令直接使用 `ios-use`。安装路径默认 `$HOME/.local/bin`，不在 `PATH` 时安装脚本会提示。

真机首次执行需要操作设备屏幕的命令，或升级到新版本后，按这个顺序准备：

```bash
ios-use devices
ios-use config --udid <udid>
ios-use start <udid>
```

- `devices` 用来查看设备列表、UDID 和配置状态。
- 设备未显示 `configured`，或显示 `driver update required`，先重新执行 `ios-use config --udid <udid>`。
- 首次配置真机可能需要 Apple ID 和 2FA。出现这类交互时，让用户在终端手动运行带账号参数的 `config` 命令。
- Simulator 免签名：`ios-use config --simulator --udid <sim-udid>`。
- 真机必须 USB 连接；只通过 Wi-Fi 连接的设备不可用。

## 3. 目标设备与命令边界

- `start <udid>` 会启动已配置设备的 driver，并把它设为后续 driver-backed 命令的目标。
- 切换设备时先 `ios-use stop`，再 `ios-use start <new-udid>`。
- `dom` / `find` / `tap` / `swipe` / `input` / `waitFor` / `screenshot` / `activateApp` / `terminateApp` / `home` / `dismissAlert` / `flow` / `proxy configca` / `proxy start` / `proxy stop` 都依赖当前 `driver.lock`，不接受自己的 `--udid`。
- `devices` / `config` / `install` / `uninstall` / `apps` / `open` / `oslog` 可使用 `--udid`。省略时，部分命令会使用当前 `driver.lock`。
- `proxy start --server` / `proxy stop --server` 只管理本机 mitmdump，不要求当前设备 driver。
- 真机 `devices` / `config` / `install` / `uninstall` / `apps` / `start` / `stop` / `open` / `oslog` 不要求 Xcode CLI；Simulator 使用仍需要 Xcode / `simctl`。

## 4. 操作原则

- 一切先以 DOM 为准。每次切页面、滚动后、找不到元素时，先跑 `ios-use dom` 或 `ios-use find`，确认页面状态再继续。
- 不要猜 bundle ID、label、按钮位置或页面状态。当前信息不足时先查设备状态，或者问用户。
- 同一设备上的 UI 命令必须串行执行，不要并发运行 `dom` / `find` / `tap` / `swipe` / `input` / `waitFor` / `screenshot`。
- 默认不截图。只有 DOM 无法描述视觉内容，或用户明确要求视觉验收时，才用 `screenshot`。
- 不知道下一步是否安全时，先 `dom --fresh`，再决定动作。

## 5. 推荐工作流

### 5.1 准备并进入目标 App

```bash
ios-use devices
ios-use start <udid>
ios-use activateApp com.apple.Preferences
ios-use dom
```

### 5.2 探索页面

```bash
ios-use dom
ios-use dom --raw
ios-use dom --fresh
ios-use find "蓝牙"
ios-use waitFor --label "蓝牙" --timeout 8
```

### 5.3 执行动作

```bash
ios-use tap "通用"
ios-use tap "亮度" --offset-ratio 0.8,
ios-use longpress "通用"
ios-use swipe --to "开发者" --from "蓝牙"
ios-use swipe --dir forth --distance 300
ios-use input --tap "搜索" --content "蓝牙"
```

动作后需要立即确认页面状态时，可在支持的动作上加 `--dom [ms]`：

```bash
ios-use tap "通用" --dom
ios-use input --tap "搜索" --content "蓝牙" --dom 300
```

### 5.4 App、URL 和弹窗

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
ios-use open "https://example.com"
ios-use dismissAlert
ios-use dismissAlert --index 0
```

`open <url>` 是 host-side 命令。省略 `--udid` 时使用当前 `driver.lock`，显式 `--udid` 优先；无 App 注册 scheme 时会报 `URL scheme "xxx" not registered on device`。

### 5.5 管理真机 App

```bash
ios-use apps
ios-use apps --json
ios-use apps --udid <udid>
ios-use install path/to/app.ipa
ios-use install path/to/app.ipa --udid <udid>
ios-use uninstall com.example.app
ios-use uninstall com.example.app --udid <udid>
```

这些命令直接走真机设备服务，不需要先 `start`，但省略 `--udid` 时需要 active 真机 lock。`install` 只安装已签名 IPA，不负责给任意 App 自动签名。卸载前确认 bundle ID，避免误删真实 App。

## 6. 常用命令速查

### 6.1 `dom`

- `ios-use dom` 输出 clean tree。
- `ios-use dom --raw` 输出原始界面树文本，排查 DOM 异常时使用。
- `ios-use dom --fresh` 忽略缓存重新获取。
- DOM type 使用短名，例如 `Text`、`Input`、`Scroll`、`Collection`。
- 展示层追加的 `vertical` / `horizontal` 只用于阅读，不要当成 `find/tap/waitFor/swipe --traits` 的可过滤 trait。

### 6.2 `find` / `waitFor`

- `ios-use find <label>` 查找元素。完整 label 优先 exact；无 exact 时回退 contains。
- `--traits <traits>` 按 DOM 展示出来的 traits 过滤，逗号分隔多值，AND 语义。
- `--cindex <int>` 先找父元素再选 DOM 中显示的第 N 个直接子元素，`-1` 表示最后一个。
- `waitFor` 用 `--label <text> --timeout <seconds>` 轮询等待元素出现。

### 6.3 `tap` / `longpress`

- `<target>` 是元素 label 或 `"x,y"` 坐标。
- 坐标 target 不支持 `traits` / `cindex` / `offset` / `offsetRatio`。
- `tap --offset "x,y"` 是相对目标元素左上角的像素偏移。
- `tap --offset-ratio "x,y"` 是相对目标元素宽高的比例偏移。
- `longpress` 默认 `500ms`，可用 `--duration <ms>` 调整。
- `tap` / `longpress` 支持 `--dom [ms]`，成功后追加 fresh DOM。

### 6.4 `swipe`

- 目标导向优先：`ios-use swipe --to "开发者" --from "蓝牙"`。
- 目标不在当前屏幕时必须传 `--from`，用当前可见元素作为滚动锚点。
- 固定距离：`ios-use swipe --dir forth --distance 300` 或 `--dir back`。
- `forth` 表示继续往前浏览当前列表，`back` 表示反方向回拉。
- `--cindex` 只作用于 `--to` 目标，不作用于 `--from`。
- 支持 `--dom [ms]`。

### 6.5 `input`

- `ios-use input --tap "搜索" --content "蓝牙"`，或键盘已弹出后 `ios-use input --content "蓝牙"`。
- `--tap` 只用于输入前聚焦；不传 `--tap` 时要求键盘已可见。
- 不隐式 clear。
- 支持 `--traits` / `--cindex` / `--dom [ms]`。

### 6.6 `screenshot`

- 截图并输出保存路径。
- 只在用户明确要求查看视觉效果，或 DOM 无法说明视觉状态时使用。

## 7. Flow 入口

写 Flow 时不要在主文件里查完整语法，直接看 `references/flow.md`。

最小运行入口：

```bash
ios-use flow my-flow.yaml
ios-use flow my-flow.yaml --targetLabel 蓝牙 --timeout 5
```

关键边界：

- Flow 目标就是最近一次 `ios-use start <udid>` 的设备，不支持 `--udid`。
- 写 flow 前先用 CLI 手动跑通每一步，再组装成 YAML。
- Flow 执行前会先检查整份 YAML；未知字段、明显类型错误和可提前发现的 subflow 错误会在任何设备动作前失败。
- Flow 中坐标、offset、offsetRatio 都写成和 CLI 参数一致的字符串。
- `needNSLog: true` 是 Flow 内使用 `nslog` action 的入口；不要使用旧字段 `needLog` / `nslog_start`。

## 8. Proxy 入口

Proxy 是抓包子系统，详细步骤看 `references/proxy.md`，主文件只保留入口和硬前提。

```bash
ios-use proxy configca
ios-use proxy start
ios-use proxy stop
ios-use proxy read
ios-use proxy read --filter "~d example.com" --raw
```

关键边界：

- `proxy configca` / 默认 `proxy start` / 默认 `proxy stop` 需要当前 active driver。
- `proxy start --server` / `proxy stop --server` 只管理本机 mitmdump，不配置设备代理。
- 设备与 Mac 需要在同一 Wi-Fi/LAN，且设备能访问 Mac 的抓包端口。VPN、防火墙或隔离 Wi-Fi 可能导致抓不到流量或设备断网。
- HTTPS 解密需要先安装并信任 CA。需要手动信任时，完成后用 `ios-use proxy configca --mark-trusted` 记录人工确认。
- 排障先运行 `ios-use proxy doctor`。

## 9. 日志

### 9.1 `oslog`

```bash
ios-use oslog --process IOSUseDriver-Runner --timeout 5
ios-use oslog --pid 123 --timeout 5
ios-use oslog --pattern "error|failed" --flags i --timeout 10
```

- 省略 `--udid` 时使用当前 `driver.lock`。
- 真机前台 stream 到超时，Simulator 在窗口期内轮询匹配。
- `--timeout 0` 表示不等待。
- `--process <name>` 或 `--pid <pid>` 过滤单个日志来源，二者互斥，只过滤日志，不切 app。
- 日志直接输出到 stdout，不写 artifact；需要落盘时自行重定向或使用 `tee`。

### 9.2 `nslog`

```bash
ios-use nslog
ios-use nslog start
ios-use nslog read --pattern "finished" --timeout 10
ios-use nslog read --last 50
ios-use nslog stop
```

- `nslog` 启动本地 NSLogger server，iOS app 主动推送日志。最好在 app 启动前启动。
- 前台 streaming 时，监听信息写 stderr，日志行写 stdout。
- `nslog start` 后台采集并写入 `~/.ios-use/logs/nslog-*.log`。
- `nslog read` 从最近一次后台采集读取；`stop` 后日志文件保留。
- 如果提示 stale local publisher 或 live nslog server，按提示清掉旧 `dns-sd` 或关闭旧 NSLogger viewer 后重试。

## 10. 常见排障

设备或 driver 连不上：

```bash
ios-use devices
ios-use config --udid <udid>
ios-use start <udid>
```

行为和预期不一致：

- 先 `ios-use dom`
- 再 `ios-use find <label>`
- DOM 无法解释时再补 `ios-use screenshot`
- 需要更多细节时加 `--verbose`

签名异常：

- altsign 出现 HTTP 4xx，常见原因是 Apple Developer 账号状态或凭据问题。
- altsign 出现 HTTP 5xx，优先检查网络或 VPN。
