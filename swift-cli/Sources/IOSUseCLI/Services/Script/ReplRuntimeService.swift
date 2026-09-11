import Darwin
import Foundation

final class ReplDriverSessionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: LockedDriverClientSession] = [:]

    func session(paths: IOSUsePaths) -> LockedDriverClientSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[paths.driverLock] {
            return existing
        }
        let created = LockedDriverClientSession(paths: paths)
        sessions[paths.driverLock] = created
        return created
    }

    func close() {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        current.forEach { $0.close() }
    }

    deinit {
        close()
    }
}

private struct ReplRPCRequest: Decodable {
    let id: Int
    let arguments: [String]?
    let imagePath: String?
    let emitImage: Bool?
}

private struct ReplRPCResponse: Encodable {
    let id: Int
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let imageBase64: String?
}

private final class ReplRPCServer: @unchecked Sendable {
    let port: Int

    private let paths: IOSUsePaths
    private let listenerFD: Int32
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let work = DispatchGroup()
    private let pool = ReplDriverSessionPool()
    private var clientFD: Int32 = -1
    private var stopped = false

    init(paths: IOSUsePaths) throws {
        self.paths = paths
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("failed to create REPL host socket")
        }
        listenerFD = fd
        setSocketNoSigPipe(fd)

        var one: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let value = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue(
                "failed to bind REPL host socket: errno \(value)"
            )
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard inspected == 0 else {
            let value = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue(
                "failed to inspect REPL host socket: errno \(value)"
            )
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let accepted = Darwin.accept(listenerFD, nil, nil)
            guard accepted >= 0 else { return }
            setSocketNoSigPipe(accepted)
            stateLock.lock()
            if stopped {
                stateLock.unlock()
                Darwin.close(accepted)
                return
            }
            clientFD = accepted
            stateLock.unlock()
            defer {
                stateLock.lock()
                let ownsClient = clientFD == accepted
                if ownsClient {
                    clientFD = -1
                }
                stateLock.unlock()
                if ownsClient {
                    Darwin.shutdown(accepted, SHUT_RDWR)
                    Darwin.close(accepted)
                }
            }
            readRequests(from: accepted)
        }
    }

    func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let client = clientFD
        clientFD = -1
        stateLock.unlock()
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        if client >= 0 {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        work.wait()
        pool.close()
    }

    private func readRequests(from descriptor: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                work.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { work.leave() }
                    handle(line, descriptor: descriptor)
                }
            }
        }
    }

    private func handle(_ data: Data, descriptor: Int32) {
        let response: ReplRPCResponse
        do {
            let request = try JSONDecoder().decode(ReplRPCRequest.self, from: data)
            if let arguments = request.arguments {
                let cli = IOSUseCLI(
                    pathsForTesting: paths,
                    replDriverSessions: pool
                )
                let result = cli.run(arguments: arguments)
                response = ReplRPCResponse(
                    id: request.id,
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    imageBase64: nil
                )
            } else if let imagePath = request.imagePath {
                let root = URL(fileURLWithPath: paths.root)
                    .standardizedFileURL.path
                let candidate = URL(fileURLWithPath: imagePath)
                    .standardizedFileURL.path
                guard candidate.hasPrefix(root + "/") else {
                    throw CLIParseError.invalidValue(
                        "REPL image path is outside IOS_USE_HOME"
                    )
                }
                let image = try Data(contentsOf: URL(fileURLWithPath: candidate))
                if request.emitImage == true {
                    let environment = ProcessInfo.processInfo.environment
                    if let directory = environment["DEVICE_RELAY_ARTIFACT_DIR"],
                       let fdText = environment["DEVICE_RELAY_ARTIFACT_FD"],
                       let fd = Int32(fdText) {
                        let name = "screenshot-\(UUID().uuidString)." + URL(fileURLWithPath: candidate).pathExtension
                        try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                        try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                            .write(contentsOf: Data((name + "\n").utf8))
                        response = ReplRPCResponse(id: request.id, exitCode: 0, stdout: "", stderr: "", imageBase64: nil)
                    } else {
                        response = ReplRPCResponse(id: request.id, exitCode: 0, stdout: "Image: \(candidate)\n", stderr: "", imageBase64: nil)
                    }
                } else {
                response = ReplRPCResponse(
                    id: request.id,
                    exitCode: 0,
                    stdout: "",
                    stderr: "",
                    imageBase64: image.base64EncodedString()
                )
                }
            } else {
                throw CLIParseError.invalidValue("invalid REPL host request")
            }
        } catch {
            let requestID = (try? JSONDecoder().decode(
                ReplRPCRequest.self,
                from: data
            ).id) ?? 0
            response = ReplRPCResponse(
                id: requestID,
                exitCode: 1,
                stdout: "",
                stderr: "\(error)",
                imageBase64: nil
            )
        }
        do {
            var encoded = try JSONEncoder().encode(response)
            encoded.append(0x0A)
            writeLock.lock()
            defer { writeLock.unlock() }
            try writeAll(fd: descriptor, data: encoded)
        } catch {
            return
        }
    }
}

