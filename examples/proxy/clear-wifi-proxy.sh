#!/usr/bin/env bash
set -euo pipefail

# Copyable replacement for the former proxy_clear_wifi_proxy.yaml recipe.
IOS_USE_BIN="${IOS_USE_BIN:-ios-use}"

"$IOS_USE_BIN" terminateApp com.apple.Preferences
"$IOS_USE_BIN" activateApp com.apple.Preferences
sleep 1
"$IOS_USE_BIN" tap "com.apple.settings.wifi"
"$IOS_USE_BIN" waitFor --label "信号强度" --traits "Cell,selected" --timeout 5
"$IOS_USE_BIN" tap "信号强度" --traits "Cell,selected" --offset-ratio "0.9,0.5"
"$IOS_USE_BIN" swipe --to "配置代理"
"$IOS_USE_BIN" waitFor --label "配置代理" --timeout 3
"$IOS_USE_BIN" tap "配置代理"
sleep 0.5
"$IOS_USE_BIN" waitFor --label "关闭" --timeout 3
"$IOS_USE_BIN" tap "关闭"
"$IOS_USE_BIN" tap "配置代理" --traits NavigationBar --offset-ratio "0.88,0.41"
