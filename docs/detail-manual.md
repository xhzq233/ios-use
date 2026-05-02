# ios-use Detailed Manual

本文档是公开详细使用指南，默认面向安装后的 `ios-use` 命令。

适用范围：

- public 使用：通过 `raw.githubusercontent.com/.../install.sh | bash` 安装后，直接运行 `ios-use`
- debug/dev 使用：在仓库内用 `bun run src/cli.ts`
- 编写和调试 flow

若本文与实现冲突，以当前 CLI `--help` 为准；若你在仓库内调试当前源码，把下面的 `ios-use` 替换成 `bun run src/cli.ts` 即可。

## 1. 基本约束

- public 默认使用安装后的 `ios-use`，不要混用旧的全局命令或历史脚本
- debug/dev 模式才需要在项目根目录执行，并使用 `bun run src/cli.ts`
- 真机必须 USB 连接；WiFi-only 设备不会出现在 usbmux 列表
- 若你在改 driver 代码，不要直接调 `xcodebuild`；工程文件以 `driver/project.yml` 为准

## 2. 首次准备

### 2.1 Public 安装

公开使用建议直接安装二进制入口：

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

安装后直接使用：

```bash
ios-use --help
```

说明：

- 安装脚本默认把 `ios-use` 安装到用户目录
- 若该目录不在 `PATH`，脚本会提示你补环境变量
- 当前安装脚本仍需要本机已安装 `bun`，因为它会本地编译 CLI

### 2.2 Public 首次使用

```bash
ios-use --help
ios-use device
```

说明：

- 安装脚本默认把 `ios-use` 安装到用户目录
- 若该目录不在 `PATH`，脚本会提示你补环境变量
- 当前安装脚本仍需要本机已安装 `bun`，因为它会本地编译 CLI

### 2.3 开发环境依赖

```bash
bun install
```

### 2.4 Debug/Dev 模式调用

仓库内开发和调试，使用源码入口：

```bash
bun run src/cli.ts <command>
```

### 2.5 真机构建与安装

```bash
# 1. 构建 driver IPA
bash scripts/build_host_app.sh
```

公开使用：

```bash
ios-use config --udid <udid>
```

仓库内 debug/dev：
```bash
bun run src/cli.ts config --udid <udid>
```

首次若 altsign session 不存在，需要补 Apple ID：

```bash
ios-use config --udid <udid> --apple-id you@example.com --password 'app-password'
```

### 2.6 Simulator 安装

```bash
# 查看已启动的 Simulator
ios-use device --simulator

# 安装并启动 Simulator driver
ios-use config --simulator --udid <simulator-udid>
```

## 3. Session 工作流

推荐优先使用 session 模式。`session start` 负责准备 driver，后续命令直接复用当前 session 状态。

### 3.1 启动 app session

```bash
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

语义：

- 冷启动目标 app
- 写入 `~/.ios-use/session.json`
- 后续 `dom/find/tap/input/...` 直接复用

### 3.2 启动 device session

```bash
ios-use session start --udid <udid>
```

语义：

- 只准备 driver，不绑定 app
- 后续通过 `activateApp` 切到目标 app

### 3.3 查看与结束

```bash
ios-use session status
ios-use session stop
```

## 4. 常用命令

### 4.1 设备与安装

```bash
ios-use device
ios-use device --simulator
ios-use config --udid <udid>
ios-use config --list
```

### 4.2 App 生命周期

```bash
ios-use activateApp com.apple.Preferences
ios-use terminateApp com.apple.Preferences
```

说明：

- `activateApp` 会切到指定 app
- `terminateApp` 会终止指定 app
- 这两类命令属于 mutation，会使旧 snapshot 失效

### 4.3 DOM / 查找 / 等待

```bash
ios-use dom
ios-use dom --raw
ios-use find "蓝牙"
ios-use waitFor --label "蓝牙" --timeout 8
```

说明：

- `dom` 默认返回 clean tree
- `dom --raw` 返回原始 snapshot 树
- `find/tap/longpress/input/swipe/waitFor` 共用同一套 label 查找语义
- `waitFor` 首轮先查 cache，miss 后才 fresh poll

支持消歧：

```bash
ios-use find "开发者" --context.ancestor-type Table
ios-use tap --label "蓝牙" --context.ancestor-label "设置"
```

### 4.4 点击、长按、输入

```bash
# 按 label 点击
ios-use tap --label "通用"

