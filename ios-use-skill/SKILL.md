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
- 真机首次使用，或升级到新版本后，先执行：

```bash
ios-use devices               # 查看设备列表、udid 和配置状态
ios-use config --udid <udid>  # 完成设备配置（显示 configured 后即可使用）
```

- 如果 `ios-use devices` 显示 `driver update required`，必须重新执行 `ios-use config --udid <udid>`。
- 首次配置真机时可能需要补 Apple ID，并触发 Apple 2FA 验证码输入，AI 无法代用户完成。此时应提示用户：「真机首次签名需要一个免费的 Apple Developer 账号。请在终端手动运行以下命令，按提示输入 Apple ID、App 专用密码，并完成两步验证（2FA）：`ios-use config --udid <udid> --apple-id <your-apple-id> --password '<app-specific-password>'`」
- Simulator 免签名：`ios-use config --simulator --udid <sim-udid>`
- 真机首次使用必须先 `config`，不要跳过
- 安装路径默认 `$HOME/.local/bin`，不在 PATH 时脚本会提示

## 2. 硬规则

- 真机必须 USB 连接，WiFi 连接的设备在 usbmux 中不可见，会报错
- 不传 `--udid` 时默认只选 USB 真机；如果要用 Simulator，必须显式传 `--udid`
- 执行操作前先 `ios-use devices` 确认设备已连接且显示 `configured`，且没有 `driver update required`
- 执行动作前，多用 `dom` 查看当前页面状态，不要盲点
- **不要猜**：每一步执行前，用 `dom`/`find` 确认当前页面状态，不要凭猜测执行。尤其是 bundle ID，如果不知道目标 app 的 bundle ID，问用户或从设备上查找（如通过 Spotlight、App Store 链接、或 dom 查看 home screen），不要逐个尝试猜测变体
- **截图策略**：默认以 `dom`/`find` 理解页面，不主动截图。只有以下场景才用 `screenshot`：(1) DOM 无法描述的视觉内容（颜色、布局、图片、动画状态）；(2) 用户明确要求看最终效果或视觉验收。不要在每一步自动截图

## 3. 推荐工作流

### 3.1 前置准备

```bash
ios-use devices               # 确认设备已连接且 configured
```

设备未显示 `configured`，或显示 `driver update required` 时，先执行 `ios-use config --udid <udid>`。

需要操作特定 app 时先 `activateApp`：

```bash
ios-use activateApp com.apple.Preferences
ios-use dom
```

### 3.2 先用 dom 探索页面

