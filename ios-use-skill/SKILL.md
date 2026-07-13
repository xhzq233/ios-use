---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices via CLI. Primary scope: real-device/session setup, DOM-first UI inspection, tap/swipe/input actions, app lifecycle, and log collection. Simulator; HTTP/HTTPS proxy capture."
---

# ios-use Skill

## 1. 职责边界

- 抓 HTTP/HTTPS 包、证书、mitmdump、过滤表达式：看 `references/proxy.md`
- 使用或排查 Simulator：看 `references/simulator.md`
- 维护旧 NSLogger / `nslog`：看 `references/nslog.md`
- 整理故障报告并提交 GitHub Issue：看 `references/report.md`

## 2. 前置要求

先安装 `ios-use`：

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

真机首次执行需要操作设备屏幕的命令，或升级到新版本后，按这个顺序准备：

```bash
ios-use status
ios-use config --udid <udid>
ios-use start
```

- `status` 用来查看 USB 真机、当前 driver、日志采集、NSLog、Proxy、配置状态；不列出 Simulator。需要 Simulator UDID 时用 `xcrun simctl list devices booted` 自行查询。
- 设备未显示 `configured`，或显示 `driver update required`，先重新执行 `ios-use config --udid <udid>`。
- 设备显示 `signing expires soon` 表示签名剩余不超过 1 天；显示 `signing expired`，或 `start` 输出 signing expired warning 时，优先重新执行 `ios-use config --udid <udid>`。`start` 会继续尝试启动，失败时不要只解释成“去设备上信任开发者”。
- 首次配置真机需要用**免费 Apple 开发者账号**（Personal Team，注意不是普通个人 Apple ID；无需付费 $99/年）签名。让用户在终端运行 `ios-use config --udid <udid> --apple-id <email>`，省略 `--password`，命令会交互提示输入该开发者账号的**登录密码**（隐藏输入）。若账号开启了双重认证，6 位验证码会在签名过程中单独提示输入。不要通过命令行参数或文档传递密码。
- 真机必须 USB 连接且系统版本为 iOS 17.4+；只通过 Wi-Fi 连接的设备不可用。

## 3. 目标设备与命令边界

- `start` 会启动第一个 USB 真机的 driver；多台真机时，用 `start <udid>` 明确指定。
- 启动后，该设备会成为后续 driver-backed 命令的目标。
- 切换设备时先 `ios-use stop`，再 `ios-use start <new-udid>`。
- `dom` / `tap` / `swipe` / `input` / `waitFor` / `screenshot` / `capture` / `home` / `dismissAlert` / `proxy configca` / `proxy start` / `proxy stop` 都使用最近一次 `start` 选中的设备，不接受自己的 `--udid`；执行前先运行 `ios-use start`。
- `status` 不接受 `--udid`，只汇总当前环境状态；`config` / `install` / `uninstall` / `apps` / `ddi-mount` / `open` / `activateApp` / `terminateApp` / `oslog` 可使用 `--udid`。省略时，部分命令会使用当前 active target。
- `proxy start --server` / `proxy stop --server` 只管理本机 mitmdump，不要求当前设备 driver。
- 真机 `status` / `config` / `install` / `uninstall` / `apps` / `ddi-mount` / `start` / `stop` / `open` / `activateApp` / `terminateApp` / `oslog` 不要求 Xcode CLI；查询 Simulator UDID 时才需要 Xcode CLI，可运行 `xcrun simctl list devices booted`。

## 4. 操作原则

- 一切先以 DOM 为准。每次切页面、滚动后、找不到元素时，先跑 `ios-use dom`，确认页面状态再继续。
- 推荐操作顺序：先观察当前页面，再定位目标，接着执行动作，最后按需要确认结果。常见链路是 `dom` / `waitFor` -> `tap` / `swipe` / `input` -> `--dom` 或再次 `dom`。
- 可以同时发起不互相依赖的只读观察命令；有页面状态依赖的命令仍建议按顺序执行，尤其是 `tap` / `swipe` / `input` 这类会改变界面的动作。
- DOM 无法描述视觉内容，或用户明确要求视觉验收时，才用 `screenshot`。

## 5. 推荐工作流

### 5.1 准备并进入目标 App

```bash
ios-use start
ios-use activateApp com.apple.Preferences
ios-use dom
```

### 5.2 探索页面

```bash
ios-use dom
ios-use dom --raw
ios-use dom --wait-quiescence
ios-use waitFor --label "蓝牙" --timeout 8
```

### 5.3 执行动作

