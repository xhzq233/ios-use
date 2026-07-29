import PlayCoverUpstream

struct PlayCoverPreparedArtifact: Sendable {
    let manifest: PlayCoverPrepareManifest
    let upstreamResult: PlayCoverUpstreamPrepareResult?
}
