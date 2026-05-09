---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices via CLI. Covers session management, UI element inspection (dom/find), tap/swipe/input actions, screenshot, oslog/nslog, app lifecycle, and YAML flow authoring. Use this skill when the user wants to interact with an iOS device, inspect screen elements, automate UI steps, write or debug automation flows, or check device logs."
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
ios-use device              # 查看设备列表和 udid
ios-use config --udid <udid>  # 签名并安装 driver
```

- 首次若 altsign session 不存在，需要补 Apple ID：`--apple-id you@example.com --password 'app-password'`
- Simulator 免签名：`ios-use config --simulator --udid <sim-udid>`
- 真机首次使用必须先 `config`，不要跳过
- 安装路径默认 `$HOME/.local/bin`，不在 PATH 时脚本会提示

## 2. 硬规则

- 真机必须 USB 连接，WiFi 连接的设备在 usbmux 中不可见，会报错
- 不传 `--udid` 时默认只选 USB 真机；如果要用 Simulator，必须显式传 `--udid`
- 起 session 前先看当前状态：

```bash
ios-use session status
```

- `--udid` 只在 `session start` 时需要，后续命令复用 session 状态，不需要再传
- 执行动作前，多用 `dom` 查看当前页面状态，不要盲点

## 3. 推荐工作流

### 3.1 先看 session，再起 session

```bash
ios-use session status
```

```bash
# app session —— 指定目标 app
ios-use session start --udid <udid> --bundle-id com.apple.Preferences

# 或 device session —— 不绑定 app，后续用 activateApp 切换
ios-use session start --udid <udid>
```

`session start` 之后的所有命令（dom、find、tap 等）直接复用 session，不需要再传 `--udid`。

### 3.2 先用 dom 探索页面

```bash
ios-use dom                        # 先看当前页面元素树
ios-use dom --save --name settings # 保存到 ~/.ios-use/artifacts/settings.json
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

### 3.5 跑 flow

```bash
ios-use flow my-flow.yaml
```

Flow 的编写规范、字段语义和 subflow 用法见 `references/flow.md`。

## 4. 当前命令语义

- `tap` / `longpress`
  - `<target>` — 元素 label 或 `"x,y"` 坐标（positional，不是 option）
  - `tap` 支持 `--offset "x,y"`（像素偏移）和 `--offset-ratio "x,y"`（比例偏移）
  - offset 原点固定为目标元素左上角 `(0,0)`
  - 缺失单轴时默认补 `0.5` ratio
  - 若 target 是绝对坐标 `x,y`，则不能再传 offset
  - `longpress` 默认 `500ms`，可通过 `--duration <ms>` 自定义
  - 底层走 synthesized pointer

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

- `screenshot`
  - 保存为 JPEG 到 `~/.ios-use/artifacts/<name>.jpg`

- `dom`
  - `--raw` 返回原始 XCUI snapshot 树（默认返回 clean tree）
  - `--save --name <name>` 时，保存到 `~/.ios-use/artifacts/<name>.json`

- `find`
  - `find <label>` 查找元素。歧义和模糊建议不报错，返回所有匹配；只有真正未找到才报错
  - `--traits <traits>` 按 traits 过滤，逗号分隔多值，AND 语义（如 `Switch`、`disabled`、`Cell,Switch`，大小写不敏感）

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`
  - 轮询间隔是内部固定值 `100ms`，不对外暴露 `interval`

- `oslog`
  - 支持 `--timeout <seconds>`，会在窗口期内轮询匹配
  - `--pattern` 正则过滤，`--flags` 正则标志（`i`/`s`/`m`）
  - `--clear` 清空 buffer
  - 日志文件保存到 `~/.ios-use/artifacts/<name>.log`

- `nslog`
  - 启动本地 NSLogger server，iOS app 主动推送日志（与 oslog 互补）
  - `--grep <pattern>` 正则过滤，`--flags` 正则标志
  - `--port <port>` 监听端口（默认自动分配）
  - `--ssl` / `--no-ssl` TLS 开关（默认开启）
  - 适合验证 app 内 NSLog 埋点

## 5. Flow 入口

- 运行 flow：

```bash
ios-use flow my-flow.yaml
```

- 写 flow、拆 subflow、设计 `vars` / `outputs`、使用 `dom.candidates`、`returnIf` 时，查看 `references/flow.md`
- 手动排查 flow 某一步失败时，先回到本文件，用 `dom` / `find` / `screenshot` / `oslog` 单独验证该步骤
- 新写 flow 时，先手动跑通每一个动作，再回到 YAML 里组装

## 6. 常见排障

- `session start` 异常：

```bash
ios-use session status
ios-use config --udid <udid>
ios-use session stop 2>/dev/null || true
sleep 3
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

- 行为和预期不一致：
  - 先 `dom`
  - 再 `find`
  - 必要时补 `screenshot`

- 改了 driver 代码但行为没变：设备上还是旧 IPA，重新 `bash scripts/build_host_app.sh` + `ios-use config`

- 调试时可以加 `--verbose` 看完整输入输出。

- 旧写法迁移：

| 旧写法 | 新写法 |
|--------|--------|
| `tap --text` | `tap <target>` |
| `tap --label` | `tap <target>` |
| `longpress --label` | `longpress <target>` |
| `--offset-x / --offset-y` | `--offset "x,y"` |
| `--offset-x-ratio / --offset-y-ratio` | `--offset-ratio "x,y"` |
| `input --text` | `input --content` |
| `wait-for` | `waitFor` |
| `app launch` | `activateApp` |
| `app close` | `terminateApp` |
| `waitFor --interval` | 不支持，轮询间隔由 driver 内部控制 |
| `nslog --interval-ms` | 不支持，轮询间隔固定 300ms |
