import SwiftUI
import UniformTypeIdentifiers
import SelfRunnerCore

@MainActor final class RunnerModel: ObservableObject {
    @Published var status = "Stopped"
    @Published var entries = [String]()
    @Published var script = """
    {"name":"Screen smoke","steps":[{"command":"dom"},{"command":"screenshot"}]}
    """
    @Published var host = "10.7.0.1"
    @Published var ready = false
    @Published var busy = false
    @Published var pairingImported = false
    @Published var embeddedVPN = false
    @Published var ddiDescription = RunnerDDIStore.description
    @Published var lastImage: UIImage?
    let hasEmbeddedVPN = Bundle.main.builtInPlugInsURL.map {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("IOSUseLoopback.appex").path)
    } ?? false
    private let queue = DispatchQueue(label: "ios-use.self-runner.session", qos: .userInitiated)
    private let session = SelfRunnerSession()
    private let vpn = LoopbackVPN()
    private let background = BackgroundSession()
    private var cancellation = ScriptCancellation()
    private var didHandleLaunch = false
    private var runAfterStart = false
    private var scheduledStart: Task<Void, Never>?
    private let pairingURL = URL.applicationSupportDirectory.appendingPathComponent("pairing.plist")
    init() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        pairingImported = FileManager.default.fileExists(atPath: pairingURL.path)
        let legacy = URL.documentsDirectory.appendingPathComponent("pairing.plist")
        if !pairingImported, FileManager.default.fileExists(atPath: legacy.path) {
            importFile(legacy, pairing: true)
            if pairingImported { try? FileManager.default.removeItem(at: legacy) }
        }
        session.log = { [weak self] line in Task { @MainActor in self?.append(line) } }
    }
    func append(_ line: String) {
        entries.append(line)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        NSLog("[session] %@", line)
        let url = URL.documentsDirectory.appendingPathComponent("session.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        } else { try? data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication) }
    }
    func importFile(_ url: URL, pairing: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if pairing {
                _ = try PairRecord.decode(data)
                try data.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var protected = pairingURL
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protected.setResourceValues(values)
                pairingImported = true; append("Pairing record imported")
            } else {
                _ = try Script.parse(data)
                script = String(decoding: data, as: UTF8.self)
                append("Script imported")
            }
        } catch { append("Import failed: \(error)") }
    }
    func importDDI(_ url: URL) {
        guard !busy, !ready else { return }
        busy = true; status = "Importing DDI"
        queue.async {
            do {
                try RunnerDDIStore.importFolder(url)
                Task { @MainActor in
                    self.ddiDescription = RunnerDDIStore.description
                    self.append("DDI image imported; it will be mounted when automation starts")
                    self.busy = false; self.status = "Stopped"
                }
            } catch {
                Task { @MainActor in self.append("DDI import failed: \(error)"); self.busy = false; self.status = "Import failed" }
            }
        }
    }
    func forgetDDI() {
        do { try RunnerDDIStore.removeImport(); ddiDescription = RunnerDDIStore.description }
        catch { append("Could not remove DDI: \(error)") }
    }
    func forgetPairing() {
        do { try FileManager.default.removeItem(at: pairingURL); pairingImported = false }
        catch { append("Could not remove pairing record: \(error)") }
    }
    func handleLaunchArguments() {
        guard !didHandleLaunch else { return }
        didHandleLaunch = true
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--remove-local-configuration") {
            Task {
                do {
                    if hasEmbeddedVPN { try await vpn.removeConfiguration() }
                    if pairingImported { forgetPairing() }
                    try RunnerDDIStore.removeImport()
                    guard !pairingImported else { throw ScriptFailure("Could not remove the pairing record") }
                    append("Removed local VPN configuration, pairing record and imported DDI")
                } catch { append("Cleanup failed: \(error)") }
            }
            return
        }
        embeddedVPN = args.contains("--embedded-vpn")
        if embeddedVPN && !hasEmbeddedVPN {
            append("This build requires an external loopback VPN"); status = "Failed"; return
        }
        if args.contains("--run-script") {
            let url = URL.documentsDirectory.appendingPathComponent("script.json")
            do {
                let data = try Data(contentsOf: url); _ = try Script.parse(data)
                script = String(decoding: data, as: UTF8.self); runAfterStart = true
            } catch { append("Launch script invalid: \(error)"); return }
        }
        if args.contains("--start-automation") {
            // Lets a device test launch the app before removing an existing DDI;
            // launching through developer services itself may need that image.
            if let delayArg = args.first(where: { $0.hasPrefix("--start-delay-seconds=") }) {
                guard let seconds = UInt64(delayArg.dropFirst("--start-delay-seconds=".count)), (1...30).contains(seconds) else {
                    append("Start delay must be 1–30 seconds"); return
                }
                status = "Waiting to start"
                append("Starting automation in \(seconds) seconds")
                scheduledStart = Task {
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                    catch { return }
                    self.start()
                }
            } else { start() }
        }
    }
    func start() {
        guard !busy, !ready else { return }
        busy = true; status = "Starting"
        Task {
            do {
                if embeddedVPN { try await vpn.start() }
                let data = try Data(contentsOf: pairingURL)
                let address = host
                background.start()
                queue.async {
                    do {
                        try self.session.start(pairing: data, host: address)
                        Task { @MainActor in self.ready = true; self.busy = false; self.status = "Ready"; if self.runAfterStart { self.runAfterStart = false; self.run() } }
                    } catch {
                        Task { @MainActor in
                            self.append("Start failed: \(error)"); self.append(await self.vpn.diagnostics()); self.busy = false; self.status = "Failed"
                            self.background.stop(); self.vpn.stop()
                        }
                    }
                }
            } catch { append("Start failed: \(error)"); busy = false; status = "Failed"; vpn.stop() }
        }
    }
    func run() {
        guard ready, !busy else { return }
        do {
            let parsed = try Script.parse(Data(script.utf8))
            let token = ScriptCancellation(); cancellation = token
            busy = true; status = "Running \(parsed.name)"
            queue.async {
                do {
                    try ScriptExecutor.run(parsed, cancellation: token, execute: self.session.execute) { index, command, result in
                        Task { @MainActor in
                            switch result {
                            case .success(let payload):
                                self.append("\(index + 1). \(command): OK")
                                if let text = payload["text"] as? String {
                                    self.append(String(text.prefix(16000)))
                                    try? Data(text.utf8).write(to: URL.documentsDirectory.appendingPathComponent("last-dom.txt"), options: .atomic)
                                }
                                if let jpeg = payload["jpeg"] as? Data {
                                    self.lastImage = UIImage(data: jpeg)
                                    try? jpeg.write(to: URL.documentsDirectory.appendingPathComponent("last-screenshot.jpg"), options: .atomic)
                                }
                            case .failure(let error): self.append("\(index + 1). \(command): \(error)")
                            }
                        }
                    }
                    Task { @MainActor in self.busy = false; self.status = "Completed"; self.append("Script completed: \(parsed.name)") }
                } catch { Task { @MainActor in self.append("Script stopped: \(error)"); self.busy = false; self.status = "Stopped script" } }
            }
        } catch { append("Script invalid: \(error)") }
    }
    func stop() {
        scheduledStart?.cancel(); scheduledStart = nil; runAfterStart = false
        cancellation.cancel()
        queue.async {
            self.session.stop()
            Task { @MainActor in
                self.ready = false; self.busy = false; self.status = "Stopped"
                self.background.stop(); self.vpn.stop()
            }
        }
    }
}

