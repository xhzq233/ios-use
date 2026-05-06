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

- 安装完成后，所有命令都直接使用 `ios-use`：
- 真机首次使用，或升级到新版本后，先执行：

```bash
ios-use device
```

```bash
ios-use config --udid <udid>
```

- `ios-use device` 可以先查看设备列表和 `udid`
- `config` 是公开使用链路的一部分，不要跳过

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
ios-use tap --label "通用"
ios-use tap --label "亮度" --offset-x-ratio 0.8
ios-use longpress --label "通用"
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

Flow 的编写规范、字段语义和 subflow 用法见 `references/flow.md`。本文件只负责"怎么手动操作手机"和"怎么用 CLI 探索/排障"。

## 4. 当前命令语义

- `tap` / `longpress`
  - `--label <text>` 或 `--label x,y`
  - `tap` 支持 `--offset-x` / `--offset-y` / `--offset-x-ratio` / `--offset-y-ratio`
  - offset 原点固定为目标元素左上角 `(0,0)`
  - 缺失单轴时默认补 `0.5` ratio
  - 若 `--label` 是绝对坐标 `x,y`，则不能再传 offset
  - `longpress` 默认 `500ms`，可通过 `--duration <ms>` 自定义
  - 底层走 synthesized pointer

- `swipe`
  - 目标导向：`--to <label> --from <label|point>`，从起点元素或坐标开始滑，直到把目标元素带进可见区域
  - 固定距离：`--dir forth|back --distance <px>`，适合已经确认页面方向时做纯距离滚动
  - `forth` 通常表示继续往前浏览当前列表，`back` 表示反方向回拉
  - 自动检测竖直/水平方向，不需要额外传方向轴
  - 页面没变化或没找到目标时，先 `dom` 再决定是否继续滑

```bash
# 1. 列表继续下滚
ios-use swipe --dir forth --distance 300

# 2. 列表往回拉
ios-use swipe --dir back --distance 300

# 3. 从当前区域往目标元素滑，直到目标进入可见区域
ios-use swipe --to "开发者" --from "蓝牙"
```

- `input`
  - `--label <text> --content <text>`
  - 不需要先 `tap` 输入框，命令会自动切换焦点再输入
  - 不隐式 clear

- `screenshot`
  - 保存为 JPEG 到 `~/.ios-use/artifacts/<name>.jpg`

- `dom`
  - `--save --name <name>` 时，保存到 `~/.ios-use/artifacts/<name>.json`

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`
  - 轮询间隔是内部固定值 `300ms`，不对外暴露 `interval`

- `oslog`
  - 支持 `--timeout <seconds>`，会在窗口期内轮询匹配
  - 日志文件保存到 `~/.ios-use/artifacts/<name>.log`

## 5. Flow 入口

- 运行 flow：

```bash
ios-use flow my-flow.yaml
```

- 写 flow、拆 subflow、设计 `vars` / `outputs`、使用 `dom.candidates` 时，查看 `references/flow.md`
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

- 调试时可以加 `--verbose` 看完整输入输出。
