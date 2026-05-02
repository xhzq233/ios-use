---
name: "ios-use-skill"
description: "Use ios-use to drive iOS devices. Best for session commands, UI exploration, and flow authoring."
---

# ios-use Skill

给公开用户和 AI 的高密度操作卡。默认按 public 口径使用，只有在仓库内调试当前源码时才切到 debug/dev 口径：

- public：先安装，再直接用 `ios-use`
- debug/dev：在仓库内用 `bun run src/cli.ts`

## 1. 硬规则

- public 安装方式：

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

- public 使用时，后续都直接用 `ios-use`：

```bash
ios-use <command>
```

- debug/dev 模式才使用源码入口：

```bash
bun run src/cli.ts <command>
```

- 真机必须 USB 连接，WiFi 连接的设备在 usbmux 中不可见，会报错
- `--udid` 只在 `session start` 时需要，后续命令复用 session 状态，不需要再传
- 真机更新到新版本后，重装链路固定：

```bash
ios-use config --udid <udid>
```

## 2. 推荐工作流

### 2.1 先起 session

```bash
# app session —— 指定目标 app
ios-use session start --udid <udid> --bundle-id com.apple.Preferences

# 或 device session —— 不绑定 app，后续用 activateApp 切换
ios-use session start --udid <udid>
```

`session start` 之后的所有命令（dom、find、tap 等）直接复用 session，不需要再传 `--udid`。

### 2.2 探索页面

```bash
ios-use dom                        # 打印当前页面元素树
ios-use dom --name settings        # 保存到 ~/.ios-use/dom-settings.json
ios-use find "蓝牙"                # 精确或模糊查找元素
ios-use waitFor --label "蓝牙" --timeout 8
```

### 2.3 执行动作

```bash
ios-use tap --label "通用"
ios-use longpress --label "通用"
ios-use longpress --label "通用" --duration 1500   # 自定义时长 (ms)
ios-use swipe --to "开发者" --from "蓝牙"
ios-use swipe --dir forth --distance 300            # 纯距离滚动
ios-use input --label "搜索" --content "蓝牙"
ios-use screenshot --name current-page              # 保存为 ~/.ios-use/screenshot-current-page.jpg
```

### 2.4 切 app

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
```

### 2.5 跑 flow

```bash
ios-use flow flows/test_flow.yaml
```

## 3. 当前命令语义

- `tap` / `longpress`
  - `--label <text>` 或 `--label x,y`
  - `longpress` 默认 `500ms`，可通过 `--duration <ms>` 自定义
  - 底层走 synthesized pointer

- `swipe`
  - 目标导向：`--to <label> --from <label|point>`
  - 固定距离：`--dir forth|back --distance <px>`
  - 自动检测竖直/水平方向

- `input`
  - `--label <text> --content <text>`
  - 不隐式 clear

- `screenshot`
  - 保存为 JPEG 到 `~/.ios-use/screenshot-<name>.jpg`

- `waitFor`
  - 轮询等待元素出现，超时返回 not-found
  - `--label <text> --timeout <seconds>`

## 4. Flow 编写规则

### 4.1 只用当前支持的 action

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

### 4.2 flow 模板

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

### 4.3 flow 原则

- 先 `waitFor`，再动作
- 能用 label 就不用坐标
- 需要滚到目标时，优先 `swipe --to`
- 关键节点保留 `dom` / `screenshot` / `oslog`

## 5. 常见排障

- `session start` 异常：

```bash
ios-use config --udid <udid>
ios-use session stop 2>/dev/null || true
sleep 3
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

- 行为和预期不一致：
  - 先 `dom`
  - 再 `find`
  - 必要时补 `screenshot`

- 修改 driver 代码后重装：

```bash
bash scripts/build_host_app.sh       # 重新构建 driver.ipa
ios-use config --udid <udid>          # 签名 + 安装到设备
ios-use session stop 2>/dev/null || true
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

- 调试时可以加 `--verbose` 看完整输入输出。

## 6. 文档入口

- 详细使用指南：`docs/detail-manual.md`
