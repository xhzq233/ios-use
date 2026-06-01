---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices via CLI. Covers device management, UI element inspection (dom/find), tap/swipe/input actions, oslog/nslog, app lifecycle, HTTP/HTTPS proxy capture, and YAML flow authoring. Use this skill when the user wants to interact with an iOS device, inspect screen elements, automate UI steps, capture network traffic, write or debug automation flows, or check device logs."
---

# ios-use Skill

## 1. 前置要求

- 先安装 `ios-use`：

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

- 安装完成后，所有命令都直接使用 `ios-use`
- 真机首次执行需要操作设备屏幕的命令，或升级到新版本后，先执行：

```bash
ios-use devices               # 查看设备列表、udid 和配置状态
ios-use config --udid <udid>  # 完成设备配置（显示 configured 后即可使用）
ios-use start <udid>          # 启动并选择当前要操作的设备
```

- 如果 `ios-use devices` 显示 `driver update required`，必须重新执行 `ios-use config --udid <udid>`。
- 首次配置真机时可能需要补 Apple ID，并触发 Apple 2FA 验证码输入。出现这类提示时，需要用户在终端手动运行：`ios-use config --udid <udid> --apple-id <your-apple-id> --password '<app-specific-password>'`
- Simulator 免签名：`ios-use config --simulator --udid <sim-udid>`
- `start <udid>` 会启动已配置设备的 driver，并把它设为后续操作目标；`dom/find/tap/swipe/input/waitFor/screenshot/activateApp/terminateApp/home/dismissAlert/flow/proxy configca/proxy start/proxy stop` 等命令必须先 start，且不再接受自己的 `--udid`；`proxy start --server` / `proxy stop --server` 只管理本机 mitmdump，不要求 start
- `open <url> [--udid <udid>]` 是 host-side 命令；省略 `--udid` 时使用当前 `driver.lock`，显式 `--udid` 优先。`install <ipa>`、`uninstall <bundleId>`、`apps` 只支持 USB 真机，省略 `--udid` 时也必须已有 active 真机 lock
- 安装路径默认 `$HOME/.local/bin`，不在 PATH 时脚本会提示

## 2. 硬规则

- 真机必须 USB 连接；只通过 Wi-Fi 连接的设备不可用
- `devices` / `config` / `install` / `uninstall` / `apps` / `open` / `oslog` 可使用 `--udid`；其他需要操作屏幕或当前设备状态的命令、Flow、proxy configca/start/stop 不接受 `--udid`，目标就是最近一次 `start` 的设备；proxy 的 `--server` 子路径只操作本机服务
- 真机 `devices` / `config` / `install` / `uninstall` / `apps` / `start` / `stop` / `open` / `oslog` 不要求 Xcode CLI；Simulator 使用仍需要 Xcode / simctl。
- 操作屏幕或当前设备状态前，先 `ios-use devices` 确认设备已连接且显示 `configured`，且没有 `driver update required`，然后运行 `ios-use start <udid>`
- 同一设备上的 `dom` / `find` / `tap` / `swipe` / `input` / `waitFor` / `screenshot` 等 UI 命令必须串行执行；不要并发运行多个 UI 命令，否则容易读失败或误判页面状态
- 执行动作前，多用 `dom` 查看当前页面状态，不要盲点
- **不要猜**：每一步执行前，用 `dom`/`find` 确认当前页面状态，不要凭猜测执行。尤其是 bundle ID，如果不知道目标 app 的 bundle ID，问用户或从设备上查找（如通过 Spotlight、App Store 链接、或 dom 查看 home screen），不要逐个尝试猜测变体
- **截图策略**：默认以 `dom`/`find` 理解页面，不主动截图。只有以下场景才用 `screenshot`：(1) DOM 无法描述的视觉内容（颜色、布局、图片、动画状态）；(2) 用户明确要求看最终效果或视觉验收。不要在每一步自动截图

## 3. 推荐工作流

### 3.1 前置准备

```bash
ios-use devices               # 确认设备已连接且 configured
```

设备未显示 `configured`，或显示 `driver update required` 时，先执行 `ios-use config --udid <udid>`。
操作屏幕或当前设备状态前执行 `ios-use start <udid>`；`stop` 会停止当前设备的 driver。需要切换设备时先 `stop` 再 `start <new-udid>`。

