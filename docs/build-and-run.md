# Build, package and run

Run commands from `D:\Codex\MasterDeskFork` in PowerShell. Read
[current-state.md](current-state.md) first and never reuse an already-issued
beta number.

## Toolchain

`scripts/Build-CustomWindows.ps1` pins the reproducible toolchain:

- Rust 1.75.0;
- Flutter 3.24.5;
- LLVM 15.0.6;
- flutter-rust-bridge 1.80.1;
- vcpkg commit `120deac3062162151622ca4860575a33844ba10b`;
- Visual Studio 2022 x64 C++ build tools, Git for Windows and Python 3.12.

The 32-bit Windows fallback uses the upstream Sciter path because Flutter
Windows has no i686 desktop runner. `scripts/Build-CustomWindowsX86.ps1` pins:

- Rust `nightly-2023-10-13-i686-pc-windows-msvc` (the Sciter x86 ABI needs
  nightly Rust 1.75);
- the same vcpkg commit with the `x86-windows-static` triplet in the separate
  `.tools\vcpkg-x86` checkout;
- rust-sciter `dyn_x86` commit
  `674e07d3066ca9a92ced3816203ab6b652629d1e`;
- Sciter x86 commit `f33df075d9eb2f8d252cb88f1b2c8096e56197ed`
  and its verified DLL SHA-256.

`scripts/Initialize-MasterDeskBuildEnvironment.ps1` resolves the existing
`.tools` caches and optional `MASTERDESK_LLVM_BIN`,
`MASTERDESK_VCPKG_ROOT`, `MASTERDESK_FLUTTER_ROOT`,
`MASTERDESK_PUB_CACHE` and `MASTERDESK_PYTHON` overrides. Preserve these
caches unless corruption has been proven.

## Fast gate

Run the standard focused Rust check/tests and keep verbose logs under
`artifacts\targeted-windows-client\<timestamp>`:

```powershell
.\scripts\Test-TargetedWindowsClient.ps1
```

For a single new test family, pass an exact filter instead of expanding the
whole gate:

```powershell
.\scripts\Test-TargetedWindowsClient.ps1 -Filter 'parallel_file_transfer_'
```

Useful separate checks are:

```powershell
.\scripts\Test-CustomDefaults.ps1
cargo check --features flutter
. .\scripts\Initialize-MasterDeskBuildEnvironment.ps1
Push-Location .\flutter
& (Join-Path $env:MASTERDESK_FLUTTER_ROOT 'bin\flutter.bat') `
    test .\test\file_transfer_telemetry_test.dart
Pop-Location
```

Run only those applicable to the changed path.

The defaults gate above retains client AND local server/API checks by default.
For the public client-only signing workflow, use
`scripts/Test-CustomDefaults.ps1 -ClientOnly`: all client source/Rust/portable
checks remain enabled; excluded deployment checks are reported as NOT_RUN,
not server PASS. Server/API checks are also available independently through
`scripts/Test-ServerDefaults.ps1`. `scripts/Test-DefaultsScope.ps1` verifies the
split and fail-closed fixtures without private deployment files.

## Cached incremental candidate

Preferred wrapper; it runs the targeted gate, chooses the next beta when
omitted, logs under `artifacts\incremental-beta\<timestamp>`, and packages from
the verified cached Windows runner:

```powershell
.\scripts\Build-IncrementalBeta.ps1 -BetaNumber <next-beta>
```

It detects dirty Flutter/bridge inputs and enables the cached AOT refresh. To
request that explicitly:

```powershell
.\scripts\Build-IncrementalBeta.ps1 -BetaNumber <next-beta> -RefreshFlutterAot
```

The lower-level Rust-only equivalent is:

```powershell
.\scripts\Build-CustomWindows.ps1 -SkipVcpkg -SkipFlutterSetup `
    -IncrementalRustOnly -BetaNumber <next-beta>
```

Use `-SkipTargetedTests` only when the exact current tree already passed the
same gate in the same task. A Rust-only build must not rebuild Flutter AOT.

## Full candidate

Use one full build only for a release/final candidate, a build-system/toolchain
change, proven cache incompatibility, or an explicit request:

```powershell
.\scripts\Build-CustomWindows.ps1 -BetaNumber <next-beta>
```

