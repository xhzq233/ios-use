# Frida GumJS static closure provenance

`IOSUseFridaEngine.framework` links the official Frida GumJS devkit produced
from the pinned Frida forks below. Release builds verify these exact Git
commits from their public repositories, verify the final Engine's static-symbol
closure, and generate the bundled third-party notice from the listed source
files. The build checkouts are temporary inputs, not release assets.

- Pinned Frida version: `16.5.6`

| Component | Public repository | Pinned commit | License |
| --- | --- | --- | --- |
| Frida Gum | https://github.com/frida/frida-gum.git | `0afeb85fcdeae1d995a55bc07f0fe57b197aecae` | wxWindows Library Licence 3.1 and bundled BSD notices |
| Frida releng (build source only) | https://github.com/frida/releng.git | `4622f5c4c432d94c1c625e598b120425a68a8414` | Source-only build tooling; see the upstream tree |
| QuickJS | https://github.com/frida/quickjs.git | `12de2e4904b63405052508c891b215d056962c18` | MIT |
| GLib and proxy-libintl-static | https://github.com/frida/glib.git | `148f677c620b57893e3fcdb872d241b61870ef0d` | LGPL-2.1-or-later plus the licenses recorded by GLib; proxy-libintl-static is LGPL-2.0 |
| libffi | https://github.com/frida/libffi.git | `10bcbcc6295e559b7c952b054e7669a912d3ce06` | MIT |
| Capstone | https://github.com/frida/capstone.git | `e98746112da0a40b2ccd0340db0d20cca5f97950` | BSD-3-Clause and LLVM University of Illinois/NCSA |
| JSON-GLib | https://github.com/frida/json-glib.git | `1f40dc373415b728efa8315af7f975bd5a4e2490` | LGPL-2.1-or-later |
| TinyCC | https://github.com/frida/tinycc.git | `722c253d8dece3bc9a46b6f510c6682329d838b7` | LGPL-2.1-or-later |
| SQLite | https://github.com/frida/sqlite.git | `9337327a50008f2d2236112ccb6f44059b1bafbd` | Public domain |
| PCRE2 | https://github.com/frida/pcre2.git | `b47486922fdc3486499b310dc9cf903449700474` | BSD-3-Clause |

The Engine dynamically links only Apple system frameworks and libraries such
as Foundation, CoreFoundation, Security, SystemConfiguration, libSystem,
libz, libiconv, and libresolv. They are not copied into the release.

The build uses QuickJS and does not link V8. Its GumJS devkit does not contain
libsoup, nghttp2, or libpsl; the release gate rejects those symbols until their
source and notices are explicitly reviewed.

The generated notice is distributed inside
`IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt`.
