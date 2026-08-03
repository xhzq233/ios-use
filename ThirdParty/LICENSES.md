# Third-party source and license manifest

Release packaging audits every entry against its detached pinned checkout and
includes all listed provenance records in the release provenance asset.
Standalone dependencies ship an individual license asset. The statically
linked Frida closure instead ships one generated notice containing its exact
upstream license material, both inside the Engine framework and as a top-level
release asset.

| Component | Pinned commit | License | Repository record |
| --- | --- | --- | --- |
| PlayCover | `7190cc9ce57c8dee0e222918468f2579acc95e1b` | GPL-3.0 — `ThirdParty/PlayCover/LICENSE` | `ThirdParty/PlayCover/PROVENANCE.md` |
| PlayTools | `d688f695e83bf080be9ad4b7346e914c7c343d96` | AGPL-3.0 — `playcover-runtime/PlayTools/LICENSE` | `playcover-runtime/PlayTools/PROVENANCE.md` |
| inject | `e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb` | GPL-3.0 — `ThirdParty/inject/LICENSE` | `ThirdParty/inject/PROVENANCE.md` |
| Yams | `3036ba9d69cf1fd04d433527bc339dc0dc75433d` | MIT — `ThirdParty/Yams/LICENSE` | `ThirdParty/Yams/PROVENANCE.md` |
| Frida GumJS static closure | See `ThirdParty/Frida/PROVENANCE.md` | wxWindows/LGPL/MIT/BSD/Public Domain — generated as `IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt` | `ThirdParty/Frida/PROVENANCE.md` |

The ios-use source archive already contains vendored PlayCover, PlayTools, and
inject source. It additionally embeds the complete pinned Yams tree under
`ThirdParty/Yams/upstream-source/`, because Yams remains a remote SwiftPM build
dependency rather than a vendored package in the working repository.

The release build creates the Frida Engine from the exact source closure named
in `ThirdParty/Frida/PROVENANCE.md`. The corresponding-source archive embeds
those complete Git trees under `ThirdParty/Frida/upstream-source/`; no second
checkout or cache is part of the release artifact.
