import Dispatch
import Foundation
import PlayCoverUpstream

struct PlayCoverPreparedArtifact: Sendable {
    let manifest: PlayCoverPrepareManifest
    let phaseTimings: PlayCoverUpstreamPreparePhaseTimings?
    let upstreamResult: PlayCoverUpstreamPrepareResult?
}

struct PlayCoverStartTiming: Equatable, Sendable {
    var inspectNanoseconds: UInt64
    var cloneNanoseconds: UInt64?
    var convertNanoseconds: UInt64?
    var signNanoseconds: UInt64?
    var verifyNanoseconds: UInt64
    var launchNanoseconds: UInt64
    var totalNanoseconds: UInt64

    static let empty = PlayCoverStartTiming(
        inspectNanoseconds: 0,
        cloneNanoseconds: nil,
        convertNanoseconds: nil,
        signNanoseconds: nil,
        verifyNanoseconds: 0,
        launchNanoseconds: 0,
        totalNanoseconds: 0
    )

    var outputLine: String {
        [
            "inspect=\(format(inspectNanoseconds))",
            "clone=\(format(cloneNanoseconds))",
            "convert=\(format(convertNanoseconds))",
            "sign=\(format(signNanoseconds))",
            "verify=\(format(verifyNanoseconds))",
            "launch=\(format(launchNanoseconds))",
            "total=\(format(totalNanoseconds))",
        ].joined(separator: " ")
    }

    mutating func addVerify(_ nanoseconds: UInt64) {
        verifyNanoseconds = adding(
            verifyNanoseconds,
            nanoseconds
        )
    }

    private func format(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds else { return "skipped" }
        return String(
            format: "%.1fms",
            Double(nanoseconds) / 1_000_000
        )
    }

    private func adding(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }
}

enum PlayCoverMonotonicClock {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsed(since start: UInt64) -> UInt64 {
        let end = now()
        return end >= start ? end - start : 0
    }
}