enum ReplRuntimeService {
    static func run(options: ReplOptions, paths: IOSUsePaths) -> CLIResult {
        do {
            let server = try ReplRPCServer(paths: paths)
            let source = try sourcePayload(options.source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "node",
                "--permission",
                "--input-type=module",
                "-e",
                javaScriptSource,
                "--",
                source.mode,
                String(server.port),
                Data(source.code.utf8).base64EncodedString(),
                source.filename,
            ]
            let environment = ProcessInfo.processInfo.environment
            process.environment = [
                "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": environment["LANG"] ?? "en_US.UTF-8",
                "LC_ALL": environment["LC_ALL"] ?? "en_US.UTF-8",
                "NODE_NO_WARNINGS": "1",
            ]
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            server.start()
            try process.run()
            // Foundation starts the child in its own process group. Give it
            // the terminal while it reads interactive input, then restore us.
            let terminal = STDIN_FILENO
            let foreground = isatty(terminal) == 1 ? tcgetpgrp(terminal) : -1
            if foreground > 0 {
                let previousSignal = signal(SIGTTOU, SIG_IGN)
                defer { signal(SIGTTOU, previousSignal) }
                if tcsetpgrp(terminal, process.processIdentifier) == 0 {
                    kill(process.processIdentifier, SIGCONT)
                }
                process.waitUntilExit()
                _ = tcsetpgrp(terminal, foreground)
            } else {
                process.waitUntilExit()
            }
            server.stop()
            return CLIResult(exitCode: process.terminationStatus)
        } catch {
            return CLIErrorEnvelope(
                message: "Unable to start the ios-use REPL. Install Node.js and retry: \(error)",
                exitCode: 1
            ).render()
        }
    }

    private static func sourcePayload(
        _ source: ReplSource
    ) throws -> (mode: String, code: String, filename: String) {
        switch source {
        case .inline(let code):
            return ("once", code, "<ios-use-repl>")
        case .file(let path):
            return (
                "once",
                try String(contentsOfFile: path, encoding: .utf8),
                path
            )
        case .standardInput:
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let code = String(data: data, encoding: .utf8) else {
                throw CLIParseError.invalidValue("REPL stdin must be UTF-8")
            }
            return ("once", code, "<stdin>")
        case .repl:
            return ("interactive", "", "<ios-use-repl>")
        }
    }

    static let javaScriptSource = #"""
    import net from "node:net";
    import repl from "node:repl";
    import { registerHooks } from "node:module";
    import { PassThrough } from "node:stream";
    import { inspect } from "node:util";

    const [mode, portValue, payloadBase64 = "", filename = "<ios-use-repl>"] = process.argv.slice(1);
    const source = Buffer.from(payloadBase64, "base64").toString("utf8");
    const socket = net.createConnection({ host: "127.0.0.1", port: Number(portValue) });
    const pending = new Map();
    const imagePaths = new WeakMap();
    let nextID = 1;
    let incoming = "";

