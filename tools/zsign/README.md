# zsign (bundled signer)

iPASide signs IPAs with [`zsign`](https://github.com/zhlynn/zsign), the
cross-platform `codesign` alternative. Because zsign handles the user's Apple
signing certificate, iPASide builds it **from source** (auditable, reproducible)
rather than shipping an opaque prebuilt binary.

## Building

Requires [MSYS2](https://www.msys2.org/) (`winget install MSYS2.MSYS2`). From an
MSYS2 shell at the repo root:

```bash
bash tools/zsign/build-zsign.sh
```

This installs the MinGW-w64 toolchain (with prebuilt OpenSSL/zlib/minizip),
clones zsign, applies a one-line MinGW compatibility patch, and produces a
statically-linked `zsign.exe` at
`src/iPASide.Engine/ipaside_engine/vendor/zsign.exe` (git-ignored).

The resulting binary emits a **SHA256-only CodeDirectory with canonical DER
entitlements** by default, which modern iOS requires.

## Runtime resolution

At sign time the engine locates zsign in this order:

1. the `IPASIDE_ZSIGN` environment variable,
2. the bundled `vendor/zsign.exe`,
3. `zsign` on `PATH`.
