# Yams upstream provenance

- Upstream: https://github.com/jpsim/Yams.git
- Pinned commit: `3036ba9d69cf1fd04d433527bc339dc0dc75433d`
- Pinned version: `5.1.3`
- License: MIT; see `LICENSE`
- Local source patches: none.
- Corresponding source: each release's
  `ios-use-v<version>-corresponding-source.tar.gz` includes the complete pinned
  Git tree under `ThirdParty/Yams/upstream-source/`, together with this exact
  license and provenance record.

Yams is used by the pinned PlayCover entitlement implementation. The exact
version is declared in `ThirdParty/PlayCover/Package.swift`; its immutable
revision, remote, and version must agree in both
`ThirdParty/PlayCover/Package.resolved` and `swift-cli/Package.resolved`.
`scripts/audit_playcover_upstreams.sh` verifies all four declarations against
this record, checks this license byte-for-byte against the pinned checkout,
and release packaging obtains source only from that audited detached checkout.
