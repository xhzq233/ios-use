# Frida GumJS static closure provenance

`IOSUseFridaEngine.framework` links the official Frida GumJS devkit produced
from the pinned Frida forks below. Release builds verify these exact Git
commits, verify the final Engine's static-symbol closure, generate the bundled
third-party notice from the listed source files, and place the full source
trees in `ios-use-v<version>-corresponding-source.tar.gz`.

- Pinned Frida version: `16.5.6`

| Component | Pinned commit | License | Path under `ThirdParty/Frida/upstream-source/` |
| --- | --- | --- | --- |
| Frida Gum | `0afeb85fcdeae1d995a55bc07f0fe57b197aecae` | wxWindows Library Licence 3.1 and bundled BSD notices | `frida-gum` |
| Frida releng (build source only) | `4622f5c4c432d94c1c625e598b120425a68a8414` | Source-only build tooling; see the upstream tree | `frida-gum/releng` |
| QuickJS | `12de2e4904b63405052508c891b215d056962c18` | MIT | `frida-gum/subprojects/quickjs` |
| GLib and proxy-libintl-static | `148f677c620b57893e3fcdb872d241b61870ef0d` | LGPL-2.1-or-later plus the licenses recorded by GLib; proxy-libintl-static is LGPL-2.0 | `frida-gum/subprojects/glib` |
| libffi | `10bcbcc6295e559b7c952b054e7669a912d3ce06` | MIT | `frida-gum/subprojects/libffi` |
| Capstone | `e98746112da0a40b2ccd0340db0d20cca5f97950` | BSD-3-Clause and LLVM University of Illinois/NCSA | `frida-gum/subprojects/capstone` |
| JSON-GLib | `1f40dc373415b728efa8315af7f975bd5a4e2490` | LGPL-2.1-or-later | `frida-gum/subprojects/json-glib` |
| TinyCC | `722c253d8dece3bc9a46b6f510c6682329d838b7` | LGPL-2.1-or-later | `frida-gum/subprojects/tinycc` |
| SQLite | `9337327a50008f2d2236112ccb6f44059b1bafbd` | Public domain | `frida-gum/subprojects/sqlite` |
| PCRE2 | `b47486922fdc3486499b310dc9cf903449700474` | BSD-3-Clause | `frida-gum/subprojects/pcre2` |

The Engine dynamically links only Apple system frameworks and libraries such
as Foundation, CoreFoundation, Security, SystemConfiguration, libSystem,
libz, libiconv, and libresolv. They are not copied into the release.

The build uses QuickJS and does not link V8. Its GumJS devkit does not contain
libsoup, nghttp2, or libpsl; the release gate rejects those symbols until their
source and notices are explicitly reviewed.

The generated notice is distributed both inside
`IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt` and as the
top-level release asset `FRIDA-STATIC-DEPENDENCY-NOTICES.txt`.
