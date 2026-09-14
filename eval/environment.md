# Settings 评测环境

2026-09-12 的环境与版本记录；[复跑方法](README.md)包含安装、起点准备、执行和恢复。
此文件不包含评测结果、账号、设备 ID 或原始轨迹。

| 项目 | 条件 |
| --- | --- |
| 主机 | Apple silicon，macOS 15.7.7（24G720） |
| 构建工具 | Xcode 26.0（17A324） |
| Node / Python | 22.18.0 / 3.11.14 |
| 手机 | USB 真机 iPhone 17，iOS 26.5.1，简体中文 |
| 起点 | 设置主列表底部 100%，空搜索框 |
| 模型 / provider / effort | gpt-6-astra / openai / low |
| Codex CLI | 0.153.4 |
| 权限模式 | danger-full-access，approval never |
| 会话 | 两个空 cwd、两个 Codex Home，同一认证账号；无旧会话续跑 |
| Skill | 当组版本的 ios-use Skill；其他全局 Skill 清单两组相同 |
| MCP | 本地 stdio，启动超时 20 s、工具超时 310 s；CLI 组不注册 MCP |
| MCP 候选 | 2.1.0，源码提交 `1efc275e770e8c80454c45600bfd4a6bd55b3629`，当时未发布 |
| CLI 候选 | 原始 v2.0.4 Release 二进制、Driver 和配套 tag Skill；远端 tag `ef806a0e2fe770bf0d3ffe32ca3dfcb814ceec3c` |
| 每轮超时 | 1800 s |

主机和工具版本来自同机环境回读；实际模型、effort、Codex 和手机版本由原始轨迹
核对。`run.py` 同时记录自身的 Python / 主机版本，该入口支持 Python 3.9+。
不同 cwd 的环境可能选择不同 Python，应在实际运行目录回读。

独立 Codex Home 不隔离全局 Skill、操作系统文件或账号级缓存。历史工具 / Skill
目录包含本任务未使用的其他条目，其完整私有上下文不公开；复跑者应记录自己两组
实际发现的目录。另一台手机的 App 安装和权限状态也会不同，因此可重跑方法，不保证
历史答案、上下文长度、缓存命中和耗时逐项相同。