```bash
ios-use tap "通用"
ios-use tap "亮度" --offset-ratio 0.8,0.5
ios-use longpress "通用"
ios-use swipe --to "开发者" --from "蓝牙" # 从"蓝牙"开始，寻找"开发者"
ios-use swipe --dir forth --distance 300
ios-use input --tap "搜索" --content "蓝牙"
```

动作后需要立即确认页面状态时，可在支持的动作上加 `--dom [ms]`：

```bash
ios-use tap "通用" --dom
ios-use input --tap "搜索" --content "蓝牙" --dom 300
```

裸 `--dom` 会等待界面平静后返回 fresh DOM；显式 `--dom <ms>` 会等待指定毫秒后返回 fresh DOM。
显式毫秒值必须不小于 `100`；需要立即跟进页面状态时用裸 `--dom`。

### 5.4 App、URL 和弹窗

```bash
ios-use activateApp com.apple.Preferences
ios-use activateApp com.example.app --terminateExisting --log
ios-use terminateApp com.apple.Preferences
ios-use open "https://example.com"
ios-use dismissAlert
ios-use dismissAlert --index 0
```

### 5.5 管理真机 App

```bash
ios-use apps
ios-use apps --json
ios-use apps --udid <udid>
ios-use ddi-mount --udid <udid>
ios-use install path/to/app.ipa
ios-use install path/to/App.app
ios-use install path/to/app.ipa --udid <udid>
ios-use uninstall com.example.app
ios-use uninstall com.example.app --udid <udid>
```

这些命令直接走真机设备服务。`ddi-mount` 用于挂载 iOS 17+ Developer Disk Image；省略 `--path` 时扫描本机 DDI 缓存。

如果本机没有与设备系统版本匹配的 DDI，可从当前 fallback 地址下载：

```text
https://deviceboxhq.com/ddi-17E5179g.zip
```

下载后解压，向 `--path` 传入匹配的 `Restore/`、`iOS_DDI/` 或 `.dmg` 路径。版本不匹配时不要强行挂载；CLI 不会自动联网下载 DDI。

`install` 只接受已签名 `.ipa` 或 `.app`，不负责给任意 App 自动签名。卸载前确认 bundle ID，避免误删真实 App。

## 6. 常用命令速查

### 6.1 `dom`

- `ios-use dom` 输出 clean tree。
- `ios-use dom --raw` 输出原始界面树文本，排查 DOM 异常时使用。
- `ios-use dom --wait-quiescence` 等待界面平静后返回 fresh clean DOM。
- `dom --raw` 只能单独使用，不能和 `--fresh` / `--wait-quiescence` 组合。
- DOM 行中的 `label=value [traits] (x,y,w,h)` 表示 label 和 value 都可作为 target 查询，`[traits]` / 坐标是元信息，不要把整行或 `label=value` 拼成 target。
- 展示层追加的 `vertical` / `horizontal` 只用于阅读，不要当成 `tap/waitFor/swipe --traits` 的可过滤 trait。

### 6.2 `waitFor`

- `--traits <traits>` 按 DOM 展示出来的 traits 过滤，逗号分隔多值，AND 语义。
- `--cindex <int>` 先找父元素再选 DOM 中显示的第 N 个直接子元素，`-1` 表示最后一个。
- `waitFor` 用 `--label <text> --timeout <seconds>` 轮询等待元素出现；加 `--gone` 时等待匹配元素消失。

### 6.3 `tap` / `longpress`

- `<target>` 是元素 label 或 `"x,y"` 坐标。
- 坐标 target 不支持 `traits` / `cindex` / `offset` / `offsetRatio`。
- `tap --offset "x,y"` 是相对目标元素左上角的像素偏移。
- `tap --offset-ratio "x,y"` 是相对目标元素宽高的比例偏移。
- `longpress` 默认 `500ms`，可用 `--duration <ms>` 调整。
- `tap` / `longpress` 支持 `--dom [ms]`，成功后追加 fresh DOM。

### 6.4 `swipe`

- 找目标时，目标导向优先：`ios-use swipe --to "开发者" --from "蓝牙"`。
- 目标不在当前屏幕时必须传 `--from`，用当前可见元素作为滚动锚点。
- 固定距离：`ios-use swipe --dir forth --distance 300` 或 `--dir back`。
- `forth` 表示继续往前浏览当前列表，`back` 表示反方向回拉。
- `--cindex` 只作用于 `--to` 目标，不作用于 `--from`。
- 支持 `--dom [ms]`。

### 6.5 `input`

