import Foundation
import Darwin

enum ScriptRuntimeService {
    static var executablePathOverrideForTesting: String?

    static func run(options: ScriptOptions) -> CLIResult {
        do {
            let nodeArguments = nodeArguments(
                options: options,
                cliPath: try currentExecutablePath()
            )
            var arguments: [UnsafeMutablePointer<CChar>?] =
                (["env", "node"] + nodeArguments).map { strdup($0) }
            arguments.append(nil)
            defer {
                for argument in arguments where argument != nil {
                    free(argument)
                }
            }
            execv("/usr/bin/env", &arguments)
            throw CLIParseError.invalidValue(
                "failed to execute Node.js: \(String(cString: strerror(errno)))"
            )
        } catch {
            return CLIErrorEnvelope(
                message: "Unable to start the JavaScript runtime. Install Node.js and retry: \(error)",
                exitCode: 1
            ).render()
        }
    }

    private static func nodeArguments(
        options: ScriptOptions,
        cliPath: String
    ) -> [String] {
        var arguments = [
            "--input-type=module",
            "-e",
            javaScriptSource,
            "--",
        ]
        switch options.source {
        case .inline(let source):
            arguments += ["inline", cliPath, source]
        case .file(let path):
            arguments += ["file", cliPath, path]
        case .standardInput:
            arguments += ["stdin", cliPath]
        case .repl:
            arguments += ["repl", cliPath]
        }
        return arguments
    }

