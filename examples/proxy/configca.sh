#!/usr/bin/env bash
set -euo pipefail

# Copyable replacement for the former proxy_configca.yaml recipe.
IOS_USE_BIN="${IOS_USE_BIN:-ios-use}"

"$IOS_USE_BIN" terminateApp com.apple.Preferences
"$IOS_USE_BIN" activateApp com.apple.Preferences
"$IOS_USE_BIN" terminateApp com.apple.mobilesafari
"$IOS_USE_BIN" open "http://127.0.0.1:9088/ca.cer"
"$IOS_USE_BIN" tap "允许" --traits Button
"$IOS_USE_BIN" dismissAlert

"$IOS_USE_BIN" activateApp com.apple.Preferences
"$IOS_USE_BIN" waitFor --label "已下载描述文件" --timeout 5
"$IOS_USE_BIN" tap "已下载描述文件"

for _ in 1 2 3; do
  "$IOS_USE_BIN" waitFor --label "安装" --traits Button
  "$IOS_USE_BIN" tap "安装" --traits Button
done

"$IOS_USE_BIN" waitFor --label "完成"
"$IOS_USE_BIN" tap "完成"
"$IOS_USE_BIN" waitFor --label "BackButton"
"$IOS_USE_BIN" tap "BackButton"
"$IOS_USE_BIN" swipe --to "关于本机"
"$IOS_USE_BIN" tap "关于本机"
"$IOS_USE_BIN" swipe --to "证书信任设置" --from "iOS版本"
"$IOS_USE_BIN" tap "证书信任设置"
"$IOS_USE_BIN" tap "mitmproxy" --traits "Cell,Switch" --offset-ratio "0.9,"
"$IOS_USE_BIN" tap "继续"
