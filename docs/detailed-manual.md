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

- 安装脚本把 `ios-use` 安装到 `$HOME/.local/bin`（或 `$XDG_BIN_HOME`、`$PREFIX/bin`）
- 若该目录不在 `PATH`，脚本会提示你补环境变量
- 当前安装脚本仍需要本机已安装 `bun`，因为它会本地编译 CLI
- 安装脚本同时会把 skill 文件安装到 `~/.ios-use/skill/`，并软链到 `~/.agents/skills/ios-use`

### 2.2 首次使用

```bash
ios-use device              # 查看设备列表和 udid
ios-use config --udid <udid>  # 签名并安装 driver
```

首次若 altsign session 不存在，需要补 Apple ID：

```bash
ios-use config --udid <udid> --apple-id you@example.com --password 'app-password'
```

### 2.3 Simulator 配置

```bash
ios-use device --simulator                    # 查看已启动的 Simulator
ios-use config --simulator --udid <sim-udid>  # 安装 Simulator driver（免签名）
```

### 2.4 开发环境

```bash
bun install                               # 安装依赖
bun run src/cli.ts <command>              # 仓库内 debug/dev 模式
bash scripts/build_host_app.sh            # 构建 driver IPA
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
- 后续 `dom/find/tap/input/...` 直接复用，不需要再传 `--udid`

### 3.2 启动 device session

```bash
ios-use session start --udid <udid>
```

语义：

- 只准备 driver，不绑定 app
- 后续通过 `activateApp` 切到目标 app

### 3.3 查看与结束

```bash
ios-use session status    # 查看当前 session 信息和 driver 状态
ios-use session stop      # 结束 session 并清理
```

### 3.4 自动 session

所有 CLI 命令（dom、find、tap 等）内部通过 `withAutoSession` 自动管理 session：

- 如果已有活跃 session 且 UDID 匹配，直接复用
- 如果没有 session，自动创建
- 如果 session 断开，清理后报错

## 4. CLI 命令参考

所有 session 感知命令共享三个通用选项：

```
--udid <udid>         设备 UDID
--bundle-id <id>      App bundle ID
--verbose             详细输出
```

### 4.1 设备与配置

```bash
ios-use device                       # 列出真机和 Simulator
ios-use device --simulator           # 仅列出 Simulator
ios-use config --udid <udid>         # 签名并安装 driver
ios-use config --list                # 列出已配置设备
ios-use config --simulator --udid <udid>  # Simulator driver（免签名）
```

`config` 选项：

| 选项 | 说明 |
|------|------|
| `--udid <udid>` | 设备 UDID |
| `--list` | 列出已配置设备 |
| `--simulator` | Simulator 模式（免签名） |
| `--apple-id <email>` | Apple ID（首次需要） |
| `--password <pwd>` | Apple ID 密码 |
| `--ipa <path>` | 预构建 driver IPA 路径 |
| `--port <port>` | Driver 本地端口（默认 8100） |

### 4.2 App 生命周期

```bash
ios-use activateApp com.apple.Preferences    # 启动或前台切换 app
ios-use terminateApp com.apple.Preferences   # 终止 app
```

### 4.3 DOM 与查找

```bash
ios-use dom                           # 当前页面元素树（clean 格式）
ios-use dom --raw                     # 原始 XCUI snapshot 树
ios-use dom --save --name settings    # 保存到 ~/.ios-use/artifacts/settings.json
ios-use find "蓝牙"                   # 查找元素
ios-use find "开发者" --context.ancestor-type Table  # 消歧查找
ios-use waitFor --label "蓝牙" --timeout 8          # 轮询等待元素出现
```

说明：

- `dom` 默认返回 clean tree（只保留 label/value/rect/type）
- `dom --raw` 返回完整 snapshot 树
- `find/tap/longpress/input/swipe/waitFor` 共用同一套 label 查找语义
- `waitFor` 轮询间隔由 driver 内部控制，不对外暴露

### 4.4 点击与长按

```bash
# 按 label 点击
ios-use tap --label "通用"

# 坐标点击
ios-use tap --label 200,80

# 带偏移点击（相对元素左上角）
ios-use tap --label "亮度" --offset-x-ratio 0.8         # 水平 80% 处
ios-use tap --label "滑块" --offset-x 50 --offset-y 10  # 绝对像素偏移

