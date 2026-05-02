import Foundation
import OSLog

// MARK: - Oslog command (doc 6.4)

enum OslogCommands {

    /// Cumulative log buffer. Populated on each oslog call from OSLogStore and
    /// preserved across calls so a subsequent `clear` can report how many
    /// entries were wiped.
    private static var buffer: [String] = []
    private static let bufferLock = NSLock()
    private static var lastRefreshAt: Date?

    /// doc 6.4 — oslog command.
    /// args.clear: true → clear buffer, return {cleared: N}
    /// args.pattern nil → write whole buffer to file, return {matched: total, total}
    /// args.pattern set → regex filter, write matches, return {matched, total, outputFile}
    static func oslog(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = decodeArgsOptional(rawArgs, as: OslogArgs.self)
        let bundleId = args?.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetBundleId = (bundleId?.isEmpty == false) ? bundleId : nil

        // clear=true: reset the buffer and exit early (doc 6.4).
        if args?.clear == true {
            bufferLock.lock()
            let n = buffer.count
            buffer.removeAll()
            lastRefreshAt = nil
            bufferLock.unlock()
            return Codec.makeOK(["cleared": n])
        }

        // Refresh buffer from OSLogStore.
        if #available(iOS 15.0, *) {
            refreshBuffer(bundleId: targetBundleId)
        } else {
            return Codec.makeError("oslog requires iOS 15.0+")
        }

        bufferLock.lock()
        let snapshot = buffer
        bufferLock.unlock()
        let total = snapshot.count

        // Determine matches.
        let matchedLines: [String]
        if let pattern = args?.pattern, !pattern.isEmpty {
            var options: NSRegularExpression.Options = []
            if let flags = args?.flags {
                if flags.contains("i") { options.insert(.caseInsensitive) }
                if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
                if flags.contains("m") { options.insert(.anchorsMatchLines) }
            }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                return Codec.makeError("invalid regex: \(error.localizedDescription)")
            }
            matchedLines = snapshot.filter { line in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return regex.firstMatch(in: line, options: [], range: range) != nil
            }
        } else {
            matchedLines = snapshot
        }

        return Codec.makeOK([
            "matched": matchedLines.count,
            "total": total,
            "content": matchedLines.joined(separator: "\n") + "\n",
        ])
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
            // Leave buffer unchanged on failure.
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
        // If the current store scope does not expose app-identifying metadata,
        // do not drop the line silently; keep it in the cumulative buffer.
        return entry.subsystem.isEmpty && entry.category.isEmpty && entry.process.isEmpty
    }

}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