@main struct RunnerApp: SwiftUI.App {
    @StateObject private var model = RunnerModel()
    @State private var picker = false
    @State private var importPairing = true
    @State private var ddiPicker = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Connection") {
                        Text(model.status).accessibilityIdentifier("runner.status")
                        TextField("Local device address", text: $model.host).autocorrectionDisabled().textInputAutocapitalization(.never)
                        if model.hasEmbeddedVPN {
                            Toggle("Use embedded local VPN", isOn: $model.embeddedVPN).disabled(model.busy || model.ready)
                        } else { Text("Connect an external loopback VPN before starting.").font(.caption) }
                        Text("Embedded VPN requires a Network Extensions signing profile. Otherwise enable an external loopback VPN first.").font(.caption)
                        Button(model.pairingImported ? "Replace pairing record" : "Import pairing record") { importPairing = true; picker = true }.disabled(model.ready || model.busy)
                        if model.pairingImported { Button("Forget pairing record", role: .destructive, action: model.forgetPairing).disabled(model.ready || model.busy) }
                        HStack {
                            Button("Start automation", action: model.start).disabled(model.busy || model.ready || !model.pairingImported)
                            Spacer()
                            Button("Stop session", action: model.stop)
                        }
                    }
                    Section("Developer image") {
                        Text(model.ddiDescription).font(.caption)
                        Text("Start automation checks the mounted image and mounts your DDI when needed. Personalization may require Internet access.").font(.caption)
                        Button("Import DDI folder") { ddiPicker = true }.disabled(model.ready || model.busy)
                        Button("Remove imported DDI", role: .destructive, action: model.forgetDDI).disabled(model.ready || model.busy)
                    }
                    Section("Script") {
                        TextEditor(text: $model.script).font(.system(.caption, design: .monospaced)).frame(minHeight: 200)
                        Button("Import JSON script") { importPairing = false; picker = true }
                        HStack {
                            Button("Run script", action: model.run).disabled(!model.ready || model.busy)
                            Spacer()
                            Button("Cancel script") { model.cancelScript() }
                        }
                    }
                    if let image = model.lastImage {
                        Section("Last screenshot") { Image(uiImage: image).resizable().scaledToFit() }
                    }
                    Section("Results") {
                        ForEach(Array(model.entries.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("ios-use Self Runner")
                .task { model.handleLaunchArguments() }
                .fileImporter(isPresented: $ddiPicker, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): model.importDDI(url)
                    case .failure(let error): model.append("DDI selection: \(error)")
                    }
                }
                .fileImporter(isPresented: $picker, allowedContentTypes: [.data, .json, .propertyList]) { result in
                    switch result {
                    case .success(let url): model.importFile(url, pairing: importPairing)
                    case .failure(let error): model.append("File selection: \(error)")
                    }
                }
            }
        }
    }
}
extension RunnerModel {
    func cancelScript() { cancellation.cancel() }
}
