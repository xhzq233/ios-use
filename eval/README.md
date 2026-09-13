# Agent evaluation

在真实 iPhone 上复跑同一自然任务，对照 **2.1.0 MCP / 原始 2.0.4 CLI**。
结果优先比较覆盖和正确性，然后报告任务耗时与**总 tokens**。

- [十应用盘点（简称「盘点」）](prompts/settings.txt)：手机名、键盘、前十个 App 权限；即原 case。
- [双应用深查（简称「深查」）](prompts/settings-comparison.txt)：手机信息、语言地区，及地图 / 抖音的定位与通知子页对比；即新 case。
- [2026-09-13 当前结果](reports/2026-09-13.md)：盘点 cb R2 已撤出；76a0779 的 R3 为 306.771 s / 1,326,647 tokens，覆盖较深，不混算同候选均值。
- [环境与版本记录](environment.md)。结果与原始轨迹暂留本地，不随方法提交。
- [CLI 配置](codex.toml)、[MCP 配置](codex-mcp.toml)。
- `run.py`：直接调用 `codex exec`，记录一次运行；也可离线汇总原始记录。
  只用 Python 标准库，无其他项目依赖，不提供导航、业务 helper、答案或评分器。

历史运行使用相同的 `codex exec` 参数，由另一通用调度脚本记录；这里提供独立的
轻量入口。它没有重跑历史样本。包装器和环境的变化须记录，不能假定能复现相同数字。

讨论单轮时使用「简称 / 候选 / 轮次」，例如 `盘点 / 210-cb / R2`。
本组 `gpt-6-astra / low` 样本中，`204` 指原始 2.0.4 CLI；`210-cb` 指
`cb21144` MCP；`210-1ef` 指历史 `1efc275` MCP。R1、R2 按同一 case 与候选
分别计数；本次后续修复样本简称 `210 / R3`，源码提交单列，不把它误写为 cb21144。
早期不同 effort 或 REPL 实验不混入。名称只便于指代，不改提示词、文件路径
或原始记录，也不增加 runner 参数。

## 1. 准备评测用户和版本

需要 Apple silicon Mac、USB 连接并解锁的测试 iPhone、可用的开发者签名，
以及支持目标模型的 Codex、Python 3.9+。当前 `cb21144` 的 MCP 不需要 Node.js；
历史 `1efc275` 使用 Node.js 22.18+。从源码构建另外需要
完整 Xcode 和 xcodegen。历史具体版本见[环境记录](environment.md)；模型不可用时不要静默替换。

建议使用专门的 macOS 评测用户。以下版本安装会替换该用户的全局 CLI、Driver
产物和 Skill。若复用工作账户，先备份安装并确认允许切换；不要将账号、签名或
设备配置写进仓库。保持同一 iPhone、系统语言、App 安装情况和权限状态不变。

从本仓根目录创建私有环境：

```bash
IOS_EVAL_REPO="$PWD"
mkdir -p "$HOME/.ios-use"
IOS_EVAL_ROOT="$(mktemp -d "$HOME/.ios-use/agent-eval.XXXXXX")"
mkdir -p "$IOS_EVAL_ROOT"/{codex-210,codex-204,workspace-210,workspace-204,results}
cp eval/codex-mcp.toml "$IOS_EVAL_ROOT/codex-210/config.toml"
cp eval/codex.toml "$IOS_EVAL_ROOT/codex-204/config.toml"
env CODEX_HOME="$IOS_EVAL_ROOT/codex-210" codex login
env CODEX_HOME="$IOS_EVAL_ROOT/codex-204" codex login
```

两个 Home 登录同一官方账号，不复制整个日常 Codex 配置。`CODEX_HOME` 隔离会话与
配置，但不会隔离操作系统文件或全局 Skill。保持两组其他 Skill / 插件清单一致，
只切换 ios-use Skill 的对应版本。工作目录内不放本仓、其他组答案或历史日志。
将 MCP 配置的 `command` 改成评测 CLI 的绝对路径；CLI 配置不含任何 MCP server。