需要操作特定 app 时先 `activateApp`：

```bash
ios-use activateApp com.apple.Preferences
ios-use dom
```

### 3.2 先用 dom 探索页面

```bash
ios-use dom                        # 先看当前页面元素树
ios-use dom --raw                  # 原始界面树文本，调试用
ios-use dom --fresh                # 忽略缓存，重新构建
ios-use find "蓝牙"                # 在 dom 基础上查目标元素
ios-use waitFor --label "蓝牙" --timeout 8
```

建议：每次切页面、滚动后、找不到元素时，都先补一次 `dom`，确认页面状态再继续。

### 3.3 执行动作

```bash
ios-use tap "通用"
ios-use tap "亮度" --offset-ratio 0.8,
ios-use longpress "通用"
ios-use swipe --to "开发者" --from "蓝牙"
ios-use swipe --dir forth --distance 300            # 纯距离滚动
ios-use input --label "搜索" --content "蓝牙"      # 不需要先 tap，会自动切换焦点
```

### 3.4 切 app

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
```

### 3.4.1 管理真机 App

```bash
ios-use apps
ios-use apps --json
ios-use apps --udid <udid>
ios-use install path/to/app.ipa
ios-use install path/to/app.ipa --udid <udid>
ios-use uninstall com.example.app
ios-use uninstall com.example.app --udid <udid>
```

这些命令直接走真机设备服务，不需要先 `start`，但省略 `--udid` 时需要 active 真机 lock。`install` 只安装已签名 IPA，不负责给任意 App 自动签名；卸载前确认 bundle ID，避免误删用户设备上的真实 App。Simulator app 安装/卸载不走这些顶层命令。

### 3.5 打开 URL 和关闭弹窗

```bash
ios-use open "https://example.com"
ios-use dismissAlert                # 默认点最后一个按钮
ios-use dismissAlert --index 0      # 点第一个按钮
```

`open <url>` 执行前会校验 URL 格式和 scheme 注册状态。省略 `--udid` 时使用当前 `driver.lock`。成功输出 `Opened URL: <url>`；设备上无 App 注册该 scheme 时报错 `URL scheme "xxx" not registered on device`。真机已注册 scheme 时输出包含 handler 信息：`Opened URL: <url> (handler: <bundle IDs>)`，底层走原生 CoreDevice URL launch，不调用 `devicectl`。

### 3.6 跑 flow

```bash
ios-use flow my-flow.yaml
ios-use flow my-flow.yaml --targetLabel 蓝牙 --timeout 5
```

Flow 的写法、外部 `vars` 和 subflow 用法见 `references/flow.md`。
Flow 执行前会先检查整份 YAML；未知字段、明显类型错误和可提前发现的 subflow 错误会在任何设备动作前失败。Flow 中坐标、offset、offsetRatio 都写成和 CLI 参数一致的字符串。

## 4. 当前命令用法

- `tap` / `longpress`
  - `<target>` — 元素 label 或 `"x,y"` 坐标（positional，不是 option）
  - 支持 `--traits <traits>` 按 traits 过滤（逗号分隔，AND 语义）
  - 支持 `--cindex <int>` 选择匹配父元素在 DOM 中显示的第 N 个直接子元素；坐标 target 不支持 traits/cindex
  - `tap` 支持 `--offset "x,y"`（像素偏移）和 `--offset-ratio "x,y"`（比例偏移）
  - offset 原点固定为目标元素左上角 `(0,0)`
  - `--offset` 缺失单轴时补 `0`；`--offset-ratio` 缺失单轴时补 `0.5`
  - 若 target 是绝对坐标 `x,y`，则不能再传 offset
  - `longpress` 默认 `500ms`，可通过 `--duration <ms>` 自定义
  - 快速 batch 操作可加 `--dom [ms]`，动作成功后等待 ms 毫秒并追加 fresh DOM；裸 `--dom` 默认 `200ms`，`--dom 0` 表示立即取

```bash
ios-use tap "通用" --traits Button
ios-use tap "通用" --dom
ios-use tap "亮度" --offset-ratio 0.8,
```

- `swipe`
  - 目标导向（推荐）：`--to <label> --from <label|point>`，自动循环滚动直到目标进入可见区域
  - 目标不需要初始可见，但必须能被系统界面树发现（不确定时先 `dom` 确认）
    - `--from` 是锚点：传一个当前可见的元素，从它所在的可滚动区域开始滚动；**目标不在当前屏幕时必须传 `--from`**
    - 不传 `--from` 时目标必须初始可见，否则返回 not found
    - 方向自动推断：根据目标元素相对于当前可见元素的位置决定 `forth`（向下/右）或 `back`（向上/左）
    - 页面内的长列表滚动，**优先用目标导向**，不要自己拆成多次纯距离 swipe
  - 固定距离：`--dir forth|back --distance <px>`，适合已经确认页面方向时做纯距离滚动
  - `forth` 通常表示继续往前浏览当前列表，`back` 表示反方向回拉
  - 自动检测竖直/水平方向，不需要额外传方向轴
  - 支持 `--traits <traits>`
  - 支持 `--cindex <int>`，只作用于 `--to` 目标，不作用于 `--from`
  - 支持 `--dom [ms]`，语义同 `tap`
  - 页面没变化或没找到目标时，先 `dom` 再决定是否继续滑

```bash
# 1. 推荐：目标导向滚动（自动循环，直到目标可见）
ios-use swipe --to "开发者" --from "蓝牙"