    private static func currentExecutablePath() throws -> String {
        if let executablePathOverrideForTesting {
            return executablePathOverrideForTesting
        }
        if let path = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = CommandLine.arguments.first,
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
                .standardizedFileURL.path
        }
        throw CLIParseError.invalidValue(
            "cannot resolve the current ios-use executable"
        )
    }

    static let javaScriptSource = #"""
    import { execFile } from "node:child_process";
    import { readFile } from "node:fs/promises";
    import repl from "node:repl";
    import { PassThrough } from "node:stream";
    import { promisify, inspect } from "node:util";

    const execFileAsync = promisify(execFile);
    const [mode, cliPath, payload] = process.argv.slice(1);

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

      try {
        const result = await execFileAsync(cliPath, argv, {
          encoding: "utf8",
          maxBuffer: 16 * 1024 * 1024,
          env: process.env,
        });
        const envelope = decodeEnvelope(result.stdout);
        if (!envelope) {
          throw new Error(`${command} did not return a JSON envelope`);
        }
        if (!envelope.ok) throw new IOSUseCommandError(envelope);
        return envelope.data;
      } catch (error) {
        if (error instanceof IOSUseCommandError) throw error;
        const envelope = decodeEnvelope(error.stdout) ?? decodeEnvelope(error.stderr);
        if (envelope) throw new IOSUseCommandError(envelope, error.message);
        const detail = String(error.stderr ?? error.message ?? error).trim();
        throw new IOSUseCommandError(null, detail);
      }
    }

    function textValue(value) {
      return typeof value === "string" ? value.trim() : "";
    }

    function elementText(element) {
      return textValue(element.label)
        || textValue(element.value)
        || textValue(element.identifier);
    }

    function elementKey(element) {
      const identifier = textValue(element.identifier);
      if (identifier) return `id:${identifier}`;
      const label = textValue(element.label);
      if (/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(label)) {
        return `label-id:${label}`;
      }
      const path = Array.isArray(element.hierarchy?.path)
        ? element.hierarchy.path.join("/")
        : "";
      if (path) return `path:${path}`;
      return [
        element.semanticType,
        element.hierarchy?.depth,
        element.hierarchy?.index,
        ...(Array.isArray(element.ancestors) ? element.ancestors : []),
      ]
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
      const roleTrait = traits.find(value => [
        "Button", "Input", "Text", "Image", "Scroll", "Group",
        "NavigationBar", "TabBar", "Switch", "Slider", "Link",
      ].includes(value));
      return {
        element_index: index,
        role: textValue(element.semanticType) || textValue(element.type) || roleTrait || "Element",
        label: textValue(element.label),
        value: textValue(element.value),
        identifier: textValue(element.identifier),
        traits,
        frame: Array.isArray(element.frame) ? element.frame : null,
        enabled: element.state?.enabled ?? null,
        selected: element.state?.selected ?? null,
        focused: element.state?.focused ?? null,
      };
    }

    function shortText(value) {
      const normalized = textValue(value).replaceAll(/\s+/g, " ");
      if (!normalized) return "";
      return normalized.length > 80 ? `${normalized.slice(0, 77)}...` : normalized;
    }

    function formatElement(element, marker = " ") {
      const role = element.role || "Element";
      const label = shortText(element.label);
      const value = shortText(element.value);
      const identifier = shortText(element.identifier);
      const fields = [];
      if (label) fields.push(JSON.stringify(label));
      if (value && value !== label) fields.push(`value=${JSON.stringify(value)}`);
      if (!label && !value && identifier) fields.push(`id=${JSON.stringify(identifier)}`);
      if (element.enabled === false) fields.push("disabled");
      if (element.selected === true) fields.push("selected");
      if (element.focused === true) fields.push("focused");
      return `${marker}[${element.element_index}] ${role}${fields.length ? ` ${fields.join(" ")}` : ""}`;
    }

    class AXHandle {
      #device;
      #current = null;
      #previous = null;

      constructor(device) {
        this.#device = device;
      }

      help() {
        return [
          "await device.ax.write()",
          "await device.ax.write(\"screenshot\")",
          "await device.ax.write(\"both\")",
          "device.ax.get([element_index|string])",
          "await device.ax.click(element_index|string|{x,y})",
          "await device.ax.setValue(element_index|string, value)",
          "await device.ax.typeText(value[, {enter:true}])",
          "await device.ax.scroll({to, from, direction, distance})",
        ].join("\n");
      }

      async write(channel = "ax") {
        if (channel === "screenshot") {
          return await runCLI(this.#device.id, "screenshot");
        }
        if (channel === "both") {
          const ax = await this.#observe();
          const screenshot = await runCLI(this.#device.id, "screenshot");
          return { ax, screenshot };
        }
        if (channel !== "ax" && channel !== undefined && channel !== null) {
          throw new TypeError('ax.write channel must be "ax", "screenshot", or "both"');
        }
        return await this.#observe();
      }

      get(selector) {
        if (!this.#current) {
          throw new Error("No current AX snapshot. Call await device.ax.write() first.");
        }
        if (selector === undefined) return this.#current.elements.slice();
        if (Number.isInteger(selector)) {
          const element = this.#current.elements[selector];
          if (!element) throw new RangeError(`Unknown element_index ${selector}`);
          return element;
        }
        if (typeof selector === "string") {
          const query = selector.trim().toLocaleLowerCase();
          return this.#current.elements.filter(element =>
            [element.label, element.value, element.identifier, element.role]
              .some(value => String(value ?? "").toLocaleLowerCase().includes(query))
          );
        }
        throw new TypeError("ax.get expects an element_index or text query");
      }

      async click(target) {
        const resolved = this.#resolveTarget(target);
        try {
          return await runCLI(this.#device.id, "tap", [resolved.target]);
        } finally {
          this.#invalidate();
        }
      }

      async setValue(target, value) {
        const resolved = this.#resolveTarget(target);
        const args = ["--tap", resolved.target, "--content", String(value)];
        const existingValue = resolved.element?.value ?? "";
        const deleteCount = Array.from(existingValue).length;
        if (deleteCount > 0) args.push("--delete", String(deleteCount));
        try {
          return await runCLI(this.#device.id, "input", args);
        } finally {
          this.#invalidate();
        }
      }

      async typeText(value, options = {}) {
        const args = ["--content", String(value)];
        if (options?.enter === true) args.push("--enter");
        try {
          return await runCLI(this.#device.id, "input", args);
        } finally {
          this.#invalidate();
        }
      }

      async scroll(options = {}) {
        const normalized = typeof options === "string" ? { to: options } : options;
        if (!normalized || typeof normalized !== "object") {
          throw new TypeError("ax.scroll expects a target string or options object");
        }
        const args = [];
        if (normalized.to !== undefined) {
          args.push("--to", this.#resolveTarget(normalized.to).target);
        }
        if (normalized.from !== undefined) {
          args.push("--from", this.#resolveTarget(normalized.from).target);
        }
        if (normalized.direction !== undefined) {
          const directions = {
            down: "forth",
            right: "forth",
            forth: "forth",
            up: "back",
            left: "back",
            back: "back",
          };
          const direction = directions[String(normalized.direction)];
          if (!direction) {
            throw new TypeError("scroll direction must be up, down, left, right, forth, or back");
          }
          args.push("--dir", direction);
        }
        if (normalized.distance !== undefined) {
          args.push("--distance", String(normalized.distance));
        }
        if (args.length === 0) args.push("--dir", "forth");
        try {
          return await runCLI(this.#device.id, "swipe", args);
        } finally {
          this.#invalidate();
        }
      }

      async #observe() {
        const data = await runCLI(this.#device.id, "dom", ["--fresh"]);
        const rawElements = Array.isArray(data.elements) ? data.elements : [];
        const elements = rawElements.map(projectElement);
        const previousEntries = keyedElements(this.#previous?.rawElements ?? []);
        const currentEntries = keyedElements(rawElements);
        const previousByKey = new Map(
          previousEntries.map(entry => [entry.key, entry.element])
        );
        const added = [];
        const changed = [];
        const currentKeys = new Set();
        const markers = [];
        currentEntries.forEach(({ key, element }, index) => {
          currentKeys.add(key);
          const prior = previousByKey.get(key);
          if (!prior) {
            added.push(index);
            markers.push("+");
          } else if (elementSignature(prior) !== elementSignature(element)) {
            changed.push(index);
            markers.push("~");
          } else {
            markers.push(" ");
          }
        });
        const removed = previousEntries
          .filter(entry => !currentKeys.has(entry.key))
          .map(entry => formatElement(projectElement(entry.element, entry.index), "-"));

        this.#current = { rawElements, elements };
        const result = {
          deviceId: this.#device.id,
          app: data.app ?? null,
          snapshotGeneration: data.snapshotGeneration ?? null,
          elementCount: elements.length,
          changes: this.#previous
            ? {
                added,
                changed,
                removed,
                unchanged: elements.length - added.length - changed.length,
              }
            : null,
          tree: elements.map((element, index) => formatElement(element, markers[index])).join("\n"),
        };
        this.#previous = { rawElements };
        return result;
      }

      #resolveTarget(target) {
        if (target && typeof target === "object" && Number.isInteger(target.element_index)) {
          target = target.element_index;
        }
        if (Number.isInteger(target)) {
          if (!this.#current) {
            throw new Error("element_index is stale. Call await device.ax.write() first.");
          }
          const element = this.#current.elements[target];
          if (!element) throw new RangeError(`Unknown element_index ${target}`);
          const text = elementText(element);
          const exactMatches = this.#current.elements.filter(candidate =>
            [candidate.label, candidate.value, candidate.identifier].some(value => textValue(value) === text)
          ).length;
          if (text && exactMatches === 1 && element.enabled !== false) {
            return { target: text, element };
          }
          if (Array.isArray(element.frame) && element.frame.length === 4) {
            const [x, y, width, height] = element.frame.map(Number);
            if ([x, y, width, height].every(Number.isFinite) && width > 0 && height > 0) {
              return {
                target: `${x + width / 2},${y + height / 2}`,
                element,
              };
            }
          }
          throw new Error(`element_index ${target} has no usable semantic target or frame`);
        }
        if (typeof target === "string" && target.length > 0) {
          return { target, element: null };
        }
        if (target && typeof target === "object") {
          const x = Number(target.x);
          const y = Number(target.y);
          if (Number.isFinite(x) && Number.isFinite(y)) {
            return { target: `${x},${y}`, element: null };
          }
        }
        throw new TypeError("target must be an element_index, semantic text, or {x, y}");
      }

      #invalidate() {
        this.#current = null;
      }
    }

    class DeviceHandle {
      constructor(info) {
        this.id = info.id;
        this.kind = info.kind;
        this.name = info.name;
        this.version = info.version;
        this.connected = info.connected;
        this.configured = info.configured;
        this.driver = info.driver;
        this.ax = new AXHandle(this);
      }

      help() {
        return this.ax.help();
      }

      async refresh() {
        const state = await mobile.getState();
        const info = state.devices.find(device => device.id === this.id);
        if (!info) throw new Error(`Device ${this.id} is no longer known to ios-use`);
        this.kind = info.kind;
        this.name = info.name;
        this.version = info.version;
        this.connected = info.connected;
        this.configured = info.configured;
        this.driver = info.driver;
        return this;
      }

      toJSON() {
        return {
          id: this.id,
          kind: this.kind,
          name: this.name,
          version: this.version,
          connected: this.connected,
          configured: this.configured,
          driver: this.driver,
        };
      }
    }

    class MobileRoot {
      #state = null;

      help() {
        return [
          "await mobile.getState()",
          "let device = await mobile.getDevice(\"device-id\")",
          "await device.ax.write()",
          "await device.ax.click(0)",
          "await device.ax.write(\"both\")",
          "await Promise.all([deviceA.ax.write(), deviceB.ax.write()])",
          "Call device.help() for the full Device API.",
        ].join("\n");
      }

      async getState() {
        this.#state = await runCLI(null, "status");
        return this.#state;
      }

      async getDevice(deviceId) {
        if (typeof deviceId !== "string" || deviceId.length === 0) {
          throw new TypeError("mobile.getDevice requires a Device ID from mobile.getState()");
        }
        const state = this.#state ?? await this.getState();
        const info = Array.isArray(state.devices)
          ? state.devices.find(device => device.id === deviceId)
          : null;
        if (!info) throw new Error(`Unknown Device ID ${deviceId}`);
        return new DeviceHandle(info);
      }
    }

    const mobile = new MobileRoot();

    async function evaluate(source, filename) {
      const input = new PassThrough();
      const output = new PassThrough();
      output.resume();
      const server = repl.start({
        input,
        output,
        prompt: "",
        terminal: false,
        useGlobal: false,
      });
      server.context.mobile = mobile;
      server.context.console = console;
      try {
        return await new Promise((resolve, reject) => {
          let completed = false;
          const fail = error => {
            if (completed) return;
            completed = true;
            reject(error);
          };
          server._domain.once("error", fail);
          server.eval(source, server.context, filename, (error, value) => {
            if (completed) return;
            completed = true;
            server._domain.removeListener("error", fail);
            if (error) reject(error);
            else resolve(value);
          });
        });
      } finally {
        server.close();
      }
    }

    async function readStandardInput() {
      const chunks = [];
      for await (const chunk of process.stdin) chunks.push(chunk);
      return Buffer.concat(
        chunks.map(chunk => Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
      ).toString("utf8");
    }

    async function main() {
      if (mode === "repl") {
        const server = repl.start({ prompt: "ios-use> " });
        server.context.mobile = mobile;
        return;
      }

      let source;
      let filename;
      if (mode === "inline") {
        source = payload ?? "";
        filename = "<ios-use-script>";
      } else if (mode === "file") {
        if (!payload) throw new Error("script --file requires a path");
        source = await readFile(payload, "utf8");
        filename = payload;
      } else if (mode === "stdin") {
        source = await readStandardInput();
        filename = "<stdin>";
      } else {
        throw new Error(`unknown ios-use script mode: ${mode}`);
      }

      const value = await evaluate(source, filename);
      if (value !== undefined) {
        if (typeof value === "string") {
          process.stdout.write(value + "\n");
        } else {
          process.stdout.write(inspect(value, {
            colors: process.stdout.isTTY,
            depth: 8,
            maxArrayLength: 200,
            breakLength: 100,
          }) + "\n");
        }
      }
    }

    main().catch(error => {
      process.stderr.write(`${error?.stack ?? error}\n`);
      process.exitCode = 1;
    });
    """#
}