# 长按
ios-use longpress --label "通用"
ios-use longpress --label "通用" --duration 800          # 自定义时长（ms）
```

`tap` offset 参数：

| 选项 | 类型 | 说明 |
|------|------|------|
| `--offset-x <px>` | 整数 | 相对元素左上角的绝对像素偏移 |
| `--offset-y <px>` | 整数 | 同上 |
| `--offset-x-ratio <ratio>` | 浮点 | 相对元素宽度的比例偏移（0.0~1.0） |
| `--offset-y-ratio <ratio>` | 浮点 | 同上 |

规则：

- 原点固定为元素左上角 `(0,0)`
- 缺失单轴时默认补 `0.5` ratio（元素中心）
- 绝对坐标 `label: "x,y"` 不能再传 offset
- `x` 和 `xRatio` 互斥，`y` 和 `yRatio` 互斥

### 4.5 滑动

```bash
# 目标驱动：滚动直到目标元素可见
ios-use swipe --to "开发者" --from "蓝牙"

# 固定距离滑动
ios-use swipe --dir forth --distance 300    # 向前（下/右）
ios-use swipe --dir back --distance 300     # 向后（上/左）
```

说明：

- `--to` / `--from` 支持 label 或 `"x,y"` 坐标
- `--dir` 只有 `forth` 和 `back` 两个值
- 自动检测竖直/水平方向
- 页面没变化时，先 `dom` 再决定是否继续滑

### 4.6 输入

```bash
ios-use input --label "搜索" --content "蓝牙"
```

说明：

- 不需要先 `tap` 输入框，命令会自动切换焦点再输入
- 不隐式 clear

### 4.7 截图

```bash
ios-use screenshot --name current-page
```

保存为 JPEG 到 `~/.ios-use/artifacts/<name>.jpg`。

### 4.8 系统日志（oslog）

```bash
ios-use oslog --pattern "Preferences" --name prefs-log
ios-use oslog --pattern "error" --flags i --timeout 5    # 轮询等待匹配
ios-use oslog --clear                                     # 清空 buffer
```

`oslog` 选项：

| 选项 | 说明 |
|------|------|
| `--pattern <pattern>` | 正则过滤 |
| `--flags <flags>` | 正则标志（`i` 不区分大小写、`s` dot 匹配换行、`m` 锚点匹配行） |
| `--timeout <seconds>` | 轮询等待匹配出现的超时时间 |
| `--name <name>` | 输出文件名前缀 |
| `--clear` | 清空 buffer，返回清除条数 |

说明：

- oslog 从设备的 OSLogStore 拉取系统日志（需要 iOS 15.0+）
- 设置 `--timeout` 时，会在窗口期内轮询直到匹配或超时
- 日志保存到 `~/.ios-use/artifacts/<name>.log`

### 4.9 App 日志（nslog）

```bash
ios-use nslog --grep "event_name"
ios-use nslog --grep "event_" --flags i --port 5555
```

`nslog` 选项：

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `--port <port>` | 0（自动分配） | 监听端口 |
| `--ssl` / `--no-ssl` | `true` | TLS 开关 |
| `--grep <pattern>` | - | 正则过滤 |
| `--flags <flags>` | `''` | 正则标志 |
| `--name <name>` | `''` | Bonjour 服务名 |
| `--publish-bonjour` / `--no-publish-bonjour` | `true` | Bonjour 发布开关 |

说明：

- nslog 启动本地 NSLogger server，iOS app 主动推送日志
- 适合验证 app 内 NSLog 埋点
- 与 oslog 互补：oslog 拉取系统日志，nslog 接收 app 日志

## 5. Flow 指南

### 5.1 执行 flow

```bash
ios-use flow my-flow.yaml
```

### 5.2 顶层字段

```yaml
name: 设置页冒烟
app: com.apple.Preferences     # 可选；指定时自动 terminate + activate
needLog: true                   # 自动启动 nslog 服务
vars:                           # 可选；输入变量
  targetLabel: 蓝牙
outputs: resultVar              # 可选；flow 返回值
steps:
  - action: waitFor
    label: ${vars.targetLabel}
    timeout: 8
