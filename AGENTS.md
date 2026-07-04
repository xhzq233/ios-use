# ios-use

## 1. Project Overview

`ios-use` 是一个 Swift iOS 自动化 CLI，通过自研 TCP XCTest driver 控制 iOS 真机与 Simulator。Host 侧 Swift CLI 负责命令解析、session 编排、本地状态管理、Flow DSL、日志/代理等客户端能力；设备侧 Swift driver 负责 XCTest UI 操作、DOM 快照、Fory 二进制协议编解码和 TCP server。

核心路径：

- `swift-cli/`：Swift CLI、参数解析、session/device 状态、Flow、proxy/oslog/nslog/config 等 host 能力。
- `shared/IOSUseProtocol/`：Swift CLI 与 Swift driver 共用的 driver command、Fory frame 和 payload 模型。
- `scripts/`：Swift CLI/driver 构建、单测、Simulator command matrix、benchmark 等本地入口。
- `ios-use-skill/SKILL.md`：仓库内 ios-use skill 使用说明；CLI / Flow / API 用户可见语义变化时同步这里，不要改 `~/.ios-use/skill/SKILL.md` 作为仓库来源。
- `driver/tcp/`：Swift TCP server、Fory codec、Fory frame 编解码。
- `driver/ui/`：XCTest/XCUIElement 操作、DOM、元素等待/定位、tap/longpress/input/swipe、screenshot、waitFor、proxy CA 等 driver command。
- `swift-cli/Tests/`、`driver/tests/`：Swift CLI 与 Swift driver 单测。

当前实现、内部设计和边界行为以代码为准。

信息查找口径：

1. 当前实现与内部设计：优先读代码，尤其是 `swift-cli/`、`driver/`、`shared/IOSUseProtocol/`。
2. 测试口径与验收：优先读单测和测试脚本。
3. 历史回溯：优先读 git log、commit message 和仓库内现有文档。
4. 当前 CLI / Flow 用户契约：读 README、ios-use-skill 和命令 help。
5. 跨层边界和协议速查：必要时读 shared protocol、CLI 和 driver 代码。
6. 运维经验：读脚本、测试入口、日志命令和相关代码。

可信度口径：

- 当前行为：代码 > 单测 / 测试脚本 > 最小契约文档。
- 历史原因：plans / archive > 零散设计说明。
- 测试要求：单测、测试脚本 > design。
- 设计文档不是完整实现说明；遇到冲突时，以代码和直接覆盖该行为的测试为准。
- 历史文档中标注早期版本、排障过程、计划稿的内容不得直接复制为当前用法。
- Release 操作流程见 `docs/how-to-release.md`；需要发布时优先按该文档执行。

文档影响分级：

- 纯内部重构、代码整理、性能实现细节、无用户可见变化的测试补充：通常不改 design；按风险运行测试。
- 新功能或 bug fix：用轻量 plan / archive 记录背景、修复点、验收方式和结果；只有用户可见契约或跨层边界变化时才同步最小 design。
- CLI 参数、Flow DSL、默认值、输出、错误语义或状态副作用变化：更新最小契约，并补测试或测试文档。
- Driver/CLI 协议字段、连接/重试/状态边界变化：更新 `shared/IOSUseProtocol/`、相关代码和测试；必要时只更新对应 design 的边界速查。
- 测试口径、case id、CI 入口或验收矩阵变化：只更新单测/测试脚本和相关测试文档。
- `ios-use-skill/SKILL.md` 和 skill references 只在 CLI/Flow/API 的用户可见用法或语义变化时同步，且只写可操作的使用说明。改 skill 时站在使用者角度想“他需要知道什么”，不是站在开发者角度想“我刚实现了什么”。

## 2. Build & Commands

所有开发命令默认在仓库根目录执行。

Host 侧常用命令：

```bash
bash scripts/build_swift_cli.sh --debug  # 构建本地 Swift CLI 到 ./ios-use
./ios-use --help                       # 构建后的本地 Swift CLI
```

