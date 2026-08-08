import PlayCoverUpstream

struct PlayCoverPreparedArtifact: Sendable {
    let preparedApp: PlayCoverPreparedApp
    let upstreamResult: PlayCoverUpstreamPrepareResult?
}
