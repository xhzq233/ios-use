# ios-use Flow 编写规范

## 1. 目标

- 这个文件只讲一件事：如何用 `ios-use flow` 编写可维护、可复用、可排查的自动化流程
- 手动操作手机、单步排障、日志导出，优先看 `SKILL.md`
- 写 flow 之前，先用 CLI 手动跑通每一步，再把它们组装成 YAML

## 2. 最小模板

```yaml
name: Settings Search
app: com.apple.Preferences
needNSLog: true
steps:
  - action: waitFor
    label: 蓝牙
    timeout: 8

  - action: tap
    label: 蓝牙

  - action: dom
    save: true
    name: settings-bluetooth
```

- `name`：flow 名称，建议能说明页面或目标
- `app`：可选；指定目标 app，常用于主 flow；入口 flow 会切到目标 app，不要再把 `terminateApp` / `activateApp` / `openURL` 当成通用前置步骤写进 flow
- `needNSLog`：设为 `true` 时自动启动 nslog capture 进程并等待 app 连接，flow 中的 `nslog` action 需要它
- `steps`：按顺序执行的动作列表

## 3. 支持的 action

标准 action（经 `executeStep` 执行）：

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
- `openURL`
- `dismissAlert`
- `oslog`
- `nslog`

Flow 编排 action（不经 `executeStep`，在 flow 引擎层处理）：

- `runFlow`
- `returnIf`
- `sleep`

**以下 action 不存在**，不要在 flow 中使用：

- ~~`wait`~~ — 没有固定等待 action；需要等待时用 `waitFor` 配合一个必定存在的元素
- ~~`dismissPopup`~~ — 关弹窗用 `dismissAlert` 或 `dom` + `candidates` + `tap`
- ~~`assert`~~ — 断言页面状态用 `waitFor`

## 4. 编写原则

- 先手动，后组装：先用 CLI 验证动作语义，再写进 flow
- 先确认页面，再做动作：切页后先 `waitFor` 或 `dom`
- 能用 label 就不用坐标；坐标只作兜底
- 需要滚动到目标时，优先 `swipe --to` 对应的 flow 写法
- 关键节点保留 `dom` / `oslog`，方便失败后定位
- 公共前置条件和公共收尾动作抽成 subflow，不要在多个 flow 里重复粘贴

## 5. 核心字段

### 5.1 `vars`

- `vars` 是唯一输入模型
- 顶层 `vars` 是默认值；CLI 外部变量可以覆盖同名默认值
- CLI 外部变量写法：`ios-use flow <file> --targetLabel 蓝牙 --timeout 5`
- `--udid`、`--verbose` 等 flow 命令自身选项不进入 `vars`
- 普通字符串字段支持模板替换，例如 `${vars.targetLabel}`
- 整段 `${...}` 可以传对象或数组原值，不只限于字符串
- 实现上应在解析后的 flow runtime 合并外部变量，不能靠拼接 YAML 注入新的 `vars:` 块
- 执行前会先 compile 整个 flow；静态错误会在任何 driver step 执行前失败
- 含模板的字段在 compile 阶段只校验外层结构，运行时解析后再做最终类型/格式校验

```yaml
vars:
  targetLabel: 蓝牙

steps:
  - action: waitFor
    label: ${vars.targetLabel}
    timeout: 5
```

运行时覆盖默认值：

```bash
ios-use flow settings.yaml --targetLabel Wi-Fi
```

适合 proxy 这类需要从 CLI 注入运行时参数的 flow：

```bash
ios-use flow flows/proxy_set_wifi_proxy.yaml --server 192.168.1.10 --port 9080
```

### 5.2 `outputs`

- `outputs` 是唯一结果回传模型
- `outputs` 只写变量名，不做映射
- 第一批支持写入 `outputs` 的 action 只有 `find` / `dom` / `runFlow`

```yaml
- action: find
  label: 蓝牙
  print: false
  outputs: matchedNode
```

### 5.3 `runFlow`

- `runFlow` 是 subflow 的唯一调用方式
- 调用方通过 `vars` 传参
- 被调 flow 通过顶层 `outputs` 声明返回值
- 如果主 flow 请求了未声明的 output，会直接报错
- `runFlow` 会检测循环引用，`A -> A` 和 `A -> B -> A` 都会直接失败

