---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices. Best for session commands, UI exploration, and flow authoring."
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
ios-use dom --name settings        # 保存到 ~/.ios-use/dom-settings.json
ios-use find "蓝牙"                # 在 dom 基础上查目标元素
ios-use waitFor --label "蓝牙" --timeout 8
```

建议：每次切页面、滚动后、找不到元素时，都先补一次 `dom`，确认页面状态再继续。

### 3.3 执行动作

```bash
ios-use tap --label "通用"
ios-use longpress --label "通用"
ios-use swipe --to "开发者" --from "蓝牙"
ios-use swipe --dir forth --distance 300            # 纯距离滚动
ios-use input --label "搜索" --content "蓝牙"      # 不需要先 tap，会自动切换焦点
ios-use screenshot --name current-page              # 保存为 ~/.ios-use/screenshot-current-page.jpg
```

### 3.4 切 app

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
```

### 3.5 跑 flow

```bash
ios-use flow flows/test_flow.yaml
```

## 4. 当前命令语义

- `tap` / `longpress`
  - `--label <text>` 或 `--label x,y`
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
  - 保存为 JPEG 到 `~/.ios-use/screenshot-<name>.jpg`

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`

## 5. Flow 编写规则

### 5.1 只用当前支持的 action

- `tap`
- `input`
- `swipe`
- `longpress`
- `dom`
- `find`
- `screenshot`
- `waitFor`
- `activateApp`
- `terminateApp`
- `oslog`
- `nslog_start`
- `nslog`
- `nslog_clear`

### 5.2 flow 模板

```yaml
name: Settings Search
app: com.apple.Preferences
needLog: true
steps:
  - action: waitFor
    label: 蓝牙
    timeout: 8

  - action: input
    label: 搜索
    content: 蓝牙
    context:
      ancestorType: SearchField

  - action: tap
    label: 蓝牙

  - action: screenshot
    name: settings-bluetooth
```

### 5.3 flow 原则

- 编写 flow 前，先用 CLI 手动跑一遍，确认每个动作都执行对
- 先 `waitFor`，再动作
- 先看 `dom`，再决定点哪里
- 能用 label 就不用坐标
- 需要滚到目标时，优先 `swipe --to`
- 关键节点保留 `dom` / `screenshot` / `oslog`

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