Driver 构建：

```bash
bash scripts/build_driver.sh            # Debug 构建，产物写入 IOS_USE_HOME 或当前目录 .ios-use/
bash scripts/build_driver.sh --release  # Release 构建，产物保留在 driver/build/
```

`scripts/build_driver.sh` 会从 `driver/project.yml` 重新生成 Xcode project 并构建 driver 产物。不要手动编辑 `driver/IOSUseDriver.xcodeproj` / `project.pbxproj`；Swift 源码变更后运行该脚本即可。

Driver 测试规划：

```bash
bash scripts/test_driver_unit.sh        # 显式运行 Swift driver 单测
bash scripts/ci_test.sh                 # Swift CLI 单测 + Swift driver 单测 + build
bash scripts/ci_test.sh --skip-builds   # 本地快速验证：单测 + 脚本检查，不重复 build
bash scripts/ci_full_simulator.sh       # 完整 headless Simulator command test
```

`test_driver_unit.sh` / `ci_test.sh` 默认使用固定保留的 `IOSUseTest` Simulator。Simulator command test 使用独立 `IOS_USE_HOME`，默认 `~/.ios-use/test-homes/simulator-commands`，可用 `IOS_USE_TEST_HOME` 覆盖；测试脚本不暴露 `--udid`，也不能覆盖或污染默认 `~/.ios-use/config.json` / `~/.ios-use/state/session.json`。
`test_driver_unit.sh` 默认使用 `~/.ios-use/test-homes/driver-unit` 作为 `IOS_USE_HOME`，避免写入真实 `~/.ios-use` state；只有显式传入 `IOS_USE_HOME` 时才使用外部 home。该脚本不依赖 Node；Node 只用于 full Simulator runner 和 benchmark 工具。

真机/Simulator 调试入口：

```bash
./ios-use status
xcrun simctl list devices booted
./ios-use config --udid <udid>
./ios-use config --simulator --udid <simulator-udid>
./ios-use start <udid>
./ios-use dom
./ios-use flow flows/test_flow.yaml
./ios-use stop
```

CLI 调试必须使用 `./ios-use` 或 `bash scripts/build_swift_cli.sh` 产物，不要使用全局 `ios-use`，全局命令可能指向已安装版本，不一定包含当前改动。
`status` 只汇总 USB 真机、当前 driver、日志采集、NSLog、Proxy 和配置状态，不列出 Simulator；需要 Simulator UDID 时用 `xcrun simctl list devices booted`。
真机首次配置涉及 Apple ID 签名时，密码必须走交互隐藏输入；即使 CLI 仍保留 `--password` 兼容入口，也不要通过命令行参数、日志、文档或测试 fixture 传递/记录 app password。

## 3. Code Style

- Swift CLI 参数校验集中使用严格 parser（如 `parseIntStrict`、`parseDoubleStrict`），不要用宽松转换直接吞错。
- `swift-cli/Sources/IOSUseCLI/CLIParser.swift` 负责命令/参数解析；`IOSUseCLI.swift` 保持执行入口清晰，不把 socket/usbmux/Fory 细节塞进 parser。
- socket/usbmux/Fory 协议逻辑保持在 Swift `DriverClient` / shared protocol 层。
- 本地状态、日志、产物路径统一通过 Swift `IOSUsePaths`，当前根目录为 `~/.ios-use/`；不要新增 `/tmp/ios-use` 或 `/tmp/WebDriverAgent` 作为当前路径口径。

## 4. Testing