```

- `app`：存在时，flow 启动前自动 `terminateApp` + `activateApp`
- `needLog`：设为 `true` 时自动启动 nslog 服务，flow 中的 `nslog` action 需要它；flow 结束时自动停止
- `vars`：输入变量，支持模板引用（`${vars.key}`）
- `outputs`：声明 flow 返回的变量名

### 5.3 支持的 action

**标准 action**（经 `executeStep` 执行，1:1 对应 driver 命令）：

| action | 说明 |
|--------|------|
| `tap` | 点击 |
| `input` | 输入文本 |
| `swipe` | 滑动 |
| `longpress` | 长按 |
| `dom` | 获取 DOM 树 |
| `find` | 查找元素 |
| `screenshot` | 截图 |
| `waitFor` | 轮询等待元素出现 |
| `activateApp` | 启动/切换 app |
| `terminateApp` | 终止 app |
| `oslog` | 拉取系统日志 |
| `nslog_start` | 启动 nslog 服务 |
| `nslog` | 查询 nslog 匹配 |
| `nslog_clear` | 清空 nslog 缓冲区 |

**Flow 编排 action**（不经 `executeStep`，在 flow 引擎层处理）：

| action | 说明 |
|--------|------|
| `runFlow` | 调用子 flow |
| `returnIf` | 条件满足时提前结束当前 flow |

**以下 action 不存在**，不要在 flow 中使用：

- ~~`wait`~~ — 没有固定等待 action；用 `waitFor` 配合一个必定存在的元素
- ~~`dismissPopup`~~ — 关弹窗用 `dom` + `candidates` + `tap`
- ~~`assert`~~ — 断言页面状态用 `waitFor`

### 5.4 Flow 编写原则

- 先手动，后组装：先用 CLI 验证动作语义，再写进 flow
- 先确认页面，再做动作：切页后先 `waitFor` 或 `dom`
- 能用 label 就不用坐标；坐标只作兜底
- 需要滚动到目标时，优先 `swipe --to`
- 关键节点保留 `dom` / `screenshot` / `oslog`，方便失败后定位
- 公共步骤抽成 subflow，不要复制粘贴

### 5.5 模板语法

Flow 中所有字符串字段支持 `${expression}` 模板替换：

```yaml
vars:
  targetLabel: 蓝牙

steps:
  - action: waitFor
    label: ${vars.targetLabel}     # 等价于 ${targetLabel}
    timeout: 5
```

规则：

- `${vars.key}` 和 `${key}` 等价（scope 自动展开）
- 整段 `${...}` 保留原始类型（对象、数组、数字、布尔值）
- 混合字符串中嵌入 `${...}` 会 stringify 拼接
- 支持嵌套路径：`${matchedNode.rect.0}`
- 缺失值会直接报错：`Missing template value: "${expr}"`

### 5.6 `vars` 与 `outputs`

**`vars`** 是唯一输入模型：

```yaml
vars:
  targetLabel: 蓝牙

steps:
  - action: waitFor
    label: ${vars.targetLabel}
    timeout: 5
```

**`outputs`** 是唯一结果回传模型：

```yaml
- action: find
  label: 蓝牙
  print: false
  outputs: matchedNode       # find 的返回值绑定到 matchedNode

- action: tap
  label: ${matchedNode.label}  # 后续 step 可引用
```

支持 `outputs` 的 action：`find`、`dom`、`runFlow`。

### 5.7 `runFlow`（subflow）

`runFlow` 是 subflow 的唯一调用方式：

主 flow：

```yaml
- action: runFlow
  file: ./subflow_wait_and_find.yaml
  vars:
    targetLabel: 蓝牙
  outputs: matchedNode

- action: tap
  label: ${matchedNode.label}
```

子 flow：

```yaml
name: "subflow: wait-and-find"
vars:
  targetLabel: 蓝牙
outputs: matchedNode
steps:
  - action: waitFor
    label: ${vars.targetLabel}
    timeout: 5

  - action: find
    label: ${vars.targetLabel}
    print: false
    outputs: matchedNode
```

语义：

- `file`：子 flow 文件路径，相对于当前 flow 文件解析
- `vars`：传给子 flow 的变量，覆盖同名的父 flow 变量
- `outputs`：从子 flow 导出的变量名，必须在子 flow 的顶层 `outputs` 中声明
- 循环引用检测：`A -> B -> A` 会直接报错

### 5.8 `dom.candidates`

`dom` 配合 `candidates` 可以在 flow 层做多候选查找：

```yaml
- action: dom
  candidates:
    - 取消
    - 关闭
    - 知道了
  outputs: popupDom

