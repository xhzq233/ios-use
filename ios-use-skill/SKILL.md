---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices via CLI. Covers auto-session, device management, UI element inspection (dom/find), tap/swipe/input actions, screenshot, oslog/nslog, app lifecycle, HTTP/HTTPS proxy capture, and YAML flow authoring. Use this skill when the user wants to interact with an iOS device, inspect screen elements, automate UI steps, capture network traffic, write or debug automation flows, or check device logs."
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
ios-use config --udid <udid>  # 签名并安装 driver（显示 configured 后即可使用）
```

- 首次若 altsign session 不存在，需要补 Apple ID：`--apple-id you@example.com --password 'app-password'`
- Simulator 免签名：`ios-use config --simulator --udid <sim-udid>`
- 真机首次使用必须先 `config`，不要跳过
- 安装路径默认 `$HOME/.local/bin`，不在 PATH 时脚本会提示

## 2. 硬规则

- 真机必须 USB 连接，WiFi 连接的设备在 usbmux 中不可见，会报错
- 不传 `--udid` 时默认只选 USB 真机；如果要用 Simulator，必须显式传 `--udid`
- 执行操作前先 `ios-use devices` 确认设备已连接且显示 `configured`
- 任意操作命令（dom/tap/swipe/...）首次执行时自动创建 session，无需手动 `session start`
- 执行动作前，多用 `dom` 查看当前页面状态，不要盲点

## 3. 推荐工作流

### 3.1 前置准备

```bash
ios-use devices               # 确认设备已连接且 configured
```

设备未显示 `configured` 时先执行 `ios-use config --udid <udid>`。

无需手动创建 session——首次执行任意操作命令（dom、tap 等）时自动建连。需要操作特定 app 时先 `activateApp`：

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
ios-use screenshot --name current-page              # 保存为 ~/.ios-use/artifacts/current-page.jpg
```

### 3.4 切 app

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
```

### 3.5 打开 URL 和关闭弹窗

```bash
ios-use openURL --url "https://example.com"
ios-use dismissAlert                # 默认点最后一个按钮
ios-use dismissAlert --index 0      # 点第一个按钮
```

### 3.6 跑 flow

```bash
ios-use flow my-flow.yaml
ios-use flow my-flow.yaml --targetLabel 蓝牙 --timeout 5
```

Flow 的编写规范、字段语义、外部 `vars` 和 subflow 用法见 `references/flow.md`。

### 3.7 停止 session

```bash
ios-use stop                        # 停止 driver 进程并清理 session
```

## 4. 当前命令语义

- `tap` / `longpress`
  - `<target>` — 元素 label 或 `"x,y"` 坐标（positional，不是 option）
  - 支持 `--traits <traits>` 按 traits 过滤（逗号分隔，AND 语义）
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
    - `--from` 是锚点：传一个当前可见的元素，driver 从它所在的 scrollable 开始滚动；**目标不在当前屏幕时必须传 `--from`**
    - 不传 `--from` 时目标必须初始可见，否则返回 not found
    - 方向自动推断：根据目标 cell 相对于当前可见 cell 的位置决定 `forth`（向下/右）或 `back`（向上/左）
    - 页面内的长列表滚动，**优先用目标导向**，不要自己拆成多次纯距离 swipe
  - 固定距离：`--dir forth|back --distance <px>`，适合已经确认页面方向时做纯距离滚动
  - `forth` 通常表示继续往前浏览当前列表，`back` 表示反方向回拉
  - 自动检测竖直/水平方向，不需要额外传方向轴
  - 支持 `--traits <traits>`
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

- `screenshot`
  - 保存为 JPEG 到 `~/.ios-use/artifacts/<name>.jpg`

- `dom`
  - `--raw` 输出原始 snapshot 格式化文本字符串（跳过 clean tree，调试用）
  - `--fresh` 忽略缓存，重新构建 snapshot

- `find`
  - `find <label>` 查找元素。歧义和模糊建议不报错，返回所有匹配；只有真正未找到才报错
  - `--traits <traits>` 按 traits 过滤，逗号分隔多值，AND 语义（如 `Switch`、`disabled`、`Cell,Switch`，大小写不敏感）

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`
  - 轮询间隔是内部固定值 `100ms`，不对外暴露 `interval`
  - 支持 `--traits <traits>`

- `openURL`
  - `--url <url>` 在设备上打开 URL
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

通过 mitmdump 在 Mac 上抓取设备的 HTTP/HTTPS 流量。

### 5.1 完整流程

```bash
# 1. 确保 mitmdump 已安装
pip install mitmproxy

# 2. 一次性：安装并信任 CA（HTTPS 解密所需，HTTP 抓包可跳过）
ios-use proxy configca

# 3. 启动抓包
ios-use proxy start

# 4. 读取抓包数据
ios-use proxy read                     # 最近 10 条
ios-use proxy read --count 20          # 最近 20 条
ios-use proxy read --duration 30s      # 最近 30 秒内的流量
ios-use proxy read --save my-capture   # 保存到 ~/.ios-use/artifacts/my-capture.jsonl

# 5. 停止抓包
ios-use proxy stop
```

### 5.2 命令详解

- `proxy configca` — 生成 mitmproxy CA 并在设备上安装+信任（一次性）
  - 流程：Safari 下载 CA → 设置安装描述文件 → 证书信任设置启用
  - 只需执行一次，CA 不会变

- `proxy start` — 启动 mitmdump + 配置设备 Wi-Fi 代理
  - `--stream` 实时输出 JSONL 到 stdout（前台阻塞，Ctrl+C 停止）
  - `-i, --interface <iface>` 指定 Mac 网卡（默认自动选 Wi-Fi）
  - `--no-body` 不记录请求/响应 body
  - `--body-limit <bytes>` body 最大字节数（默认 102400）
  - 非 stream 模式下命令执行完即退出，mitmdump 在后台运行
  - 首次安装 driver 后会自动检测网络权限弹窗并授权

- `proxy stop` — 清除设备 Wi-Fi 代理 + 停止 mitmdump

- `proxy read` — 读取抓包数据
  - `--count <n>` 条数（默认 10）
  - `--duration <time>` 时间窗口（如 `30s`、`1m`）
  - `--save [name]` 保存到文件

- `proxy doctor` — 诊断 proxy 环境（mitmdump 安装、CA 状态、网络连通性）

### 5.3 LAN 连通性验证

`proxy start` 在配置 Wi-Fi 代理前，会先在 Mac 上启动临时 HTTP probe server，并用设备 Safari 打开 `http://<mac-lan-ip>:<probe-port>/ping`，再通过 DOM 校验页面里是否出现固定文本。这样验证的是设备自身能否访问 Mac LAN IP，不依赖 driver 进程自身发起网络请求。

## 6. 常见排障

- 操作命令异常（连不上设备）：

```bash
ios-use devices                 # 确认设备 configured
ios-use config --udid <udid>    # 重新签名安装（会自动清理旧 session）
```

- 行为和预期不一致：
  - 先 `dom`
  - 再 `find`
  - 必要时补 `screenshot`

- 改了 driver 代码但行为没变：设备上还是旧 IPA，重新 `bash scripts/build_host_app.sh` + `ios-use config`

- 调试时可以加 `--verbose` 看完整输入输出。