**2.1.0 样本是未发布的源码候选** `1efc275e770e8c80454c45600bfd4a6bd55b3629`。
必须先取得该提交，不能用后来同名版本或 `main` 冒充历史候选。iPhone 场景可按以下
方式构建和安装；这不执行 Mac App 测试：

```bash
git worktree add --detach "$IOS_EVAL_ROOT/source-210" 1efc275e770e8c80454c45600bfd4a6bd55b3629
cd "$IOS_EVAL_ROOT/source-210"
bash scripts/build_swift_cli.sh
bash scripts/build_driver.sh --release
mkdir -p "$HOME/.local/bin" "$HOME/.ios-use"
install -m 755 ios-use "$HOME/.local/bin/ios-use"
install -m 644 driver/build/driver.ipa "$HOME/.ios-use/driver.ipa"
install -m 644 driver/build/driver-sim.ipa "$HOME/.ios-use/driver-sim.ipa"
bash scripts/install_skill.sh
cd "$IOS_EVAL_REPO"
export PATH="$HOME/.local/bin:$PATH"
```

确保 `command -v ios-use` 指向刚安装的二进制，且版本为 2.1.0；MCP 配置使用同一路径。
对已有非软链接 Skill 目录，installer 会保留并提示；先人工移到私有备份位置再安装。

2.0.4 条件使用原始发布产物及其配套 Skill，轮到它时运行现有 installer：

```bash
bash scripts/install.sh --version v2.0.4
```

本次原始远端 tag 为 `ef806a0e2fe770bf0d3ffe32ca3dfcb814ceec3c`；记录实际安装来源。
不要只切换 CLI 而留下另一版本的 Driver / Skill，也不要将本地同名 tag 的
重新构建产物等同于原始 Release 二进制。升级或降级前停止当前目标，安装后重新配置和
启动；具体签名 / DDI 恢复见 [setup](../ios-use-skill/references/setup.md)。

## 2. 每轮的计时外准备

```bash
ios-use --version
ios-use status
# 版本切换时：先用旧版本 stop，再安装新版本，然后执行下面两步。
ios-use config --udid '<device-id>'
ios-use start '<device-id>'
ios-use dom
```

- 只保留一个测试目标运行。记录 CLI / Driver / Skill 来源、Codex / Node / Python / Xcode
  和系统版本，另保存起点 DOM。不要公开原始设备 ID、手机名称、权限数据或完整配置。
  可用 `codex --version`、`node --version`、`python3 --version`、`sw_vers`、
  `xcodebuild -version` 回读；注意不同 cwd 的环境可能选择不同的 Python。
- 控制器将手机恢复到 **设置主列表底部（100%），搜索框为空**；确认不是 App 子页面。
  两轮使用同一起点。自动锁屏、通知或弹窗干扰要记录，不在候选运行中暗中修正。
- 检查对应 Home 的 MCP 清单：
  `env CODEX_HOME='<condition-home>' codex mcp list --json`。
  CLI 组应为空；MCP 组只有本次服务器。检查实际发现的 Skill 与工具清单，不以空 cwd
  推断“完全隔离”。
- MCP 通道首次使用时，在无模型 turn 的 MCP 客户端中确认 `js/js_reset`、跨调用变量、
  await、异常和图像输出；超过 30 秒的调用应使用足够的工具超时。参见
  [MCP 使用说明](../ios-use-skill/references/mcp.md)。通道探针不计 Agent 任务收益。
- 原生 quiescence 可能先于导航动画结束；不要把 Driver READY 或两次相同 AX 当成
  应用页面就绪的证明。记录真实失败和候选自身的恢复。

## 3. 串行各跑一次

以下命令会调用模型并消耗 tokens。`run.py` 不登录、不安装版本、不操作起点、
不重试、不调用额外 worker 或 judge。`danger-full-access / never` 与历史条件一致，
具有该 macOS 用户的完整权限；仅在允许真实 UI 操作的评测账户使用。

