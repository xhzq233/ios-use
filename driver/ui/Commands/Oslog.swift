import Foundation
import OSLog
import Fory

// MARK: - Oslog command (doc 6.4)

enum OslogCommands {
    private static let pollIntervalMs = 300

    private static var buffer: [String] = []
    private static let bufferLock = NSLock()
    private static var lastRefreshAt: Date?

    static func oslog(_ args: ForyOslogArgs?, fory: Fory) throws -> ForyResponseFrame {
        let bundleId = args?.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBundleId = (bundleId?.isEmpty == false) ? bundleId : nil

        // clear=true: reset the buffer and exit early.
        if args?.clear == true {
            bufferLock.lock()
            let n = buffer.count
            buffer.removeAll()
            lastRefreshAt = nil
            bufferLock.unlock()
            let payload = ForyOslogPayload(matched: 0, total: 0, content: "", cleared: Int32(n))
            return try Codec.foryOK(payload, fory: fory)
        }

        guard #available(iOS 15.0, *) else {
            return Codec.foryError("oslog requires iOS 15.0+")
        }

        let matcher: ((String) -> Bool)?
        do {
            matcher = try makeMatcher(pattern: args?.pattern.isEmpty == true ? nil : args?.pattern, flags: args?.flags.isEmpty == true ? nil : args?.flags)
        } catch {
            return Codec.foryError("invalid regex: \(error.localizedDescription)")
        }

        let timeoutSec = max(args?.timeout ?? 0, 0)
        let deadline = Date().addingTimeInterval(timeoutSec)
        var snapshot: [String] = []
        var matchedLines: [String] = []
        repeat {
            refreshBuffer(bundleId: targetBundleId)
            snapshot = bufferLock.withLock { buffer }
            matchedLines = filterLines(snapshot, matcher: matcher)
            if timeoutSec <= 0 || matchedLines.count > 0 || Date() >= deadline {
                break
            }
            usleep(UInt32(Self.pollIntervalMs * 1000))
        } while true

        let total = snapshot.count
        let payload = ForyOslogPayload(
            matched: Int32(matchedLines.count),
            total: Int32(total),
            content: matchedLines.joined(separator: "\n") + "\n",
            cleared: 0
        )
        return try Codec.foryOK(payload, fory: fory)
    }

    // MARK: - OSLogStore ingestion

    @available(iOS 15.0, *)
    private static func refreshBuffer(bundleId: String?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let startDate = bufferLock.withLock {
                lastRefreshAt ?? Date().addingTimeInterval(-60)
            }
            let position = store.position(date: startDate)
            let entries = try store.getEntries(at: position)
            var appended: [String] = []
            var newestDate = startDate
            for entry in entries {
                if let logEntry = entry as? OSLogEntryLog {
                    newestDate = max(newestDate, logEntry.date)
                    if matchesActiveBundle(logEntry, bundleId: bundleId) {
                        appended.append(logEntry.composedMessage)
                    }
                } else {
                    newestDate = max(newestDate, entry.date)
                    if bundleId == nil {
                        appended.append(entry.composedMessage)
                    }
                }
                if appended.count >= 500 { break }
            }
            bufferLock.lock()
            if !appended.isEmpty {
                buffer.append(contentsOf: appended)
                if buffer.count > 5000 {
                    buffer.removeFirst(buffer.count - 5000)
                }
            }
            lastRefreshAt = newestDate.addingTimeInterval(0.001)
            bufferLock.unlock()
        } catch {
            NSLog("[oslog] refreshBuffer failed: \(error)")
        }
    }

    @available(iOS 15.0, *)
    private static func matchesActiveBundle(_ entry: OSLogEntryLog, bundleId: String?) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return true }
        if entry.subsystem == bundleId { return true }
        if entry.category == bundleId { return true }
        if entry.process == bundleId { return true }
        if entry.composedMessage.contains(bundleId) { return true }
        return entry.subsystem.isEmpty && entry.category.isEmpty && entry.process.isEmpty
    }
}

func makeMatcher(pattern: String?, flags: String?) throws -> ((String) -> Bool)? {
    guard let pattern, !pattern.isEmpty else { return nil }

    var options: NSRegularExpression.Options = []
    if let flags {
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
    }
    let regex = try NSRegularExpression(pattern: pattern, options: options)
    return { line in
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }
}

func filterLines(_ lines: [String], matcher: ((String) -> Bool)?) -> [String] {
    guard let matcher else { return lines }
    return lines.filter(matcher)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