For native 32-bit Windows, including the Windows 7 compatibility candidate,
use the separate Sciter wrapper after provisioning its pinned x86 toolchain and
vcpkg checkout:

```powershell
.\scripts\Build-CustomWindowsX86.ps1 -BetaNumber <next-beta>
```

This is not a Flutter package. It builds `i686-pc-windows-msvc`, statically
links the native libraries, embeds the legacy Sciter UI, verifies the pinned
32-bit `sciter.dll`, and creates one portable self-extracting EXE. A successful
x86 build or WOW64 launch is not by itself a Windows 7 PASS; inspect the PE
imports and launch/connect on a real Windows 7 SP1 32-bit VM before publishing
Windows 7 support.

Do not run `cargo clean` or clear Flutter/vcpkg/Rust caches as a routine step.

The Flutter 3.24 backend can finish `app.so` and the generated asset bundle
while leaving an idle wrapper. The build script has a bounded watchdog: it waits
for stable AOT plus valid non-empty asset/font manifests, stops the exact wrapper
process tree and copies the validated generated assets into Release. Packaging
also rejects an empty/invalid `FontManifest.json`, `AssetManifest.bin` or missing
Material Icons registration. Do not clear caches if those outputs and stamps are
complete; continue the same beta as described by the script output.

## Identity and artifacts

Every changed package must be created by the build script as:

```text
dist\MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86_64.exe
dist\MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86-sciter.exe
```

`N` is a monotonically increasing positive integer. Filename, embedded
`<version> beta <N>`, build date `YYYY-MM-DD HH:mm`, About page, installed
registry metadata and GUI update comparison must agree. Never hand-rename an
EXE.

Important outputs:

- packaged EXE: `dist\`;
- x86 Sciter build evidence and unpacked payload:
  `artifacts\build\beta-<N>-x86-sciter-<YYYY-MM-DD>\`;
- unpacked runner: `flutter\build\windows\x64\runner\Release\`;
- Rust library: `...\Release\libmasterdesk.dll`;
- Flutter AOT: `...\Release\data\app.so`;
- consistency manifest:
  `...\Release\data\masterdesk-build-manifest.json`;
- build/test/lab evidence: `artifacts\`.

Record the EXE SHA-256 and, for incremental mixed Rust/Flutter work, the runner,
`libmasterdesk.dll`, `app.so` and relevant plugin DLL hashes.

## Portable, install, update and uninstall

- Launching a package with no arguments always opens it portably, even when an
  older MasterDesk is installed.
- On a clean PC, use the package's normal **Install** card. The installed path
  is normally `C:\Program Files\MasterDesk\MasterDesk.exe`; service and
  shortcuts are registered by the application.
- To update, launch the newer package portably and click its standard GUI
  **Update** action, or use the installed update card. No startup path may
  silently call `--install` or `--update`.
- Uninstall through Windows Apps/Programs. `--install`, `--update`,
  `--uninstall`, `--service` and `--server` are internal command paths used by
  the GUI/service workflow, not alternate package products.
- Never create or distribute `MasterDesk-*-install.exe`.

User logs normally live below `%APPDATA%\MasterDesk\log\`. Do not assume a
literal `masterdesk_rCURRENT.log` name; enumerate the directory because Viewer,
main GUI and update processes use different current/dated names.

## Known build details

- x64 beta106+ packages align their owned EXE/DLL PE metadata with the generated
  beta identity, including an incrementally reused runner. Existing issued
  packages and signed files cannot be overwritten/stamped. `-PrepareSigning`
  adds signing-preparation requirements (including the pinned custom-engine
  archive on full setup), but does not sign, upload, install or publish anything.
  See [x64 preparation](signing-x64-preparation.md). Local unsigned beta106 was
  used for verification. Hosted107 built but its final mixed-scope gate failed;
  both106/107 are reserved. The next hosted proof starts at beta108 or later.
- The custom build applies reproducible patches to the cached `desktop_drop`
  Windows source. If the upstream package signature changes, the build fails
  closed instead of silently omitting the patch.
- Installed descendants must not inherit the portable runtime app-name marker.
- Authenticode signing is separate; an unsigned local beta must not be described
  as publisher-signed.
- A successful build does not authorize publishing, manifest changes, GitHub
  release work, or production deployment.
