# Deprecated: NSLogger / nslog

`nslog` 已弃用，仅保留旧命令兼容。调用时会输出弃用提示。

- 普通 App 启动 stdout/stderr：`ios-use activateApp <bundleId> --terminateExisting --log`。
- Mac App stdout/stderr：`ios-use start --mac --app <App.app> --log`。
- 系统 unified log：`ios-use oslog`。

历史 NSLogger 采集仍可读取或停止：

```bash
ios-use nslog read --last 50
ios-use nslog stop
```

停止采集会保留已写入的日志文件。NSLogger 要求 App 主动集成，不能代替
普通 App 的 stdout/stderr 采集。
