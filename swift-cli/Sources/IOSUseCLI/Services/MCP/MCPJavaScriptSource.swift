enum MCPJavaScriptSource {
    static let code = #"""
    import net from "node:net";
    import repl from "node:repl";
    import { registerHooks } from "node:module";
    import { PassThrough } from "node:stream";
    import { inspect, formatWithOptions } from "node:util";
    import { AsyncLocalStorage } from "node:async_hooks";
    import { createInterface } from "node:readline";
    import { fileURLToPath } from "node:url";

    const [portValue] = process.argv.slice(1);
    const executionContext = new AsyncLocalStorage();
    function emit(content) {
      const execution = executionContext.getStore();
      if (!execution?.active) throw new Error("This JavaScript execution has ended");
      process.stdout.write(JSON.stringify({event: "content", content}) + "\n");
    }
    const socket = net.createConnection({ host: "127.0.0.1", port: Number(portValue) });
    socket.setEncoding("utf8");
    const pending = new Map();
    let nextID = 1;
    let incoming = "";

    const connected = new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });

    socket.on("data", chunk => {
      incoming += chunk;
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
      const error = new Error("ios-use JavaScript host disconnected");
      for (const completion of pending.values()) completion.reject(error);
      pending.clear();
    });

    async function rpc(payload) {
      const execution = executionContext.getStore();
      if (!execution?.active) throw new Error("This JavaScript execution has ended");
      await connected;
      if (!execution.active) throw new Error("This JavaScript execution has ended");
      const id = nextID++;
      const result = new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        socket.write(JSON.stringify({ id, ...payload }) + "\n", error => {
          if (!error) return;
          pending.delete(id);
          reject(error);
        });
      });
      execution.pending.add(result);
      result.then(() => execution.pending.delete(result), () => execution.pending.delete(result));
      return await result;
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

    async function observe(deviceID, ax, screenshot, options) {
      const result = await rpc({deviceID, observation: {ax, screenshot, waitQuiescence: options.waitQuiescence !== false}});
      if (result.exitCode !== 0) {
        throw new IOSUseCommandError(decodeEnvelope(result.stdout) ?? decodeEnvelope(result.stderr), result.stderr);
      }
      return result;
    }

    async function interact(deviceID, interaction) {
      const result = await rpc({deviceID, interaction});
      if (result.exitCode !== 0) {
        throw new IOSUseCommandError(decodeEnvelope(result.stdout) ?? decodeEnvelope(result.stderr), result.stderr);
      }
    }

    function textValue(value) {
      return typeof value === "string" ? value.trim() : "";
    }

    function elementText(element) {
      return textValue(element.label) || textValue(element.value) || textValue(element.identifier);
    }

    function elementKey(element) {
      if (element.nodeID) return `node:${element.nodeID}`;
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
        element.enabled,
        element.visible,
        element.selected,
        element.focused,
        element.depth,
        element.parent_index,
        element.childCount,
      ]);
    }

    function projectElement(element, index) {
      const traits = Array.isArray(element.traits) ? element.traits : [];
      // XCTest DOM carries state in traits; its unused structured fields decode as false.
      const hasStructuredState = Boolean(textValue(element.semanticType));
      const projected = {
        ...element,
        element_index: index,
        role: textValue(element.semanticType) || textValue(element.type) || traits[0] || "Element",
        label: textValue(element.label),
        value: typeof element.value === "string" ? element.value : "",
        identifier: textValue(element.identifier),
        traits,
        frame: Array.isArray(element.frame) ? element.frame : null,
        enabled: hasStructuredState ? (element.state?.enabled ?? null) : !traits.includes("disabled"),
        selected: hasStructuredState ? (element.state?.selected ?? null) : traits.includes("selected"),
        focused: hasStructuredState ? (element.state?.focused ?? null) : traits.includes("focused"),
        visible: hasStructuredState ? (element.state?.visible ?? null) : !traits.includes("invisible"),
        depth: element.hierarchy?.depth ?? 0,
      };
      projected.state = {...element.state, enabled: projected.enabled, selected: projected.selected, focused: projected.focused, visible: projected.visible};
      return projected;
    }

    function projectElements(rawElements) {
      const stack = [];
      const elements = rawElements.map(projectElement);
      for (const element of elements) {
        while (stack.length && stack.at(-1).remaining === 0) stack.pop();
        const parent = stack.at(-1);
        element.depth = stack.length;
        element.parent_index = parent?.index ?? null;
        element.children = [];
        element.ancestor_indices = stack.map(entry => entry.index);
        if (parent) {
          elements[parent.index].children.push(element.element_index);
          parent.remaining--;
        }
        const count = element.childCount ?? 0;
        if (count > 0) stack.push({index: element.element_index, remaining: count});
      }
      return elements;
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

    function imageMimeType(bytes) {
      if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "image/png";
      if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
      if (Buffer.from(bytes.subarray(0,4)).toString() === "RIFF" && Buffer.from(bytes.subarray(8,12)).toString() === "WEBP") return "image/webp";
      throw new TypeError("emitImage requires PNG, JPEG, or WebP image bytes");
    }

    const nodeRepl = {
      write(value) {
        const text = typeof value === "string" ? value : inspect(value, {
          colors: false, depth: 8, maxArrayLength: 200, breakLength: 100,
        });
        emit({type: "text", text});
      },
      async emitImage(image) {
        let bytes = image?.bytes ?? image;
        let mimeType = image?.mimeType;
        if (typeof bytes === "string" && bytes.startsWith("file:")) {
          const response = await rpc({imagePath: fileURLToPath(bytes)});
          if (response.exitCode !== 0) throw new Error(response.stderr);
          bytes = Uint8Array.from(Buffer.from(response.imageBase64, "base64"));
        } else if (typeof bytes === "string") {
          const match = /^data:(image\/[a-z+.-]+);base64,([\s\S]*)$/i.exec(bytes);
          if (!match) throw new TypeError("emitImage expects image bytes or a data/file URL");
          mimeType = match[1];
          bytes = Uint8Array.from(Buffer.from(match[2], "base64"));
        }
        if (!ArrayBuffer.isView(bytes) || bytes.BYTES_PER_ELEMENT !== 1) {
          throw new TypeError("emitImage expects image bytes or {bytes, mimeType}");
        }
        bytes = new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const detected = imageMimeType(bytes);
        if (mimeType && mimeType !== detected) throw new TypeError("Image MIME type does not match its bytes");
        emit({type: "image", mimeType: detected, data: Buffer.from(bytes).toString("base64")});
      },
    };

    const executionConsole = Object.fromEntries(
      ["log", "info", "warn", "error", "debug", "dir"].map(method => [
        method, (...args) => nodeRepl.write(formatWithOptions({colors: false}, ...args)),
      ])
    );

    class DeviceHandle {
      #current = null;
      #previous = null;

      constructor(info) {
        Object.assign(this, info);
      }

      help() {
        nodeRepl.write([
          "await device.listApps({includeSystem: true}) // real iOS / Simulator",
          "await device.getApp(bundleId) // activate, reuse its ready AX, return this Device",
          "await device.terminateApp(bundleId)",
          "await device.start(); await device.stop() // configured iOS / Simulator Driver",
          "await device.getAXState() // fresh AX; waits for UI animations by default",
          "await device.getAXSnapshot() // full structured AX, no text/diff or automatic output",
          "await device.getScreenshot()",
          "await device.getAXStateAndScreenshot()",
          "await device.click(element_index|string|[x,y], {clickCount: 2}) // default: 1",
          "await device.setValue(element_index|string, value)",
          "await device.typeText(value)",
          "await device.selectText(element_index, text, {prefix, suffix, selectionType: \"text\"}) // also cursor_before / cursor_after",
          "await device.pressKey(\"super+a\") // xdotool-style keys; ctrl and super are distinct",
          "await device.paste(value) // plain text only",
          "await device.drag([fromX,fromY], [toX,toY])",
          "await device.longPress(element_index|string|[x,y], 0.5) // seconds",
          "await device.scroll(element_index|[x,y], \"down\", 0.5) // fraction of the scroll viewport",
          "await device.scrollTo(text, anchor)",
          "await device.waitFor(text, {gone: true, timeout: 20})",
          "await device.waitFor(ax => /* expected page condition */ false, {timeout: 10}) // structured AX; throws on timeout",
          "device.get() // complete latest AX objects with parent_index, children and ancestor_indices",
          "Unsupported: rich-text paste, secondary AX actions, secure-text replacement/selection. iOS clicks are touch-only; Mac supports single clicks and Return/Enter keys.",
        ].join("\n"));
      }

      async refresh() {
        const state = await cua.getState({ emit: false });
        const info = state.devices.find(device => device.id === this.id);
        if (!info) throw new Error(`Device ${this.id} is no longer known to ios-use`);
        Object.assign(this, info);
        return this;
      }

      async listApps(options = {}) {
        if (this.id === "mac") throw new Error("listApps supports real iOS and Simulator, not the Mac backend");
        const args = ["--udid", this.id];
        if (options.includeSystem) args.push("--system");
        const result = await runCLI(null, "apps", args);
        if (options.emit !== false) nodeRepl.write(result.apps);
        return result.apps;
      }

      async getApp(bundleId, options = {}) {
        if (typeof bundleId !== "string" || !bundleId) throw new TypeError("getApp requires an installed bundle ID from listApps");
        this.#current = null;
        this.#previous = null;
        const args = [bundleId, "--dom"];
        if (options.terminateExisting === true) args.push("--terminateExisting");
        const result = await runCLI(this.id, "activateApp", args);
        this.#setAX(result.readiness.dom);
        if (options.emit !== false) this.#formatAX(options);
        return this;
      }

      async terminateApp(bundleId) {
        if (typeof bundleId !== "string" || !bundleId) throw new TypeError("terminateApp requires an installed bundle ID");
        this.#current = null;
        this.#previous = null;
        return await runCLI(this.id, "terminateApp", [bundleId]);
      }

      async start(options = {}) {
        if (this.id === "mac") throw new Error("Use native ios-use start --mac --app <App.app> for Mac setup");
        this.#current = null;
        this.#previous = null;
        const state = await runCLI(null, "start", [this.id]);
        Object.assign(this, state.devices.find(device => device.id === this.id));
        if (options.observe !== false) await this.getAXState(options);
        return this;
      }

      async stop() {
        this.#current = null;
        this.#previous = null;
        const state = await runCLI(this.id, "stop");
        Object.assign(this, state.devices.find(device => device.id === this.id));
        return this;
      }

      async getAXState(options = {}) {
        this.#current = null;
        const result = await observe(this.id, true, false, options);
        return this.#applyAX(result.data.ax, options);
      }

      async getAXSnapshot(options = {}) {
        this.#current = null;
        const result = await observe(this.id, true, false, options);
        const snapshot = this.#setAX(result.data.ax);
        if (options.emit === true) nodeRepl.write(snapshot);
        return snapshot;
      }

      #setAX(data) {
        const elements = projectElements(data.elements ?? []);
        this.#current = {app: data.app, windowSize: data.windowSize, snapshotGeneration: data.snapshotGeneration, elements};
        return this.#current;
      }

      #applyAX(data, options) {
        this.#setAX(data);
        return this.#formatAX(options);
      }

      #formatAX(options) {
        if (options.disableDiffing === true) this.#previous = null;
        const {elements, app} = this.#current;
        const previousEntries = keyedElements(this.#previous?.elements ?? []);
        const currentEntries = keyedElements(elements);
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
          .map(entry => formatElement(entry.element, "-"));
        this.#previous = { elements };
        const header = `Device ${this.id} ${app ?? ""}`.trim();
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
        const response = await observe(this.id, false, true, options);
        const bytes = this.#imageBytes(response);
        if (options.emit !== false) await nodeRepl.emitImage(bytes);
        return bytes;
      }

      async getAXStateAndScreenshot(options = {}) {
        this.#current = null;
        const response = await observe(this.id, true, true, options);
        const state = this.#applyAX(response.data.ax, {...options, emit: false});
        const screenshot = this.#imageBytes(response);
        if (options.emit !== false) {
          nodeRepl.write(state);
          await nodeRepl.emitImage(screenshot);
        }
        return { state, screenshot };
      }

      #imageBytes(response) {
        if (!response.imageBase64) throw new Error("ios-use screenshot bytes unavailable");
        const bytes = Uint8Array.from(Buffer.from(response.imageBase64, "base64"));
        Object.assign(bytes, response.data.screenshot);
        return bytes;
      }

      async click(target, options = {}) {
        const button = options.mouseButton ?? "left";
        const count = options.clickCount ?? 1;
        if (!["left", "l"].includes(button)) throw new TypeError("iOS touch targets support left clicks only; use longPress for a context menu");
        if (!Number.isInteger(count) || count < 1 || count > 10) throw new TypeError("clickCount must be an integer from 1 to 10");
        const resolved = this.#resolveTarget(target);
        try {
          return await interact(this.id, {name: "click", target: resolved.interactionTarget, clickCount: count});
        } finally {
          this.#current = null;
        }
      }

      async setValue(target, value) {
        if (typeof value !== "string") throw new TypeError("setValue requires a text string");
        if (typeof target === "string") {
          if (!this.#current) await this.getAXState({emit: false});
          const matches = this.#current.elements.filter(element => [element.label, element.value, element.identifier].includes(target));
          if (matches.length !== 1) throw new Error("setValue requires one observed editable target; select its element_index");
          target = matches[0].element_index;
        }
        const resolved = this.#resolveTarget(target);
        try {
          return await interact(this.id, {name: "replace", target: resolved.interactionTarget, text: value});
        } finally {
          this.#current = null;
        }
      }

      async typeText(value) {
        if (typeof value !== "string") throw new TypeError("typeText requires a text string");
        try {
          return await interact(this.id, {name: "type", text: value});
        } finally {
          this.#current = null;
        }
      }

      async paste(value, options = {}) {
        if (options.format && options.format !== "text") throw new TypeError("ios-use paste supports plain text only");
        return await this.typeText(value);
      }

      async performSecondaryAction(target, action) {
        this.#resolveTarget(target);
        throw new Error("ios-use does not yet expose secondary accessibility actions; observe and use the visible control or longPress context menu");
      }

      async waitFor(text, options = {}) {
        if (typeof text === "function") {
          const timeout = options.timeout ?? 10;
          if (!Number.isFinite(timeout) || timeout <= 0) throw new TypeError("waitFor timeout must be positive seconds");
          const deadline = Date.now() + timeout * 1000;
          do {
            const snapshot = await this.getAXSnapshot({waitQuiescence: options.waitQuiescence});
            if (await text(snapshot)) {
              if (options.emit === true) this.#formatAX(options);
              return snapshot;
            }
          } while (Date.now() < deadline);
          throw new Error(`AX condition not met within ${timeout}s; inspect device.get() for the last observed state`);
        }
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
        if (typeof key !== "string" || !key) throw new TypeError("pressKey requires a key or modifier+key string");
        try {
          return await interact(this.id, {name: "key", text: key});
        } finally {
          this.#current = null;
        }
      }

      async selectText(target, text, options = {}) {
        if (typeof text !== "string" || !text) throw new TypeError("selectText requires non-empty text");
        const selectionType = options.selectionType ?? "text";
        if (!["text", "cursor_before", "cursor_after"].includes(selectionType)) throw new TypeError("Unknown selectionType");
        if ((options.prefix !== undefined && typeof options.prefix !== "string") || (options.suffix !== undefined && typeof options.suffix !== "string")) throw new TypeError("prefix and suffix must be strings");
        const resolved = this.#resolveTarget(target);
        try {
          await interact(this.id, {name: "select", target: resolved.interactionTarget, text, prefix: options.prefix, suffix: options.suffix, selectionType});
        } finally { this.#current = null; }
      }

      async drag(from, to) {
        if (!Array.isArray(from) || !Array.isArray(to)) throw new TypeError("drag requires observed [x,y] points");
        const start = this.#resolveTarget(from);
        const end = this.#resolveTarget(to);
        if (start.element || end.element) throw new TypeError("drag requires observed [x,y] points");
        try { return await runCLI(this.id, "swipe", ["--from", start.target, "--to", end.target]); }
        finally { this.#current = null; }
      }

      async longPress(target, duration = 0.5) {
        if (!Number.isFinite(duration) || duration <= 0) throw new TypeError("longPress duration must be positive seconds");
        const resolved = this.#resolveTarget(target);
        try { return await runCLI(this.id, "longpress", [resolved.target, "--duration", `${Math.round(duration * 1000)}ms`]); }
        finally { this.#current = null; }
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
          if (text && exactMatches === 1 && element.enabled !== false) return { target: text, interactionTarget: {label: text}, element };
          if (Array.isArray(element.frame) && element.frame.length === 4) {
            const [x, y, width, height] = element.frame.map(Number);
            return { target: `${x + width / 2},${y + height / 2}`, interactionTarget: {point: [x + width / 2, y + height / 2]}, element };
          }
          throw new Error(`element_index ${target} has no usable target`);
        }
        if (typeof target === "string" && target.length > 0) return { target, interactionTarget: {label: target}, element: null };
        const point = Array.isArray(target) ? target : target && typeof target === "object" ? [target.x, target.y] : null;
        if (point?.length === 2 && point.every(Number.isFinite)) {
          return { target: `${Number(point[0])},${Number(point[1])}`, interactionTarget: {point: point.map(Number)}, element: null };
        }
        throw new TypeError("target must be an element_index, semantic text, or [x, y]");
      }

      toJSON() {
        return { id: this.id, kind: this.kind, name: this.name, version: this.version, connected: this.connected, configured: this.configured, driver: this.driver };
      }
    }

    class CUARoot {
      #state = null;
      #devices = new Map();

      help() {
        nodeRepl.write([
          "await cua.getState()",
          "let device = await cua.getDevice(\"device-id\")",
          "let idle = await cua.getDevice(\"device-id\", {observe:false}); await idle.start()",
          "await device.listApps(); await device.getApp(\"bundle.id\")",
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
        const device = this.#devices.get(deviceId) ?? new DeviceHandle(info);
        this.#devices.set(deviceId, device);
        if (options.emit !== false) device.help();
        if (options.observe !== false) await device.getAXState(options);
        return device;
      }
    }

    const cua = new CUARoot();

    function installContext(server) {
      server.context.cua = cua;
      server.context.nodeRepl = nodeRepl;
      server.context.console = executionConsole;
      server.context.setTimeout = setTimeout;
      server.context.clearTimeout = clearTimeout;
      for (const name of ["process", "require", "module", "Buffer", "fetch", "WebSocket"]) {
        Object.defineProperty(server.context, name, {value: undefined, configurable: false});
      }
    }

    const input = new PassThrough();
    const output = new PassThrough();
    const server = repl.start({input, output, prompt: "", terminal: false, useGlobal: false, ignoreUndefined: true});
    installContext(server);
    output.on("data", chunk => {
      const execution = executionContext.getStore();
      const message = chunk.toString("utf8").trim();
      if (execution?.active && message) execution.reject?.(new Error(message));
    });

    async function execute(code) {
      const execution = {active: true, pending: new Set(), reject: null};
      return await executionContext.run(execution, async () => {
        let isError = false;
        try {
          await connected;
          await new Promise((resolve, reject) => {
            execution.reject = reject;
            server.eval(code, server.context, "<ios-use-mcp>", (error, value) => {
              if (error) reject(error);
              else Promise.resolve(value).then(resolve, reject);
            });
          });
          while (execution.pending.size) await Promise.allSettled([...execution.pending]);
        } catch (error) {
          isError = true;
          nodeRepl.write(error?.stack ?? String(error));
          if (error instanceof IOSUseCommandError) nodeRepl.write({
            category: error.category, retryable: error.retryable,
            mutationMayHaveApplied: error.mutationMayHaveApplied, interaction: error.interaction,
          });
          while (execution.pending.size) await Promise.allSettled([...execution.pending]);
        } finally {
          execution.active = false;
          execution.reject = null;
        }
        process.stdout.write(JSON.stringify({event: "complete", isError}) + "\n");
      });
    }

    registerHooks({
      resolve(specifier) { throw new Error(`Module imports are unavailable in ios-use mcp: ${specifier}`); },
    });
    process.getBuiltinModule = undefined;
    const requests = createInterface({input: process.stdin, crlfDelay: Infinity});
    for await (const line of requests) {
      if (!line.trim()) continue;
      const request = JSON.parse(line);
      await execute(request.code);
    }
    server.close();
    input.destroy();
    output.destroy();
    socket.end();
    """#
}