# 2. 列表继续下滚
ios-use swipe --dir forth --distance 300

# 3. 列表往回拉
ios-use swipe --dir back --distance 300
```

- `input`
  - `--label <text> --content <text>`
  - 不需要先 `tap` 输入框，命令会自动切换焦点再输入
  - 不隐式 clear
  - 支持 `--traits <traits>`
  - 支持 `--cindex <int>`
  - 支持 `--dom [ms]`，语义同 `tap`

- `screenshot`
  - 截图并输出保存路径
  - **只在用户明确要求查看视觉效果时使用**，默认不截图；AI 以 `dom`/`find` 理解页面

- `dom`
  - `--raw` 输出设备返回的原始界面树文本，排查 DOM 异常时使用
  - `--fresh` 忽略缓存，重新获取界面树
  - DOM type 使用短名，例如 `StaticText -> Text`、`SearchField/TextField -> Input`、`ScrollView -> Scroll`、`CollectionView -> Collection`
  - CLI 展示层可能给 `Scroll` / `Collection` / `Table` 追加 `vertical` / `horizontal`，只用于阅读 DOM；不要把这些方向当成 `find/tap/waitFor/swipe --traits` 的可过滤 trait

- `find`
  - `find <label>` 查找元素。完整 label 优先 exact；无 exact 时回退 contains；歧义和模糊建议不报错，只有真正未找到才报错
  - `--traits <traits>` 按 DOM 展示出来的 traits 过滤，逗号分隔多值，AND 语义（如 `Input`、`Switch`、`disabled`、`Cell,Switch`，大小写不敏感）
  - `--cindex <int>` 先找父元素再选 DOM 中显示的第 N 个直接子元素，`-1` 表示最后一个

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`
  - 支持 `--traits <traits>`
  - 支持 `--cindex <int>`

- `open`
  - `<url>` 在设备上打开 URL
  - 成功输出 `Opened URL: <url>`；真机已注册 scheme 包含 `(handler: <bundle IDs>)`
  - 未注册 scheme 报错 `URL scheme "xxx" not registered on device`
  - 不需要先执行 `start`

- `dismissAlert`
  - 关闭当前系统弹窗（Alert）
  - `--index <n>` 点击第几个按钮（0-based），不传则默认点最后一个

- `oslog`
  - 省略 `--udid` 时使用当前 `driver.lock`
  - 支持 `--timeout <seconds>`，会在窗口期内轮询匹配
  - `--pattern` 正则过滤，`--flags` 正则标志（`i`/`s`/`m`）
  - `--clear` 清空 buffer
  - `--bundle-id` 按 bundle ID 过滤
  - 采集完成后会输出日志文件路径