    const connected = new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });

    socket.on("data", chunk => {
      incoming += chunk.toString("utf8");
      for (;;) {
        const newline = incoming.indexOf("\n");
        if (newline < 0) break;
        const line = incoming.slice(0, newline);
        incoming = incoming.slice(newline + 1);
        if (!line) continue;
        const response = JSON.parse(line);
        const completion = pending.get(response.id);
        if (!completion) continue;
        pending.delete(response.id);
        completion.resolve(response);
      }
    });
    socket.on("error", error => {
      for (const completion of pending.values()) completion.reject(error);
      pending.clear();
    });
    socket.on("close", () => {
      const error = new Error("ios-use REPL host disconnected");
      for (const completion of pending.values()) completion.reject(error);
      pending.clear();
    });

    async function rpc(payload) {
      await connected;
      const id = nextID++;
      return await new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        socket.write(JSON.stringify({ id, ...payload }) + "\n", error => {
          if (!error) return;
          pending.delete(id);
          reject(error);
        });
      });
    }

    class IOSUseCommandError extends Error {
      constructor(envelope, fallback) {
        super(envelope?.error?.message ?? fallback ?? "ios-use command failed");
        this.name = "IOSUseCommandError";
        this.command = envelope?.command ?? null;
        this.code = envelope?.error?.code ?? null;
        this.category = envelope?.error?.category ?? null;
        this.retryable = envelope?.error?.retryable ?? false;
        this.mutationMayHaveApplied = envelope?.error?.mutationMayHaveApplied ?? false;
        this.data = envelope?.data ?? null;
        this.interaction = envelope?.interaction ?? null;
        this.warnings = envelope?.warnings ?? [];
      }
    }

    function decodeEnvelope(text) {
      const value = String(text ?? "").trim();
      if (!value) return null;
      try {
        const decoded = JSON.parse(value);
        return typeof decoded === "object" && decoded !== null ? decoded : null;
      } catch {
        return null;
      }
    }

    async function runCLI(deviceId, command, args = []) {
      const argv = ["--json"];
      if (deviceId !== null) argv.push("--device", deviceId);
      argv.push(command, ...args.map(String));
      const result = await rpc({ arguments: argv });
      const envelope = decodeEnvelope(result.stdout) ?? decodeEnvelope(result.stderr);
      if (!envelope) {
        throw new IOSUseCommandError(null, result.stderr || `${command} did not return JSON`);
      }
      if (result.exitCode !== 0 || !envelope.ok) {
        throw new IOSUseCommandError(envelope, result.stderr);
      }
      return envelope.data;
    }

    function textValue(value) {
      return typeof value === "string" ? value.trim() : "";
    }

    function elementText(element) {
      return textValue(element.label) || textValue(element.value) || textValue(element.identifier);
    }

    function elementKey(element) {
      const identifier = textValue(element.identifier);
      if (identifier) return `id:${identifier}`;
      const label = textValue(element.label);
      if (label) return `label:${element.semanticType ?? element.type}:${label}`;
      return [element.semanticType, element.hierarchy?.depth, element.hierarchy?.index]
        .map(value => String(value ?? ""))
        .join("|");
    }

    function keyedElements(elements) {
      const occurrences = new Map();
      return elements.map((element, index) => {
        const base = elementKey(element);
        const occurrence = occurrences.get(base) ?? 0;
        occurrences.set(base, occurrence + 1);
        return { key: `${base}#${occurrence}`, element, index };
      });
    }

    function elementSignature(element) {
      return JSON.stringify([
        element.semanticType,
        element.label,
        element.value,
        element.identifier,
        element.traits,
        element.frame,
        element.state,
      ]);
    }

    function projectElement(element, index) {
      const traits = Array.isArray(element.traits) ? element.traits : [];
      // XCTest DOM carries state in traits; its unused structured fields decode as false.
      const hasStructuredState = Boolean(textValue(element.semanticType));
      return {
        element_index: index,
        role: textValue(element.semanticType) || textValue(element.type) || traits[0] || "Element",
        label: textValue(element.label),
        value: textValue(element.value),
        identifier: textValue(element.identifier),
        traits,
        frame: Array.isArray(element.frame) ? element.frame : null,
        enabled: hasStructuredState ? (element.state?.enabled ?? null) : !traits.includes("disabled"),
        selected: hasStructuredState ? (element.state?.selected ?? null) : traits.includes("selected"),
        focused: hasStructuredState ? (element.state?.focused ?? null) : traits.includes("focused"),
        visible: hasStructuredState ? (element.state?.visible ?? null) : !traits.includes("invisible"),
        depth: element.hierarchy?.depth ?? 0,
      };
    }

    function shortText(value) {
      const normalized = textValue(value).replaceAll(/\s+/g, " ");
      return normalized.length > 80 ? `${normalized.slice(0, 77)}...` : normalized;
    }

    function formatElement(element, marker = " ") {
      const fields = [];
      const label = shortText(element.label);
      const value = shortText(element.value);
      if (label) fields.push(JSON.stringify(label));
      if (value && value !== label) fields.push(`value=${JSON.stringify(value)}`);
      if (!label && !value && element.identifier) fields.push(`id=${JSON.stringify(element.identifier)}`);
      if (element.enabled === false) fields.push("disabled");
      if (element.selected === true) fields.push("selected");
      if (element.focused === true) fields.push("focused");
      if (element.visible === false) fields.push("invisible");
      return `${marker}${"  ".repeat(Math.max(0, element.depth))}[${element.element_index}] ${element.role}${fields.length ? ` ${fields.join(" ")}` : ""}`;
    }

    const nodeRepl = Object.freeze({
      write(value) {
        const rendered = typeof value === "string" ? value : inspect(value, {
          colors: process.stdout.isTTY,
          depth: 8,
          maxArrayLength: 200,
          breakLength: 100,
        });
        process.stdout.write(rendered + (rendered.endsWith("\n") ? "" : "\n"));
      },
      async emitImage(image) {
        const path = imagePaths.get(image) ?? image?.path;
        if (!path) throw new TypeError("nodeRepl.emitImage expects bytes returned by getScreenshot");
        const result = await rpc({imagePath: path, emitImage: true});
        if (result.exitCode !== 0) throw new Error(result.stderr);
        if (result.stdout) process.stdout.write(result.stdout);
      },
    });

    class DeviceHandle {
      #current = null;
      #previous = null;

      constructor(info) {
        Object.assign(this, info);
      }

      help() {
        nodeRepl.write([
          "await device.getAXState({waitQuiescence: true}) // wait for UI animations before reading",
          "await device.getScreenshot()",
          "await device.getAXStateAndScreenshot()",
          "await device.click(element_index|string|[x,y])",
          "await device.setValue(element_index|string, value)",
          "await device.typeText(value)",
          "await device.pressKey(\"Return\")",
          "await device.scroll(element_index|[x,y], \"down\", 0.5) // fraction of the scroll viewport",
          "await device.scrollTo(text, anchor)",
          "await device.waitFor(text, {gone: true, timeout: 20})",
        ].join("\n"));
      }

      async refresh() {
        const state = await cua.getState({ emit: false });
        const info = state.devices.find(device => device.id === this.id);
        if (!info) throw new Error(`Device ${this.id} is no longer known to ios-use`);
        Object.assign(this, info);
        return this;
      }

      async getAXState(options = {}) {
        if (options.disableDiffing === true) this.#previous = null;
        const args = ["--fresh"];
        if (options.waitQuiescence === true) args.push("--wait-quiescence");
        const data = await runCLI(this.id, "dom", args);
        const rawElements = Array.isArray(data.elements) ? data.elements : [];
        const elements = rawElements.map(projectElement);
        const previousEntries = keyedElements(this.#previous?.rawElements ?? []);
        const currentEntries = keyedElements(rawElements);
        const previousByKey = new Map(previousEntries.map(entry => [entry.key, entry]));
        const currentKeys = new Set();
        const markers = [];
        currentEntries.forEach(({ key, element, index }) => {
          currentKeys.add(key);
          const prior = previousByKey.get(key);
          markers.push(!prior ? "+" : prior.index !== index || elementSignature(prior.element) !== elementSignature(element) ? "~" : " ");
        });
        const removed = previousEntries
          .filter(entry => !currentKeys.has(entry.key))
          .map(entry => formatElement(projectElement(entry.element, entry.index), "-"));
        this.#current = { rawElements, elements };
        this.#previous = { rawElements };
        const header = `Device ${this.id} ${typeof data.app === "string" ? data.app : data.app?.bundleId ?? ""}`.trim();
        const changed = elements.flatMap((element, index) => markers[index] === " " ? [] : [formatElement(element, markers[index])]);
        const state = [header, ...removed, ...changed, ...(!removed.length && !changed.length ? ["No AX changes."] : [])]
          .filter(Boolean)
          .join("\n");
        if (options.emit !== false) nodeRepl.write(state);
        return state;
      }

      async getScreenshot(options = {}) {
        this.#current = null;
        this.#previous = null;
        const data = await runCLI(this.id, "screenshot", ["--no-ocr"]);
        const response = await rpc({ imagePath: data.imagePath });
        if (response.exitCode !== 0 || !response.imageBase64) {
          throw new Error(response.stderr || "ios-use screenshot bytes unavailable");
        }
        const bytes = Uint8Array.from(Buffer.from(response.imageBase64, "base64"));
        Object.defineProperty(bytes, "path", { value: data.imagePath, enumerable: false });
        imagePaths.set(bytes, data.imagePath);
        if (options.emit !== false) await nodeRepl.emitImage(bytes);
        return bytes;
      }

      async getAXStateAndScreenshot(options = {}) {
        const screenshot = await this.getScreenshot({ emit: false });
        const state = await this.getAXState({ ...options, emit: false });
        if (options.emit !== false) {
          nodeRepl.write(state);
          await nodeRepl.emitImage(screenshot);
        }
        return { state, screenshot };
      }

      async click(target) {
        const resolved = this.#resolveTarget(target);
        try {
          return await runCLI(this.id, "tap", [resolved.target]);
        } finally {
          this.#current = null;
        }
      }

      async setValue(target, value) {
        if (typeof target === "string") {
          if (!this.#current) await this.getAXState({emit: false});
          const matches = this.#current.elements.filter(element => [element.label, element.value, element.identifier].includes(target));
          if (matches.length !== 1) throw new Error("setValue requires one observed editable target; select its element_index");
          target = matches[0].element_index;
        }
        const resolved = this.#resolveTarget(target);
        const args = ["--tap", resolved.target, "--content", String(value)];
        const deleteCount = Array.from(resolved.element?.value ?? "").length;
        if (deleteCount > 0) args.push("--delete", String(deleteCount));
        try {
          return await runCLI(this.id, "input", args);
        } finally {
          this.#current = null;
        }
      }

      async typeText(value) {
        try {
          return await runCLI(this.id, "input", ["--content", String(value)]);
        } finally {
          this.#current = null;
        }
      }

      async paste(value, options = {}) {
        if (options.format && options.format !== "text") throw new TypeError("ios-use paste supports plain text only");
        return await this.typeText(value);
      }

      async waitFor(text, options = {}) {
        const args = [String(text), "--timeout", `${options.timeout ?? 10}s`];
        if (options.gone) args.push("--gone");
        if (options.match) args.push("--match", options.match);
        await runCLI(this.id, "waitFor", args);
        return await this.getAXState({emit: options.emit});
      }

      async scrollTo(text, anchor, options = {}) {
        const args = ["--to", String(text)];
        if (anchor !== undefined) args.push("--from", this.#resolveTarget(anchor).target);
        try { await runCLI(this.id, "swipe", args); }
        finally { this.#current = null; }
        return await this.getAXState({emit: options.emit});
      }

      async pressKey(key) {
        if (String(key).toLowerCase() !== "return") {
          throw new TypeError("ios-use currently supports pressKey(\"Return\") only");
        }
        try {
          return await runCLI(this.id, "input", ["--content", "", "--enter"]);
        } finally {
          this.#current = null;
        }
      }

      async scroll(target, direction = "down", pages = 1) {
        const directions = { down: [1, -1], right: [0, -1], d: [1, -1], r: [0, -1], up: [1, 1], left: [0, 1], u: [1, 1], l: [0, 1] };
        const axisAndSign = directions[String(direction).toLowerCase()];
        if (!axisAndSign) throw new TypeError("scroll direction must be up, down, left, or right");
        const amount = Number(pages);
        if (!Number.isFinite(amount) || amount <= 0) throw new TypeError("scroll pages must be a positive finite number");
        // Resolve indices before any implicit observation can give them a new meaning.
        const resolved = target === undefined || target === null ? null : this.#resolveTarget(target);
        if (!this.#current) await this.getAXState({emit: false});
        const [x, y, width, height] = this.#scrollFrame(resolved);
        const [axis, sign] = axisAndSign;
        const extent = axis === 0 ? width : height;
        const center = [x + width / 2, y + height / 2];
        let remaining = extent * amount;
        let result;
        try {
          // Keep each drag inside the observed viewport, including multi-page requests.
          while (remaining > 0) {
            const distance = Math.min(remaining, extent * 0.75);
            const from = center.slice();
            const to = center.slice();
            // Start in the inner quarter, matching Driver scroll gestures;
            // centering a long drag can start under a navigation-bar overlay.
            from[axis] -= sign * extent / 4;
            to[axis] = from[axis] + sign * distance;
            result = await runCLI(this.id, "swipe", ["--from", from.join(","), "--to", to.join(",")]);
            remaining -= distance;
          }
          return result;
        } finally {
          this.#current = null;
        }
      }

      #scrollFrame(resolved) {
        const elements = this.#current.elements;
        const appFrame = elements[0]?.frame;
        if (!appFrame) throw new Error("No viewport in the current AX state");
        const scrollRoles = new Set(["scroll", "scrollview", "scrollarea", "table", "collection", "collectionview", "list"]);
        const isScrollable = element => element.visible !== false && scrollRoles.has(element.role.toLowerCase());
        let container;
        const anchor = resolved?.element ?? (resolved && elements.find(element =>
          [element.label, element.value, element.identifier].includes(resolved.target)
        ));
        if (anchor && isScrollable(anchor)) {
          container = anchor;
        } else {
          // XCTest's flat DOM may have no hierarchy depth; use the observed
          // anchor center to select the smallest containing scroll viewport.
          const point = anchor?.frame
            ? [anchor.frame[0] + anchor.frame[2] / 2, anchor.frame[1] + anchor.frame[3] / 2]
            : resolved?.target.split(",").map(Number);
          const candidates = elements.filter(element => {
            if (!isScrollable(element) || !element.frame) return false;
            const [x, y, width, height] = element.frame;
            return !point || (point[0] >= x && point[0] <= x + width && point[1] >= y && point[1] <= y + height);
          });
          candidates.sort((a, b) => {
            const areaDifference = a.frame[2] * a.frame[3] - b.frame[2] * b.frame[3];
            return (point ? areaDifference : -areaDifference) || b.element_index - a.element_index;
          });
          container = candidates[0];
        }
        if (!container?.frame) throw new Error("No observed scrollable at the target; read AX and select a scroll container or a point inside it");
        const [x, y, width, height] = container.frame;
        const left = Math.max(x, appFrame[0]);
        const top = Math.max(y, appFrame[1]);
        const right = Math.min(x + width, appFrame[0] + appFrame[2]);
        const bottom = Math.min(y + height, appFrame[1] + appFrame[3]);
        if (right <= left || bottom <= top) throw new Error("The scroll viewport is outside the current App frame");
        return [left, top, right - left, bottom - top];
      }

      get(selector) {
        if (!this.#current) throw new Error("No current AX state. Call await device.getAXState() first.");
        if (selector === undefined) return this.#current.elements.slice();
        if (Number.isInteger(selector)) {
          const element = this.#current.elements[selector];
          if (!element) throw new RangeError(`Unknown element_index ${selector}`);
          return element;
        }
        const query = String(selector).trim().toLocaleLowerCase();
        return this.#current.elements.filter(element =>
          [element.label, element.value, element.identifier, element.role]
            .some(value => String(value ?? "").toLocaleLowerCase().includes(query))
        );
      }

      #resolveTarget(target) {
        if (target && typeof target === "object" && Number.isInteger(target.element_index)) target = target.element_index;
        if (Number.isInteger(target)) {
          if (!this.#current) throw new Error("element_index is stale. Call await device.getAXState() first.");
          const element = this.#current.elements[target];
          if (!element) throw new RangeError(`Unknown element_index ${target}`);
          if (element.enabled === false || element.visible === false) throw new Error("Target is disabled or invisible; observe or scroll before acting");
          const text = elementText(element);
          const exactMatches = this.#current.elements.filter(candidate =>
            [candidate.label, candidate.value, candidate.identifier].some(value => textValue(value) === text)
          ).length;
          if (text && exactMatches === 1 && element.enabled !== false) return { target: text, element };
          if (Array.isArray(element.frame) && element.frame.length === 4) {
            const [x, y, width, height] = element.frame.map(Number);
            return { target: `${x + width / 2},${y + height / 2}`, element };
          }
          throw new Error(`element_index ${target} has no usable target`);
        }
        if (typeof target === "string" && target.length > 0) return { target, element: null };
        const point = Array.isArray(target) ? target : target && typeof target === "object" ? [target.x, target.y] : null;
        if (point?.length === 2 && point.every(value => Number.isFinite(Number(value)))) {
          return { target: `${Number(point[0])},${Number(point[1])}`, element: null };
        }
        throw new TypeError("target must be an element_index, semantic text, or [x, y]");
      }

      toJSON() {
        return { id: this.id, kind: this.kind, name: this.name, version: this.version, connected: this.connected, configured: this.configured, driver: this.driver };
      }
    }

    class CUARoot {
      #state = null;

      help() {
        nodeRepl.write([
          "await cua.getState()",
          "let device = await cua.getDevice(\"device-id\")",
          "await device.getAXState()",
          "await device.click(0)",
          "await device.getAXStateAndScreenshot()",
          "await Promise.all([deviceA.getAXState(), deviceB.getAXState()])",
          "Call device.help() for the current target API.",
        ].join("\n"));
      }

      async getState(options = {}) {
        this.#state = await runCLI(null, "status");
        if (options.emit !== false) nodeRepl.write(this.#state);
        return this.#state;
      }

      async getDevice(deviceId, options = {}) {
        if (typeof deviceId !== "string" || !deviceId) {
          throw new TypeError("cua.getDevice requires a stable Device ID");
        }
        const cached = Array.isArray(this.#state?.devices)
          ? this.#state.devices.find(device => device.id === deviceId)
          : null;
        const inferred = deviceId === "mac"
          ? { id: deviceId, kind: "mac", name: "Mac Backend" }
          : /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(deviceId)
            ? { id: deviceId, udid: deviceId }
              : null;
        const info = cached ?? inferred;
        if (!info) throw new Error(`Unknown Device ID ${deviceId}`);
        const device = new DeviceHandle(info);
        await device.getAXState(options);
        return device;
      }
    }

    const cua = new CUARoot();

    function installContext(server) {
      server.context.cua = cua;
      server.context.nodeRepl = nodeRepl;
      server.context.console = console;
      for (const name of ["process", "require", "module", "Buffer", "fetch", "WebSocket"]) {
        Object.defineProperty(server.context, name, { value: undefined, configurable: false });
      }
    }

    async function evaluate(code, sourceName) {
      const input = new PassThrough();
      const output = new PassThrough();
      const server = repl.start({ input, output, prompt: "", terminal: false, useGlobal: false });
      installContext(server);
      try {
        return await new Promise((resolve, reject) => {
          let settled = false;
          const finish = (callback, value) => {
            if (settled) return;
            settled = true;
            callback(value);
          };
          output.on("data", chunk => {
            const message = chunk.toString("utf8").trim();
            if (message) finish(reject, new Error(message));
          });
          server.eval(code, server.context, sourceName, (error, value) => {
            if (error) finish(reject, error);
            else finish(resolve, value);
          });
        });
      } finally {
        server.close();
        input.destroy();
        output.destroy();
      }
    }

    async function main() {
      await connected;
      registerHooks({
        resolve(specifier) {
          throw new Error(`Module imports are unavailable in ios-use repl: ${specifier}`);
        },
      });
      process.getBuiltinModule = undefined;
      if (mode === "interactive") {
        const server = repl.start({ prompt: "ios-use> ", useGlobal: false, ignoreUndefined: true });
        const evaluate = server.eval;
        server.eval = function(code, context, filename, callback) {
          evaluate.call(this, code, context, filename, error => callback(error, undefined));
        };
        installContext(server);
        server.once("exit", () => socket.end());
        return;
      }
      if (mode !== "once") throw new Error(`unknown ios-use repl mode: ${mode}`);
      await evaluate(source, filename);
      socket.end();
    }

    main().catch(error => {
      process.stderr.write(`${error?.stack ?? error}\n`);
      socket.destroy();
      process.exitCode = 1;
    });
    """#
}