- Host 单测使用 Swift Package XCTest，测试文件在 `swift-cli/Tests/`。
- Swift driver 单测在 `driver/tests/`。Swift CLI、driver 或 shared protocol 改动后，必须显式运行 `bash scripts/test_driver_unit.sh` 或默认 `bash scripts/ci_test.sh`；需要完整本地 Simulator 回归时运行 `bash scripts/ci_full_simulator.sh`，GitHub 上使用独立的 `Full Simulator` workflow 手动触发。
- 单测必须覆盖完整语义和边界，不要只测 happy path；尤其是 driver 侧 Swift 改动，必须补 `driver/tests/` 中的算法、协议、错误分支或状态边界测试。
- 单测 mock 必须隔离本地环境：不得直接读写真实 `~/.ios-use/`、真实配置、真实 session、真实 artifacts、真实 Apple 账号材料或真实设备状态；需要文件系统状态时使用临时 HOME / 临时目录，并在 `afterEach` 恢复。
- `mock.module` / 全局 monkey patch 必须在测试结束恢复，不能污染同一进程里的其他测试；优先用依赖注入或局部 fake，避免 mock 公共模块导致跨文件副作用。
- 改动 CLI 参数、Flow DSL、协议字段、错误语义时，必须有对应验收；只更新受影响的权威文档和测试说明，避免把同一语义复制到多处。
- Flow 测试不能只看 runner 输出 `completed`；涉及 UI 语义时需要在 Simulator/真机上逐步验证 tap/swipe/assert 等实际效果。
- 排查 UI、网络、弹窗、元素状态时优先使用本项目命令（如 `dom`、`waitFor`、`tap`、`screenshot`、proxy/log-read/oslog 相关命令）实际观察，不要凭空假设；旧 NSLogger / `nslog` 只在 App 已接入 NSLogger 或 Flow 明确依赖 `needNSLog` 时使用。
- UI/driver 命令实测按页面状态依赖串行执行；`tap` / `swipe` / `input` / `dismissAlert` / `flow` 等会改变界面或依赖当前页面的命令不要并发。同一 session 上只有不互相依赖的只读观察命令才可以并行，且一旦出现 TCP read failure 或页面状态竞争，先回到串行复现并查原因。
- Driver 代码使用 `NSLog()` 输出日志（不是 `print()`）；设备上 driver 日志前缀包括 `[driver]`、`[session]`、`[source]`，日志会写入 `~/.ios-use/logs/driver.log`。
- 新增或调整本地测试脚本时，必须避免破坏开发机环境：不要覆盖真实 Apple ID/签名配置/真机 session/proxy state；如需临时写 `~/.ios-use/config.json` 或 `~/.ios-use/state/session.json`，必须先备份并在退出时恢复。

## 5. Security

- `.env`、`.env.*`、`assets/`、`dist/`、`driver/build/`、`docs/private/`、`release/` 已在 `.gitignore` 中；不要提交本地密钥、签名产物、私有文档、日志或构建产物。
- `config` 会交互处理 Apple ID / app password、签名后的 driver bundle id 和本地配置；不要在日志、文档、测试 fixture 中写入真实账号、密码、UDID 或证书材料。
- 对外发布前必须检查 Git tracked 内容和 Git 历史中的敏感信息，不只检查当前工作树。重点包括 commit author/committer 邮箱、绝对本机路径、公司/组织路径、私有文档路径、真实 App 路径、完整 UDID、账号、证书和日志片段。

## 6. Configuration

- 运行时：Swift executable；本地 CLI bin 为仓库根目录 `./ios-use`，开发脚本入口见 `scripts/README.md`。当前构建、测试、安装和 Release 不依赖 npm metadata。
- Driver 配置：`driver/project.yml` 是 XcodeGen source of truth；Swift 版本为 5.9，iOS deployment target 为 16.0。
- Host 本地目录：`~/.ios-use/`，包含 `config.json`、`state/session.json`、`logs/driver.log`、`artifacts/` 等；Debug CLI 未设置 `IOS_USE_HOME` 时，driver IPA 开发产物使用当前目录 `.ios-use/`。
- 真机 driver IPA 文件名为 `driver.ipa`，Simulator driver IPA 文件名为 `driver-sim.ipa`。Debug CLI 从 `IOS_USE_HOME` 读取，未设置时从当前目录 `.ios-use/` 读取；Release CLI 从安装目录读取。