- `nslog`
  - 启动本地 NSLogger server，iOS app 主动推送日志（与 oslog 互补）。最好在app启动前启动NSLogger server，不然app连接不上
  - `ios-use nslog [--name <name>]` 前台 streaming；监听信息写 stderr，日志行写 stdout
  - `ios-use nslog start [--name <name>]` 后台采集并把日志写入 `~/.ios-use/logs/nslog-*.log`
  - `ios-use nslog read [--pattern <regex>] [--flags <flags>] [--timeout <sec>] [--clearAfterRead] [--last N]` 从最近一次后台采集读取
  - `ios-use nslog stop` 停止后台采集；日志文件保留，可继续 read 历史日志
  - 启动时如果提示 stale local publisher 或 live nslog server，说明本机已有 `_nslogger-ssl._tcp` Bonjour 发布可能抢占 app 连接。按提示里的 PID/port 清掉 stale `dns-sd` 或关闭旧 NSLogger viewer 后重试；该 warning 不代表当前命令启动失败
  - 适合验证 app 内 NSLog 埋点

## 5. Proxy 抓包

通过 mitmdump 在 Mac 上抓取设备的 HTTP/HTTPS 流量。完整指南见 `references/proxy.md`。

### 5.1 快速上手

```bash
# 1. 一次性：安装并信任 CA（HTTPS 解密所需，HTTP 抓包可跳过）
ios-use proxy configca

# 2. 启动抓包（后台运行，立即返回）
ios-use proxy start

# 3. 停止抓包
ios-use proxy stop

# 4. 查看抓包数据（读取最近一次 proxy start）
ios-use proxy read
ios-use proxy read --filter "~d okx.com" --raw
```

### 5.2 命令详解

- `proxy configca` — 生成 mitmproxy CA 并在设备上安装+信任；若过程中需要手动输入设备密码或手动信任证书，完成后运行 `ios-use proxy configca --mark-trusted`
- `proxy configca --mark-trusted` — 不 push CA、不执行安装 flow，只在已有当前 CA 文件时记录用户已人工信任
- `proxy start [--server] [-i <interface>]` — 默认启动 mitmdump + 配置设备 Wi-Fi 代理，并把本次 `~/.ios-use/artifacts/proxy-*.mitm` 写为 last capture；`--server` 只启动本机 mitmdump，不配置设备
- `proxy read [--filter <expression>] [--raw] [--last N]` — 只读取最近一次 `proxy start` 写入的 last capture；`proxy stop` 不会删除最后一次 capture，stop 后仍可继续 `proxy read`；`--last` 必须大于 0
- `proxy stop [--server]` — 默认先清除设备 Wi-Fi 代理，再停止 mitmdump；`--server` 只停止本机 mitmdump，不清设备 Wi-Fi 代理
- `proxy doctor` — 诊断 proxy 环境

网络前提：设备与 Mac 需要在同一 Wi-Fi/LAN，且设备能访问 Mac 的抓包端口。VPN、防火墙或隔离 Wi-Fi 可能导致抓不到流量或设备断网，排障先看 `proxy doctor`。

### 5.3 查看 .mitm 文件

优先使用 `proxy read` 查看最近一次抓包：

```bash
# 列出所有请求
ios-use proxy read

# 按域名过滤，显示完整 headers + body
ios-use proxy read --filter "~d example.com" --raw

# 按 method / 状态码 / URL 路径过滤
ios-use proxy read --filter "~m POST"
ios-use proxy read --filter "~c 404"
ios-use proxy read --filter "~u /api/"

# 只看最近 N 行
ios-use proxy read --last 20
```

过滤表达式：`~d` 域名、`~u` URL 子串、`~m` method、`~c` 状态码、`~b` body 内容。组合用 `&`（AND）`|`（OR），取反用 `!`。

## 6. 常见排障

- 操作命令异常（连不上设备）：

```bash
ios-use devices                 # 确认设备 configured
ios-use config --udid <udid>    # 重新签名安装
```

- 行为和预期不一致：
  - 先 `dom`
  - 再 `find`
  - DOM 无法解释时再补 `screenshot`（不要默认每步都截）

- 调试时可以加 `--verbose` 看完整输入输出。

- altsign出现http 4xx，可能是，非免费开发者账号（需要在developer.apple.com/login先注册)；5xx 可能是网络问题，提示开VPN。