# 坐标点击
ios-use tap --label 200,80

# 长按，默认 500ms
ios-use longpress --label "通用"
ios-use longpress --label 200,80 --duration 800

# 输入
ios-use input --label "搜索" --content "蓝牙"
```

说明：

- `tap` / `longpress` 底层走 synthesized pointer
- `longpress` 默认 `500ms`
- `input` 当前语义是：
  - `rawFind`
  - 选择可编辑 snapshot
  - 按坐标聚焦
  - fresh snapshot 复查焦点/键盘
  - `FBTypeText`
- `input` 不隐式 clear

### 4.5 滑动

```bash
# 向目标滚动直到可见
ios-use swipe --to "开发者" --from "蓝牙"

# 固定距离滑动
ios-use swipe --dir forth --distance 200
ios-use swipe --dir back --distance 200
```

说明：

- `--to` / `--from` 用于目标驱动滚动
- `--dir` 目前是 `forth` / `back`
- `distance` 使用整数像素

### 4.6 截图与日志

```bash
ios-use screenshot --name settings-home
ios-use oslog --pattern Preferences --name prefs-log
ios-use nslog --grep event_name
```

说明：

- `screenshot` 底层走 `_XCT_requestScreenshot`
- 返回协议是 JSON header + raw JPEG binary
- 当前编码质量为 `0.8`
- `oslog` 是 driver 命令
- `nslog` 是单独的本地日志接收器

## 5. Flow 指南

### 5.1 执行 flow

```bash
ios-use flow flows/test_flow.yaml
```

### 5.2 顶层字段

```yaml
name: 设置页冒烟
app: com.apple.Preferences
needLog: true
steps:
  - action: waitFor
    label: 蓝牙
    timeout: 8
```

说明：

- `app` 存在时，flow 会先 `terminateApp` 再 `activateApp`
- `needLog: true` 会自动启动 NSLogger server
- flow 结束时会自动停止 NSLogger server

### 5.3 当前支持的 action

仅保留当前实现存在的 action：

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

不应再写入旧 action：

- `assert`
- `dismissPopup`
- `launch`
- `close`
- `record`
- `swipeback`

### 5.4 Flow 示例

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

  - action: waitFor
    label: 蓝牙
    timeout: 5

  - action: tap
    label: 蓝牙

  - action: screenshot
    name: settings-bluetooth

  - action: oslog
    pattern: Preferences
    name: settings-oslog
```

### 5.5 编写原则

- 先 `waitFor`，再做动作
- 有稳定 label 时，优先 `tap/longpress/input` 的 label 路径
- 不要假设“滑一次大概就到”，优先用 `swipe --to`
- 每个关键节点都至少保留一种验证手段：`waitFor` / `dom` / `screenshot` / `oslog`

## 6. 排障

### 6.1 `session start` 失败

先按完整链路重建：

```bash
bash scripts/build_host_app.sh
ios-use config --udid <udid>
ios-use session stop 2>/dev/null || true
sleep 3
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

### 6.2 命令语法和文档不一致

优先检查：

- `ios-use --help`
- 对应命令的 `--help`
- 若你在仓库内 debug，再看 `src/cli.ts`

不要再参考历史文档中的这些旧写法：

- `tap --text`
- `input --text`
- `wait-for`
- `app launch`
- `app close`

### 6.3 改了 driver 代码但行为没变

通常是因为设备上还是旧 IPA：

```bash
bash scripts/build_host_app.sh
ios-use config --udid <udid>
```

### 6.4 真机日志与崩溃

- driver 代码统一用 `NSLog()`
- 设备侧日志文件：`/tmp/ios-use-driver.log`
- 崩溃日志可用 `idevicecrashreport` 拉取

## 7. 公开文档边界

本文只保留：

- 当前可执行的安装、session、命令、flow 用法
- 常见排障

不包含：

- 内部设计文档
- 忽略目录中的私有文档
- 历史架构演进与性能研究笔记