```bash
ios-use dom                        # 先看当前页面元素树
ios-use dom --raw                  # 原始 snapshot 文本，调试用
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

### 3.5 打开 URL 和关闭弹窗

```bash
ios-use open "https://example.com"
ios-use dismissAlert                # 默认点最后一个按钮
ios-use dismissAlert --index 0      # 点第一个按钮
```

### 3.6 跑 flow

```bash
ios-use flow my-flow.yaml
ios-use flow my-flow.yaml --targetLabel 蓝牙 --timeout 5
```

Flow 的编写规范、字段语义、外部 `vars` 和 subflow 用法见 `references/flow.md`。

## 4. 当前命令语义

- `tap` / `longpress`
  - `<target>` — 元素 label 或 `"x,y"` 坐标（positional，不是 option）
  - 支持 `--traits <traits>` 按 traits 过滤（逗号分隔，AND 语义）
  - 支持 `--cindex <int>` 选择匹配父元素的第 N 个 cleaned child；坐标 target 不支持 traits/cindex
  - `tap` 支持 `--offset "x,y"`（像素偏移）和 `--offset-ratio "x,y"`（比例偏移）
  - offset 原点固定为目标元素左上角 `(0,0)`
  - 缺失单轴时默认补 `0.5` ratio
  - 若 target 是绝对坐标 `x,y`，则不能再传 offset
  - `longpress` 默认 `500ms`，可通过 `--duration <ms>` 自定义

```bash
ios-use tap "通用" --traits Button
ios-use tap "亮度" --offset-ratio 0.8,
```

- `swipe`
  - 目标导向（推荐）：`--to <label> --from <label|point>`，自动循环滚动直到目标进入可见区域
    - 目标不需要初始可见，但必须已在 AX 树中（不确定时先 `dom` 确认）
    - `--from` 是锚点：传一个当前可见的元素，从它所在的可滚动区域开始滚动；**目标不在当前屏幕时必须传 `--from`**
    - 不传 `--from` 时目标必须初始可见，否则返回 not found
    - 方向自动推断：根据目标 cell 相对于当前可见 cell 的位置决定 `forth`（向下/右）或 `back`（向上/左）
    - 页面内的长列表滚动，**优先用目标导向**，不要自己拆成多次纯距离 swipe
  - 固定距离：`--dir forth|back --distance <px>`，适合已经确认页面方向时做纯距离滚动
  - `forth` 通常表示继续往前浏览当前列表，`back` 表示反方向回拉
  - 自动检测竖直/水平方向，不需要额外传方向轴
  - 支持 `--traits <traits>`
  - 支持 `--cindex <int>`，只作用于 `--to` 目标，不作用于 `--from`
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

- `screenshot`
  - 保存为 JPEG 到 `~/.ios-use/artifacts/<name>.jpg`
  - **只在用户明确要求查看视觉效果时使用**，默认不截图；AI 以 `dom`/`find` 理解页面

- `dom`
  - `--raw` 输出原始 snapshot 格式化文本字符串（跳过 clean tree，调试用）
  - `--fresh` 忽略缓存，重新构建 snapshot

- `find`
  - `find <label>` 查找元素。完整 label 优先 exact；无 exact 时回退 contains；歧义和模糊建议不报错，只有真正未找到才报错
  - `--traits <traits>` 按 traits 过滤，逗号分隔多值，AND 语义（如 `Switch`、`disabled`、`Cell,Switch`，大小写不敏感）
  - `--cindex <int>` 先找父元素再选第 N 个 cleaned child，`-1` 表示最后一个

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`
  - 轮询间隔是内部固定值 `100ms`，不对外暴露 `interval`
  - 支持 `--traits <traits>`
  - 支持 `--cindex <int>`

- `open`
  - `<url>` 在设备上打开 URL
  - Safari 会处理该 URL

- `dismissAlert`
  - 关闭当前系统弹窗（Alert）
  - `--index <n>` 点击第几个按钮（0-based），不传则默认点最后一个

- `oslog`
  - 支持 `--timeout <seconds>`，会在窗口期内轮询匹配
  - `--pattern` 正则过滤，`--flags` 正则标志（`i`/`s`/`m`）
  - `--clear` 清空 buffer
  - `--bundle-id` 按 bundle ID 过滤
  - 日志文件保存到 `~/.ios-use/artifacts/<name>.log`

- `nslog`
  - 启动本地 NSLogger server，iOS app 主动推送日志（与 oslog 互补）
  - `--name <name>` Bonjour 服务名
  - `--grep <pattern>` 正则过滤，`--flags` 正则标志
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

# 4. 查看抓包数据（mitmproxy flow dump 格式）
mitmdump -r <flow文件路径>                                    # 列表概览
mitmdump -r <flow文件路径> --set flow_detail=3 "~d okx.com"  # 按域名过滤 + 完整详情
```

### 5.2 命令详解

- `proxy configca` — 生成 mitmproxy CA 并在设备上安装+信任（一次性）
- `proxy start [-i <interface>]` — 启动 mitmdump + 配置设备 Wi-Fi 代理，抓包保存为 `~/.ios-use/artifacts/proxy-*.flow`
- `proxy stop` — 先清除设备 Wi-Fi 代理，再停止 mitmdump；若设备侧清理失败，会提示手动关闭 Wi-Fi 代理且不继续停止本地服务
- `proxy doctor` — 诊断 proxy 环境

### 5.3 查看 .flow 文件

抓包产物为 mitmproxy flow dump 格式，使用 mitmdump 查看：

```bash
# 列出所有请求
mitmdump -r file.flow

# 按域名过滤，显示完整 headers + body
mitmdump -r file.flow --set flow_detail=3 "~d example.com"

# 按 method / 状态码 / URL 路径过滤
mitmdump -r file.flow "~m POST"
mitmdump -r file.flow "~c 404"
mitmdump -r file.flow "~u /api/"
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
