#!/usr/bin/env python3
"""Export an existing trusted pairing record and enable this host's Wi-Fi connection.

No pairing, passwords or signing accounts are created. The output is a credential:
import it in Self Runner, then remove the exported copy when no longer needed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import socket
import ssl
import struct
import tempfile


class PreparationError(Exception):
    pass


def exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise PreparationError("Device closed the connection")
        data.extend(chunk)
    return bytes(data)


def plist_reply(stream, header_size=4):
    header = exact(stream, header_size)
    size = struct.unpack(">I", header)[0] if header_size == 4 else struct.unpack("<IIII", header)[0] - 16
    if not 0 < size <= 16 * 1024 * 1024:
        raise PreparationError("Invalid device response length")
    value = plistlib.loads(exact(stream, size))
    if not isinstance(value, dict):
        raise PreparationError("Device returned a non-dictionary response")
    return value


def mux_request(stream, value):
    data = plistlib.dumps(dict(value, ProgName="ios-use"))
    stream.sendall(struct.pack("<IIII", 16 + len(data), 1, 8, 1) + data)
    return plist_reply(stream, 16)


def lockdown_request(stream, value):
    data = plistlib.dumps(dict(value, Label="ios-use"))
    stream.sendall(struct.pack(">I", len(data)) + data)
    reply = plist_reply(stream)
    if "Error" in reply:
        raise PreparationError("Lockdown rejected %s: %s" % (value["Request"], reply["Error"]))
    return reply


def pairing_bytes(value):
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return base64.b64decode(value, validate=True)
    raise PreparationError("Pairing record has an invalid certificate or key")


def enable_wireless(open_mux, udid, pair, artifacts):
    stream = open_mux()
    try:
        devices = mux_request(stream, {"MessageType": "ListDevices"}).get("DeviceList", [])
        match = next((d for d in devices if d.get("Properties", {}).get("SerialNumber") == udid), None)
        if match is None:
            raise PreparationError("Device is not present on the selected usbmux connection")
        device_id = match.get("DeviceID", match["Properties"].get("DeviceID"))
        reply = mux_request(stream, {"MessageType": "Connect", "DeviceID": device_id,
                                     "PortNumber": socket.htons(62078)})
        if reply.get("Number") != 0:
            raise PreparationError("Could not open the device's Lockdown service")
        reply = lockdown_request(stream, {"Request": "StartSession", "HostID": pair["HostID"],
                                           "SystemBUID": pair["SystemBUID"]})
        if reply.get("EnableSessionSSL"):
            artifacts.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="self-runner-pairing-", dir=artifacts) as temporary:
                files = [Path(temporary) / "certificate.pem", Path(temporary) / "key.pem"]
                for path, key in zip(files, ["HostCertificate", "HostPrivateKey"]):
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, "wb") as output:
                        output.write(pairing_bytes(pair[key]))
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                # Lockdown uses the imported host certificate for authentication;
                # its server certificate is self-signed by the pairing identity.
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
                context.load_cert_chain(str(files[0]), str(files[1]))
                stream = context.wrap_socket(stream)
        lockdown_request(stream, {"Request": "SetValue", "Domain": "com.apple.mobile.wireless_lockdown",
                                   "Key": "EnableWifiConnections", "Value": True})
    finally:
        stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", help="Already-paired device; required without --connection")
    parser.add_argument("--connection", type=Path, help="Provider's ios-use device-connection.json")
    parser.add_argument("--output", required=True, type=Path, help="New owner-only pairing file; never overwritten")
    parser.add_argument("--skip-wireless", action="store_true", help="Export only; do not enable Wi-Fi connections")
    args = parser.parse_args()
    connection = json.loads(args.connection.read_text()) if args.connection else None
    udid = args.udid or (connection or {}).get("udid")
    if not udid:
        parser.error("--udid or --connection is required")
    if connection and args.udid and args.udid != connection["udid"]:
        parser.error("--udid does not match --connection")
    if args.output.exists() or args.output.is_symlink():
        parser.error("Output already exists; choose a new path")

    def open_mux():
        if connection:
            endpoint = connection["usbmux"]
            return socket.create_connection((endpoint["host"], endpoint["port"]), timeout=15)
        stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stream.settimeout(15)
        try:
            stream.connect("/var/run/usbmuxd")
            return stream
        except BaseException:
            stream.close()
            raise

    with open_mux() as stream:
        reply = mux_request(stream, {"MessageType": "ReadPairRecord", "PairRecordID": udid})
    if "PairRecordData" not in reply:
        raise PreparationError("No existing trusted pairing record for the selected device")
    raw = pairing_bytes(reply["PairRecordData"])
    pair = plistlib.loads(raw)
    for key in ["HostID", "SystemBUID", "HostPrivateKey", "HostCertificate"]:
        if not pair.get(key):
            raise PreparationError("Incomplete pairing record")
    if not args.skip_wireless:
        state_root = Path(os.environ.get("IOS_USE_HOME", str(Path.home() / ".ios-use")))
        enable_wireless(open_mux, udid, pair, state_root / "artifacts")
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(raw)
    print("Pairing credential exported to the requested owner-only file.")
    if not args.skip_wireless:
        print("Wi-Fi developer connections enabled for this trusted host.")


if __name__ == "__main__":
    try:
        main()
    except (PreparationError, OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