- `ios-use input --tap "搜索" --content "蓝牙"`，或已有文本焦点后 `ios-use input --content "蓝牙"`。
- `--tap` 只用于输入前聚焦；不传 `--tap` 时向当前文本焦点输入。
- `--delete <n>` 会在 content 前发送 n 个删除字符。
- `--enter` 会发送尾随换行符，可触发 Enter、Done、Go、发送等行为。
- 支持 `--traits` / `--cindex` / `--dom [ms]`。

### 6.6 `screenshot`

- 截图并输出保存路径；默认同时运行 macOS Vision 的 accurate OCR，并输出 OCR 文本、坐标和 `.ocr.json` sidecar。
- 只需要像素时使用 `ios-use screenshot --no-ocr --name pixels-only`；OCR 失败不会影响已经写入的截图，但会返回 warning。
- 只在用户明确要求查看视觉效果，或 DOM 无法说明视觉状态时使用。

### 6.7 `capture`

```bash
ios-use tap "站姿1" && ios-use capture --fps 10 --duration 3 --name pose-sweep
```

- `capture` 只做固定时长的截图采样，不内置 tap、trigger、wait 或 shell 执行。
- `--fps` 范围为 `(0, 10]`，默认 `10`；`--duration` 默认 `3` 秒。
- 输出目录只有 JPEG 帧和 `manifest.json`，不生成 GIF、视频、contact sheet 或 OCR sidecar。
- `--keep-changed-frames` 可只保留 JPEG 字节发生变化的采样帧；manifest 仍记录所有采样槽位。

## 7. Proxy 入口

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

## 8. 日志

### 8.1 App 启动日志

```bash
ios-use activateApp com.example.app --terminateExisting --log
ios-use terminateApp com.example.app
```

- 用 `activateApp --terminateExisting --log` 重新启动 App；命令会直接返回日志文件路径。用 `rg`、`tail` 或 `less` 查询该文件，例如 `rg -n -i 'error|warning' <log-file>`。
- `--log` 必须和 `--terminateExisting` 一起使用。
- `terminateApp` 后采集进程会随 App 退出自动结束；再次 `activateApp --log` 会替换上一轮采集。

### 8.2 `oslog`

```bash
ios-use oslog --process IOSUseDriver-Runner --timeout 5
ios-use oslog --pid 123 --timeout 5
ios-use oslog --pattern "error|failed" --flags i --timeout 10
```

- 省略 `--udid` 时使用当前 active target。
- 真机前台 stream 到超时。
- `--timeout` 必须大于 0；`0` 不合法。
- `--process <name>` 或 `--pid <pid>` 过滤单个日志来源，二者互斥，只过滤日志，不切 app。
- 日志直接输出到 stdout，不写 artifact；需要落盘时自行重定向或使用 `tee`。

- 需要系统 unified log、`os_log` 或更宽的系统日志时用 `oslog`。
- 旧 NSLogger / `nslog` 只在 App 已接入 NSLogger 时使用，见 `references/nslog.md`。

## 9. 常见排障

遇到无法解决的问题时，可以先到 GitHub Issues 搜索相似问题，再决定是否整理报告。需要主动提交 GitHub Issue 时，用户明确说“提交吧”这类提交意图即可；确认后再看 `references/report.md`，按模板收集失败命令、`status`、配置摘要和必要日志尾部，并在提交前脱敏 Apple ID、完整 UDID、证书、密码和业务 App 私有日志。Issue 查询、创建、关闭优先用 `gh` CLI；本机没有 `gh` 时先安装 GitHub CLI。

签名异常时，先重新运行 `ios-use config --udid <udid>`，再运行 `ios-use start <udid>`。常见情况：

- `config` 输出 `Driver signing warnings` 时，先看随后是否成功安装；这是 profile、UDID、bundle id 或 codesign 的风险提示，不一定阻塞安装。
- `driver update required` 表示 CLI/driver 版本不匹配；`signing expired` 表示已安装 driver 的开发者签名过期。两者都重新运行 `ios-use config --udid <udid>`；`start` 遇到 expired 通常只给 warning，但仍应刷新签名。
- altsign 返回 HTTP 4xx，优先检查 Apple Developer 账号状态、Apple ID 和交互式认证是否有效，然后重试 `config`。
- altsign 返回 HTTP 5xx，优先检查网络、VPN 或代理，稍后再重试；不要反复修改设备 UI 状态来解决服务端错误。
- 如果签名成功但启动仍失败，再检查设备上的开发者信任状态和 driver/设备版本是否匹配，不要把所有失败都归因于“信任开发者”。

不要把密码、验证码、证书或完整签名 profile 放进命令参数、日志或报告；需要上游报告时按 `references/report.md` 收集并脱敏证据。
