enum MCPJavaScriptSource {
    static let code = #"""
    (function(nativeCall, emitText, emitBytes, decodeBase64, scheduleTimer, cancelTimer, complete) {

    class IOSUseCommandError extends Error {
      constructor(envelope) {
        super(envelope.error.message);
        this.name = "IOSUseCommandError";
        this.command = envelope.command;
        this.code = envelope.error.code;
        this.category = envelope.error.category;
        this.retryable = envelope.error.retryable;
        this.mutationMayHaveApplied = envelope.error.mutationMayHaveApplied;
        this.data = envelope.data;
        this.interaction = envelope.interaction;
        this.warnings = envelope.warnings;
      }
    }

    async function callHost(name, deviceID, options = {}) {
      const result = await new Promise(resolve => nativeCall(name, deviceID, options, resolve));
      if (result.error) throw new IOSUseCommandError(result.error);
      return result;
    }

    async function deviceCall(deviceID, name, options = {}) {
      return (await callHost(name, deviceID, options)).data;
    }

    function observe(deviceID, ax, screenshot, options) {
      return callHost("observe", deviceID, {ax, screenshot, waitQuiescence: options.waitQuiescence !== false});
    }

    async function interact(deviceID, {name, ...options}) {
      await deviceCall(deviceID, name, options);
    }

    function inspect(value) {
      if (typeof value === "string") return value;
      const seen = new WeakSet();
      return JSON.stringify(value, (_, item) => {
        if (typeof item === "bigint") return String(item) + "n";
        if (typeof item === "object" && item !== null) {
          if (seen.has(item)) return "[Circular]";
          seen.add(item);
        }
        return item;
      }, 2) ?? String(value);
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
      if (label) return `label:${element.role}:${label}`;
      return [element.role, element.depth, element.parent_index]
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
        element.role,
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
        childCount: element.childCount ?? 0,
      };
      // Keep useful backend metadata, not empty protocol slots or duplicate state/tree fields.
      for (const key of ["nodeID", "hint", "class"]) {
        const value = textValue(element[key]);
        if (value) projected[key] = value;
      }
      if (hasStructuredState) {
        projected.opaque = element.state?.opaque ?? null;
        projected.zOrder = element.zOrder ?? 0;
      }
      if (element.snapshotGeneration > 0) projected.snapshotGeneration = element.snapshotGeneration;
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
      if (String.fromCharCode(...bytes.subarray(0,4)) === "RIFF" && String.fromCharCode(...bytes.subarray(8,12)) === "WEBP") return "image/webp";
      throw new TypeError("emitImage requires PNG, JPEG, or WebP image bytes");
    }

    const nodeRepl = {
      write(value) {
        emitText(inspect(value));
      },
      async emitImage(image) {
        let bytes = image?.bytes ?? image;
        let mimeType = image?.mimeType;
        if (typeof bytes === "string" && bytes.startsWith("file:")) {
          bytes = new Uint8Array((await callHost("readImage", null, {url: bytes})).image);
        } else if (typeof bytes === "string") {
          const match = /^data:(image\/[a-z+.-]+);base64,([\s\S]*)$/i.exec(bytes);
          if (!match) throw new TypeError("emitImage expects image bytes or a data/file URL");
          mimeType = match[1];
          bytes = new Uint8Array(decodeBase64(match[2]));
        }
        if (!ArrayBuffer.isView(bytes) || bytes.BYTES_PER_ELEMENT !== 1) {
          throw new TypeError("emitImage expects image bytes or {bytes, mimeType}");
        }
        bytes = new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const detected = imageMimeType(bytes);
        if (mimeType && mimeType !== detected) throw new TypeError("Image MIME type does not match its bytes");
        const buffer = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
          ? bytes.buffer : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        emitBytes(buffer, detected);
      },
    };

    const executionConsole = Object.fromEntries(
      ["log", "info", "warn", "error", "debug", "dir"].map(method => [
        method, (...args) => nodeRepl.write(args.map(inspect).join(" ")),
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
          "await device.activateApp(bundleId) // ready AX is available through device.get()",
          "await device.terminateApp(bundleId)",
          "await device.start(); await device.stop() // configured iOS / Simulator Driver",
          "await device.getAXState() // fresh AX; requests native quiescence, not page readiness",
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
          "device.get() // complete latest AX objects with parent_index, children and ancestor_indices",
          "For known flows, observe with {emit:false}, check the destination container via get(), and emit only task results. Stop on failed transitions; do not compare two AX texts for readiness.",
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
        const result = await deviceCall(this.id, "apps", {includeSystem: options.includeSystem === true});
        if (options.emit !== false) nodeRepl.write(result.apps);
        return result.apps;
      }

      async activateApp(bundleId, options = {}) {
        if (typeof bundleId !== "string" || !bundleId) throw new TypeError("activateApp requires an installed bundle ID from listApps");
        this.#current = null;
        this.#previous = null;
        const result = await deviceCall(this.id, "activateApp", {bundleId, terminateExisting: options.terminateExisting === true});
        this.#setAX(result.readiness.dom);
        if (options.emit !== false) this.#formatAX(options);
      }

      async terminateApp(bundleId) {
        if (typeof bundleId !== "string" || !bundleId) throw new TypeError("terminateApp requires an installed bundle ID");
        this.#current = null;
        this.#previous = null;
        return await deviceCall(this.id, "terminateApp", {bundleId});
      }

      async start(options = {}) {
        if (this.id === "mac") throw new Error("Use native ios-use start --mac --app <App.app> for Mac setup");
        this.#current = null;
        this.#previous = null;
        const state = await deviceCall(this.id, "start");
        Object.assign(this, state.devices.find(device => device.id === this.id));
        if (options.observe !== false) await this.getAXState(options);
        return this;
      }

      async stop() {
        this.#current = null;
        this.#previous = null;
        const state = await deviceCall(this.id, "stop");
        Object.assign(this, state.devices.find(device => device.id === this.id));
        return this;
      }

      async getAXState(options = {}) {
        this.#current = null;
        const result = await observe(this.id, true, false, options);
        return this.#applyAX(result.data.ax, options);
      }

      #setAX(data) {
        const elements = projectElements(data.elements ?? []);
        this.#current = {app: data.app, windowSize: data.windowSize, elements};
      }

      #applyAX(data, options) {
        this.#setAX(data);
        return this.#formatAX(options);
      }

      #formatAX(options) {
        const {elements, app} = this.#current;
        const previousEntries = keyedElements(options.disableDiffing === true ? [] : this.#previous?.elements ?? []);
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
        const header = `Device ${this.id} ${app ?? ""}`.trim();
        const changed = elements.flatMap((element, index) => markers[index] === " " ? [] : [formatElement(element, markers[index])]);
        const state = [header, ...removed, ...changed, ...(!removed.length && !changed.length ? ["No AX changes."] : [])]
          .filter(Boolean)
          .join("\n");
        if (options.emit !== false) this.#emitAX(state);
        return state;
      }

      #emitAX(state) {
        nodeRepl.write(state);
        this.#previous = {elements: this.#current.elements};
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
          this.#emitAX(state);
          await nodeRepl.emitImage(screenshot);
        }
        return { state, screenshot };
      }

      #imageBytes(response) {
        if (!response.image) throw new Error("ios-use screenshot bytes unavailable");
        const bytes = new Uint8Array(response.image);
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
        const timeout = options.timeout ?? 10;
        if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 300) throw new TypeError("waitFor timeout must be positive seconds, at most 300");
        await deviceCall(this.id, "waitFor", {text: String(text), timeout, gone: options.gone === true, match: options.match ?? "contains"});
        return await this.getAXState({emit: options.emit});
      }

      async scrollTo(text, anchor, options = {}) {
        const from = anchor === undefined ? null : this.#resolveTarget(anchor).interactionTarget;
        try { await deviceCall(this.id, "swipe", {to: {label: String(text)}, from}); }
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
        try { return await deviceCall(this.id, "swipe", {from: start.interactionTarget, to: end.interactionTarget}); }
        finally { this.#current = null; }
      }

      async longPress(target, duration = 0.5) {
        if (!Number.isFinite(duration) || duration <= 0) throw new TypeError("longPress duration must be positive seconds");
        const resolved = this.#resolveTarget(target);
        try { return await deviceCall(this.id, "longpress", {target: resolved.interactionTarget, duration}); }
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
            result = await deviceCall(this.id, "swipe", {from: {point: from}, to: {point: to}});
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
          "await device.listApps(); await device.activateApp(\"bundle.id\")",
          "await device.getAXState()",
          "await device.click(0)",
          "await device.getAXStateAndScreenshot()",
          "await Promise.all([deviceA.getAXState(), deviceB.getAXState()])",
          "Call device.help() for the current target API.",
        ].join("\n"));
      }

      async getState(options = {}) {
        this.#state = await deviceCall(null, "status");
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

    globalThis.cua = cua;
    globalThis.nodeRepl = nodeRepl;
    globalThis.console = executionConsole;
    globalThis.setTimeout = (callback, delay = 0, ...args) => {
      if (typeof callback !== "function") throw new TypeError("setTimeout requires a function");
      return scheduleTimer(() => callback(...args), Number(delay));
    };
    globalThis.clearTimeout = cancelTimer;

    function reportError(error) {
        nodeRepl.write(String(error) + (error?.stack ? "\n" + error.stack : ""));
        if (error instanceof IOSUseCommandError) nodeRepl.write({
          category: error.category, retryable: error.retryable,
          mutationMayHaveApplied: error.mutationMayHaveApplied, interaction: error.interaction,
        });
    }
    return {
      reportError,
      attach: promise => Promise.resolve(promise).then(result => result.value).then(
        () => complete(false),
        error => { reportError(error); complete(true); }
      ),
    };
    })
    """#
}