主 flow：

```yaml
- action: runFlow
  file: ./subflow_wait_and_find.yaml
  vars:
    targetLabel: 蓝牙
  outputs: matchedNode

- action: find
  label: ${matchedNode.label}
  print: false
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

### 5.4 `dom.candidates`

- `dom` 原始返回不变，`candidates` 只在 Flow 层做派生
- 可派生出 `matches` 和 `firstMatch`
- 排序先按 `candidates` 顺序，再按 DOM 遍历顺序
- 没命中时，`firstMatch` 为 `null`

```yaml
- action: dom
  candidates:
    - 取消
    - 关闭
  outputs: popupDom

- action: tap
  label: ${popupDom.firstMatch.label}
```

适用场景：

- 弹窗有多个可能按钮文案，但你只想命中第一优先候选
- 当前 `find` 不支持一次传多个 label 时，用 `dom + candidates` 做 flow 层选择

### 5.5 `tap offset`

- `offset.x/y`：相对目标元素左上角 `(0,0)` 的绝对像素偏移（整数）
- `offset.xRatio/yRatio`：相对目标元素宽高的比例偏移（浮点，范围 `0..1`）
- 缺失单轴时，默认补 `0.5` ratio
- `offset` 只对元素 label 生效
- 如果 `label` 是绝对坐标 `x,y`，再传 `offset` 会直接报错

```yaml
- action: tap
  label: 亮度
  offset:
    xRatio: 0.8
```

### 5.6 `returnIf`

- `returnIf` 是 Flow 编排 action，不会操作设备
- 用途是“当前条件满足时，立即结束当前 flow”
- 字段固定为：
  - `value`：模板解析后的任意值
  - `is`：只允许 `true` / `false` / `null`
- 当 `value === is` 时，立即结束当前 flow
- 当 `value !== is` 时，继续执行后续 step
- `returnIf` 不支持 `outputs`

```yaml
- action: dom
  candidates:
    - 取消
    - 关闭
  outputs: popupDom

- action: returnIf
  value: ${popupDom.firstMatch}
  is: null

- action: tap
  label: ${popupDom.firstMatch.label}
```

适用场景：

- 公共 subflow 里做 no-op 返回
- 弹窗候选未命中时直接结束当前 flow
- 某个前置条件已经满足时提前返回，避免重复动作

## 6. 常用 action 写法

### 6.1 `waitFor`

- 用于等待元素出现或变为可见
- 轮询间隔是内部固定值 `100ms`，不对外暴露 `interval`

```yaml
- action: waitFor
  label: 蓝牙
  timeout: 8
```

### 6.2 `find`

- 用于拿到结构化节点，常和 `outputs` 配合
- 找不到或命中歧义时会直接失败
- `traits` 支持逗号分隔多值，AND 语义（元素必须同时包含所有指定 trait）
- `cindex` 支持按 cleaned child 顺序选择父元素的直接 child，允许负数，`-1` 表示最后一个 child

```yaml
- action: find
  label: 蓝牙
  traits: Cell
  cindex: -1
  print: false
  outputs: bluetoothNode
```

```yaml
- action: find
  label: 开关
  traits: "Cell,Switch"
  print: false
```

### 6.3 `dom`

- 用于观察当前页面全量结构
- 调试阶段建议多用
- 需要落盘时加 `save: true`
- 非 raw DOM 保存为 JSON，结构为 `{ dom, matches, firstMatch }`；raw DOM 保存为 `.txt`

```yaml
- action: dom
  save: true
  name: settings-home
  print: false
