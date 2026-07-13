# Proxy shell examples

These scripts are the user-facing replacement for the three bundled proxy YAML recipes. They are ordinary shell so an agent can inspect, edit, compose, or add cleanup around each step without a second workflow language.

Prerequisites:

- install `ios-use`, configure and start the target device (`ios-use start`);
- install mitmproxy before running the built-in proxy server (`ios-use proxy start`);
- for CA setup, start the built-in server first so `http://127.0.0.1:9088/ca.cer` is reachable;
- keep the device and Mac on the same Wi-Fi/LAN.

Examples:

```bash
bash examples/proxy/configca.sh
bash examples/proxy/set-wifi-proxy.sh --server 192.168.1.10 --port 9080
bash examples/proxy/clear-wifi-proxy.sh
```

Set `IOS_USE_BIN` when testing a local checkout, for example `IOS_USE_BIN=./ios-use bash examples/proxy/clear-wifi-proxy.sh`. The built-in `ios-use proxy start/stop/configca` remains the preferred stateful entry point; these scripts expose the underlying device steps for custom shell orchestration.
