#!/usr/bin/env bash
set -euo pipefail

IOS_USE_BIN="${IOS_USE_BIN:-ios-use}"
server=""
port=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      [[ $# -ge 2 ]] || { echo "--server requires a value" >&2; exit 2; }
      server="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 2; }
      port="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s --server <ip-or-host> --port <port>\n' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$server" || -z "$port" ]]; then
  echo "Usage: $0 --server <ip-or-host> --port <port>" >&2
  exit 2
fi

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
"$IOS_USE_BIN" waitFor --label "手动" --timeout 3
"$IOS_USE_BIN" tap "手动"
"$IOS_USE_BIN" waitFor --label "服务器" --timeout 3
"$IOS_USE_BIN" input --tap "服务器" --content "$server"
"$IOS_USE_BIN" input --tap "端口" --content "$port"
"$IOS_USE_BIN" tap "配置代理" --traits NavigationBar --offset-ratio "0.88,0.41"