```

### 6.x Compile 校验

- 未知字段会直接报错，不会静默忽略。
- `outputs` 只支持 `find` / `dom` / `runFlow` / `swipe`。
- 静态字段类型严格：`raw: "true"`、`clear: 1`、`offset: "-50,-50"` 都会失败。
- `offset` 必须写成对象，例如 `{x: -50, y: -50}` 或 `{xRatio: 0.8}`。
- 静态 `runFlow.file` 的子 flow 会在父 flow 执行前一起校验。

### 6.4 `swipe`

- **目标导向（推荐）**：通过 `to` / `from` 自动循环滚动，直到目标进入可见区域
  - 目标不需要初始可见，但必须已在 AX 树中（不确定时先 `dom` 确认）
  - `from` 是锚点，传一个当前可见的元素，从它所在的可滚动区域开始滚动；**目标不在当前屏幕时必须传 `from`**
  - 不传 `from` 时目标必须初始可见，否则返回 not found
  - 方向自动推断，无需手动指定
- 固定距离：通过 `dir + distance` 做纯距离滚动
- `traits` / `cindex` 只作用于 `to`，不作用于 `from`

```yaml
# 推荐：自动循环滚动到目标可见
- action: swipe
  to: 开发者
  from: 蓝牙
  cindex: -1
```

```yaml
# 固定距离滚动
- action: swipe
  dir: forth
  distance: 300
```

### 6.5 `oslog`

- `timeout` 在窗口期内轮询匹配
- `bundleId` 按 subsystem/category/process/消息内容过滤
- `clear: true` 清空 buffer
- 适合验证某个动作之后系统日志是否出现

```yaml
- action: oslog
  pattern: Preferences
  flags: i
  bundleId: com.apple.Preferences
  timeout: 3
  name: settings-oslog
```

### 6.6 `sleep`

- 等待指定毫秒，用于页面切换后等 UI 渲染、弹窗延迟出现等时序场景
- `ms` 可选，不传默认 `1000ms`（1 秒）
- 不显示、不计入步数（`--verbose` 时可见）
- 可被 Ctrl+C 中断

```yaml
- action: sleep           # 默认等待 1000ms

- action: sleep
  ms: 500
```

### 6.7 `nslog`

- 需要 `needNSLog: true`（自动启动 nslog capture 进程并等待 app 连接）
- `pattern` 是正则匹配，`timeout` 轮询等待匹配出现
- `clearAfterRead: true` 读取后截断当前 flow 的 nslog 文件，避免后续 action 重复命中
- flow 内 `nslog` 从本次 flow 的 capture 文件读取，不更新全局 `ios-use nslog read` 使用的 `lastCapture`
- 适合验证 app 内 NSLog 埋点是否触发

```yaml
- action: nslog
  pattern: event=show_category
  timeout: 5
  clearAfterRead: true
```

### 6.8 `openURL`

- 在设备上打开 URL（Safari 处理）
- Simulator flow 运行时走 Mac 侧 `xcrun simctl openurl`，不发送 driver `openURL` command
- 真机当前仍走 legacy driver openURL 路径
- `url` 是必填字段

```yaml
- action: openURL
  url: "https://example.com"
```

### 6.9 `dismissAlert`

- 关闭当前系统 Alert 弹窗
- 不传 `index` 时默认点击最后一个按钮
- `index` 是 0-based，`0` 表示第一个按钮

```yaml
- action: dismissAlert

- action: dismissAlert
  index: 0
```

### 6.10 关闭弹窗

没有 `dismissPopup` action。关闭弹窗的标准做法：

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

## 7. 推荐工作流

1. 先手动跑通目标页面上的每个动作
2. 把稳定可复用的前置过程抽成 subflow
3. 用 `vars` 传输入，用 `outputs` 传回结果
4. 在关键节点保留 `dom` / `oslog`
5. 运行 `ios-use flow your-flow.yaml`
6. 如果失败，回到 `SKILL.md` 的 CLI 工作流逐步单步复现

## 8. 常见错误

- 一上来就写大 flow，不先手动验证：最后很难知道是哪一步语义错了
- 用坐标代替 label：页面稍微变化就脆
- 公共步骤复制多份：后期改一个弹窗策略要改很多地方
- 把多候选查找硬塞给 `find`：应该改用 `dom + candidates`
- 在绝对坐标 `label: "x,y"` 上继续叠加 `offset`：这是非法组合
- 使用不存在的 action（`dismissPopup`、`assert`、`wait`）：只用第 3 节列出的 action

## 9. 中断与清理

- 第一次 Ctrl+C：优雅中断，等待当前 step 完成后停止
- 第二次 Ctrl+C：强制退出
- 中断时自动清理临时资源、停止 nslog capture
- `needNSLog: true` 的 flow 结束时自动停止 nslog capture 进程（无论正常结束还是中断）