先安装并准备 2.1.0：

```bash
python3 eval/run.py run \
  --codex-home "$IOS_EVAL_ROOT/codex-210" \
  --cwd "$IOS_EVAL_ROOT/workspace-210" \
  --output "$IOS_EVAL_ROOT/results/210-mcp"
```

该轮完全结束后，控制器停止 Driver、安装 2.0.4、重新配置 / 启动并恢复同一起点，再运行：

```bash
python3 eval/run.py run \
  --codex-home "$IOS_EVAL_ROOT/codex-204" \
  --cwd "$IOS_EVAL_ROOT/workspace-204" \
  --output "$IOS_EVAL_ROOT/results/204-cli"
```

运行设置对比 case 时，向同一命令增加
`--prompt eval/prompts/settings-comparison.txt`。每个重复样本均使用新的 Home、空 cwd
和结果目录，不续跑旧会话；候选版本和运行顺序以对应评测记录为准。

默认模型 `gpt-6-astra`、effort `low`、每轮超时 1800 秒。启动后读取 transcript 的
实际 model / effort，若不同会终止该进程；不要继续第二组或自行补跑。
未读到实际配置时仍属未验证，需人工审阅后再继续。Ctrl-C / 超时会结束本轮进程组，
保留原始记录；已发出的设备动作可能完成，Driver 仍需控制器显式恢复。

候选执行期间不操作设备、不向候选提供另一组结果或补充路线。
出现故障只记录；额外模型 trial 需重新约定。测后恢复原安装及 Skill，确认设备页面和
Driver 状态；若只为本次试验启动，则停止它。不要自动清除保存的备份和日志。

## 4. 证据、计量和质量审阅

每轮保存 `request.json`、`exec.jsonl`、`stderr.log`、`final.txt`、`summary.json`。
完整 transcript 位于对应 Codex Home 的 `sessions/`，summary 保存其实际路径。
**完整归档包含整个本轮目录和 transcript；不要把认证目录随结果打包。**
原始记录不改写，分享前先人工脱敏，默认不放 Git。

离线汇总不产生模型调用：

```bash
python3 eval/run.py summarize /path/to/exec.jsonl \
  --transcript /path/to/rollout.jsonl
```

- **总 tokens = input_tokens + output_tokens**。cached input 已含在 input，reasoning
  output 已含在 output，不重复相加。字段缺失保持未知；总 tokens 不等于账单金额。
  `summarize` 面向本协议的单个 fresh turn；不要用它合并 resumed / 多轮会话。
- 任务耗时取 `task_complete.duration_ms`；进程 Wall 取启动到结束的单调时钟。
  安装、签名、起点恢复不计入。离线汇总不会从事件时间戳猜进程 Wall。
- 核对 exec 与 transcript 累计 usage；需要逐响应审计时按 `response_id` 去重后加总。
  候选、预检、失败 trial、主控制器 / reviewer 的消耗分开报告，不能把候选总量称为
  整项开发工作的总消耗。
- 汇总中的 `tools` 只计 shell 与 MCP 调用（包括读 Skill）；被脚本捕获的内部异常
  不一定构成一次失败工具调用。完整失败分析仍需回看工具返回。
- 人工回读实际工具输出，核对手机名、键盘、前十个 App 顺序及已报告字段。
  区分主页面与嵌套子页；未显示不等于关闭。检查是否改设置、跨接口或控制器介入。
  进程成功退出不构成任务 PASS，不靠最终答复自评。
- 可选统计 Driver 日志中候选时间段的 DOM / action RPC 与 TCP 接入；DOM RPC
  不等于命令内部的全部 AX 采样。没有日志时保留未知，不从工具调用数推导。

原提示词没有规定子页读取深度。自然任务复跑应原样保留并报告覆盖差异；若要严格
等工作量对照，先为两组共同约定“只读主页面”或“包括哪些子页”，另记为新实验，
不要回改历史提示词。单对版本结果不证明 MCP 的独立因果收益或稳定提速。
