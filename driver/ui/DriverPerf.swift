import Foundation

enum DriverPerf {
    static func append(_ message: String) {
        #if DEBUG_PERF
        NSLog(message)
        #endif
    }

    static func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
    }
}

@discardableResult
func withPerf<T>(_ tag: String = #function, stage: String? = nil, _ body: () -> T) -> T {
    #if DEBUG_PERF
    let startedAt = CFAbsoluteTimeGetCurrent()
    let value = body()
    let name = stage.map { "\(tag).\($0)" } ?? tag
    DriverPerf.append("[perf] \(name) elapsed=\(DriverPerf.elapsedMilliseconds(since: startedAt))ms")
    return value
    #else
    return body()
    #endif
}
