# inject upstream provenance

- Upstream: https://github.com/paradiseduo/inject.git
- Pinned commit: `e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb`
- License: GPL-3.0; see `LICENSE`
- Imported source: `Injection/Injection/{BitType,Command,Extension,Inject,Shell}.swift`
- Corresponding source: the release asset named
  `ios-use-v<version>-corresponding-source.tar.gz` contains the five imported
  files, local package recipe, license, and this record.

## Expected vendored upstream files

<!-- audit-vendored-files:start -->
- `BitType.swift`
- `Command.swift`
- `Extension.swift`
- `Inject.swift`
- `Shell.swift`
<!-- audit-vendored-files:end -->

## Recorded local source patches

All five imported sources are byte-identical to the pinned checkout. The empty
allowlist is intentional; any source change fails the upstream audit until its
path and justification are recorded here.

<!-- audit-local-patches:start -->
<!-- audit-local-patches:end -->

The source files are unmodified.  The only package-level patch removes the
unrelated command-line executable and tests so ios-use links the upstream
`injection` library directly.  Runtime injection uses
`Inject.injectMachO`/`LoadCommand`; ios-use adds strict preflight validation
before invoking it and verifies the resulting load command afterwards.
