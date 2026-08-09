# Third-party source and license manifest

Release packaging audits every imported entry against its detached pinned
checkout. The exact GitHub release tag carries the project and vendored
licenses. The statically linked Frida closure additionally ships one generated
notice containing its exact upstream license material inside the Engine
framework.

| Component | Pinned commit | License | Repository record |
| --- | --- | --- | --- |
| PlayCover | `7190cc9ce57c8dee0e222918468f2579acc95e1b` | GPL-3.0 — `ThirdParty/PlayCover/LICENSE` | `ThirdParty/PlayCover/PROVENANCE.md` |
| PlayTools | `d688f695e83bf080be9ad4b7346e914c7c343d96` | AGPL-3.0 — `playcover-runtime/PlayTools/LICENSE` | `playcover-runtime/PlayTools/PROVENANCE.md` |
| inject | `e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb` | GPL-3.0 — `ThirdParty/inject/LICENSE` | `ThirdParty/inject/PROVENANCE.md` |
| Frida GumJS static closure | See `ThirdParty/Frida/PROVENANCE.md` | wxWindows/LGPL/MIT/BSD/Public Domain — generated as `IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt` | `ThirdParty/Frida/PROVENANCE.md` |

The exact ios-use tag contains vendored PlayCover, PlayTools, and inject source.
The release build creates the Frida Engine only after fetching and validating
the exact public commits named in `ThirdParty/Frida/PROVENANCE.md`; those
temporary build checkouts are not release assets.