- action: returnIf
  value: ${popupDom.firstMatch}
  is: null

- action: tap
  label: ${popupDom.firstMatch.label}
```

派生逻辑：

- 递归展平所有 DOM 节点
- 按 `candidates` 顺序匹配（normalized 子串匹配）
- 返回 `matches`（全部命中）和 `firstMatch`（第一个命中，未命中为 `null`）
- 适用场景：弹窗按钮文案不固定、需要多候选兜底

### 5.9 `returnIf`

`returnIf` 是条件提前返回 action：

```yaml
- action: returnIf
  value: ${popupDom.firstMatch}    # 待检查的值
  is: null                         # 只允许 true / false / null
```

语义：

- `value === is` 时，立即结束当前 flow 并返回已声明的 `outputs`
- `value !== is` 时，继续执行后续 step
- 适用场景：弹窗未命中时 no-op 返回、前置条件已满足时跳过后续步骤

### 5.10 `tap offset`

Flow 中的 tap 支持 offset 偏移：

```yaml
- action: tap
  label: 亮度
  offset:
    xRatio: 0.8    # 元素宽度 80% 处
    yRatio: 0.5    # 元素高度 50% 处
```

offset 字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `x` | number | 绝对像素偏移 |
| `y` | number | 绝对像素偏移 |
| `xRatio` | number | 比例偏移（0.0~1.0） |
| `yRatio` | number | 比例偏移（0.0~1.0） |

规则与 CLI 一致：原点为元素左上角，缺失轴补 0.5，绝对坐标不能叠加 offset。

### 5.11 日志验证（oslog / nslog）

**oslog** — 拉取系统日志：

```yaml
- action: oslog
  pattern: Preferences
  flags: i
  bundleId: com.apple.Preferences
  timeout: 3
  name: settings-oslog
```

**nslog** — 推送式 app 日志（需要 `needLog: true`）：

```yaml
- action: nslog
  pattern: event=show_category
  timeout: 5
  clearAfterRead: true
```

区别：

- oslog：从设备 OSLogStore 拉取，适合系统日志和第三方 app 日志
- nslog：app 内 NSLog 主动推送，适合自定义埋点验证
- 两者都支持 `timeout` 轮询等待、`pattern` 正则过滤

### 5.12 关弹窗模板

```yaml
- action: dom
  candidates:
    - 取消
    - 关闭
    - 知道了
  outputs: popupDom

- action: returnIf
  value: ${popupDom.firstMatch}
  is: null

- action: tap
  label: ${popupDom.firstMatch.label}
```

### 5.13 中断与清理

- 第一次 Ctrl+C：优雅中断，等待当前 step 完成后停止
- 第二次 Ctrl+C：强制退出
- 中断时自动清理：断开 driver 连接、停止 nslog 服务、移除信号处理器

## 6. 排障

### 6.1 `session start` 失败

```bash
ios-use session stop 2>/dev/null || true
sleep 3
ios-use config --udid <udid>
ios-use session start --udid <udid> --bundle-id com.apple.Preferences
```

### 6.2 行为和预期不一致

- 先 `dom` 看当前页面
- 再 `find` 验证目标元素
- 必要时补 `screenshot`
- 加 `--verbose` 看完整输入输出

### 6.3 改了 driver 代码但行为没变

设备上还是旧 IPA：

```bash
bash scripts/build_host_app.sh
ios-use config --udid <udid>
```

### 6.4 真机日志与崩溃

- driver 日志前缀：`[driver]` / `[session]` / `[source]`
- 设备侧日志文件：`/tmp/ios-use-driver.log`
- 崩溃日志：`idevicecrashreport -k -u <udid> ~/iOS_Crash_Logs`

### 6.5 旧写法参考

不要再使用：

- `tap --text` → `tap --label`
- `input --text` → `input --content`
- `wait-for` → `waitFor`
- `app launch` → `activateApp`
- `app close` → `terminateApp`
- `waitFor --interval` → 不支持，轮询间隔由 driver 内部控制
- `nslog --interval-ms` → 不支持，轮询间隔固定 300ms
