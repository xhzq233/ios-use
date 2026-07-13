# NSLogger / nslog

`nslog` 是旧 NSLogger 入口。只有目标 App 已接入 NSLogger 时再用。普通 App 启动日志优先用主手册里的 `activateApp --terminateExisting --log`；系统 unified log 用 `oslog`。

## 常用命令

```bash
ios-use nslog
ios-use nslog start
ios-use nslog read --last 50
ios-use nslog read --pattern "finished" --timeout 10
ios-use nslog stop
```

- 前台 `ios-use nslog` 会启动本地 NSLogger server 并直接 stream 日志。
- `nslog start` 后台采集并写入 `~/.ios-use/logs/nslog-*.log`。
- `nslog read` 读取最近一次后台采集，支持 `--pattern`、`--flags`、`--timeout`、`--last`、`--clearAfterRead`。
- `nslog stop` 停止后台采集，已写入的日志文件会保留。

## 排障

- App 必须主动接入 NSLogger；没有接入时 `nslog` 收不到普通 stdout/stderr。
- 如果提示 stale local publisher 或 live nslog server，按 CLI 提示清理旧 `dns-sd` 或关闭旧 NSLogger viewer 后再试。
