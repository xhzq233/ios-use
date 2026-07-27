import Dispatch
import Foundation
import PlayCoverUpstream

struct PlayCoverPreparedArtifact: Sendable {
    let manifest: PlayCoverPrepareManifest
    let phaseTimings: PlayCoverUpstreamPreparePhaseTimings?
    let upstreamResult: PlayCoverUpstreamPrepareResult?
}

struct PlayCoverLaunchPhaseTiming: Equatable, Sendable {
    var aliasNanoseconds: UInt64?
    var openDispatchNanoseconds: UInt64?
    // Gross wall time from open dispatch return through the exact launch
    // claim. Runtime transport/ping is an observed nested subtotal, not an
    // additional duration that can be added to exact ownership.
    var exactOwnershipNanoseconds: UInt64?
    var runtimeTransportPingNanoseconds: UInt64?
    var readyGeometryNanoseconds: UInt64?

    static let empty = PlayCoverLaunchPhaseTiming(
        aliasNanoseconds: nil,
        openDispatchNanoseconds: nil,
        exactOwnershipNanoseconds: nil,
        runtimeTransportPingNanoseconds: nil,
        readyGeometryNanoseconds: nil
    )
}

struct PlayCoverStartTiming: Equatable, Sendable {
    var inspectNanoseconds: UInt64
    var cloneNanoseconds: UInt64?
    var convertNanoseconds: UInt64?
    var signNanoseconds: UInt64?
    var verifyNanoseconds: UInt64
    var launchNanoseconds: UInt64
    var launchPhaseTiming: PlayCoverLaunchPhaseTiming = .empty
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
            "alias="
                + formatLaunchPhase(
                    launchPhaseTiming.aliasNanoseconds
                ),
            "openDispatch="
                + formatLaunchPhase(
                    launchPhaseTiming.openDispatchNanoseconds
                ),
            "exactOwnership="
                + formatLaunchPhase(
                    launchPhaseTiming.exactOwnershipNanoseconds
                ),
            "runtimeTransportPing="
                + formatLaunchPhase(
                    launchPhaseTiming.runtimeTransportPingNanoseconds
                ),
            "readyGeometry="
                + formatLaunchPhase(
                    launchPhaseTiming.readyGeometryNanoseconds
                ),
            "total=\(format(totalNanoseconds))",
        ].joined(separator: " ")
    }

    mutating func addVerify(_ nanoseconds: UInt64) {
        verifyNanoseconds = adding(
            verifyNanoseconds,
            nanoseconds
        )
    }

    private func formatLaunchPhase(
        _ nanoseconds: UInt64?
    ) -> String {
        guard let nanoseconds else { return "skipped" }
        return String(
            format: "%.3fms",
            Double(nanoseconds) / 1_000_000
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
