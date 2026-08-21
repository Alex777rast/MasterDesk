# MasterDesk self-hosted Windows build

For a new Codex account or context-free continuation, read
`CODEX_START_HERE.md` first. It routes only the relevant portions of the
detailed handoff and plan. This guide does not authorize a build, publication,
or production change by itself.

This repository is based on the upstream RustDesk `1.4.9` tag
(`6c578292e8ebbbec708b76986ba8c4bc7c509747`).

## Compiled defaults

The client loads the following values before it reads a user profile:

- Product name, Windows service and configuration namespace: `MasterDesk`
- ID server: `hbbs.masterdesk.online`
- Relay server: `hbbr.masterdesk.online`
- Account/address-book API: internal compiled endpoint, hidden from UI and exported configuration
- Server public key: internal compiled value, hidden from UI and exported configuration
- Codec: `VP9`
- Image quality: `Balanced`
- View style: `Adaptive`
- Incoming authentication: password and local `Accept` / `Dismiss` approval
- Keyboard mode for new peers: `Translate` (`beta` in the UI)
- Keyboard input source: `Input source 1`
- Monitor switch on the main toolbar: enabled
- Monitors on the session toolbar: enabled
- Use all local displays for a remote session: enabled
- UDP hole punching: enabled
- Block remote-device input: disabled
- Privacy mode: disabled
- Camera: disabled
- TCP tunnelling: disabled
- Remote configuration modification: enabled
- Windows socket-level direct routing to `hbbs.masterdesk.online`,
  `hbbr.masterdesk.online` and `api.masterdesk.online` (with
  `176.123.167.146` retained as a hidden resolved-address alias)
- Windows RDS cross-session GUI access for local administrators
- MasterDesk release checks: enabled through the compiled HTTPS manifest
- Interactive in-place updates: enabled on Windows with release SHA-256
  verification
- Unattended background installation: disabled

The implementation is in `src/custom_defaults.rs`. ID and relay endpoints remain
administrator-configurable. API Server and Key are protected internal values:
they are obfuscated in the executable, hidden from the UI and cannot be replaced
through the generic options bridge.
Profiles that still contain the previous `desk.masteronline.space` or split
`*.masteronline.space` endpoints are migrated to `*.masterdesk.online` during
an application update. Unrecognized administrator-defined servers are kept.

An unauthorized incoming request restores and foregrounds the connection
manager on the client machine. The local user can accept or reject the request
while the remote operator is still at the password prompt.

The Community `hbbs`/`hbbr` deployment remains responsible only for ID and
relay traffic. Account and address-book requests use the separate HTTPS API at
`api.masterdesk.online`; its reproducible test deployment is stored in
`deploy/masterdesk-api/`.

## MasterDesk update channel

An installed client can read the compiled HTTPS update manifest at startup. A
portable client never requests the manifest automatically. The manifest
contains an independent branded release sequence and an HTTPS release-page
URL. A newer sequence displays a dismissible update card in the main window.

For an installed Windows client the card downloads the exact MasterDesk release
asset, verifies it against `SHA256.txt` from the same GitHub Release and starts
an elevated in-place update. A downloaded `MasterDesk-*.exe` opens portably on
a clean computer and shows the normal Install card in the main window. It also
opens portably when an installed MasterDesk copy is detected: startup never
enters installation or update automatically. If the portable build is newer
than the installed copy, the main window shows an explicit `Update` button.
Only that user action may start the local in-place update.
Every package remains portable-by-default; never create a filename ending in
`-install.exe`. Each new EXE uses
`MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86_64.exe`, with an increasing
numeric beta. The same full `<version> beta <N>` and `YYYY-MM-DD HH:mm` build
date are embedded in the package, displayed on **About MasterDesk**, written to
installed registry metadata, and used for the local GUI Update comparison.
The unattended background auto-installer remains disabled. Authenticode through
SignPath is still required before describing the binaries as publisher-signed.

A permanent password set by a clean portable process is stored as an encrypted
verifier/salt pair in the user's `MasterDesk.toml`. The GUI reports success only
after a checked write and fresh read confirm that exact pair, so closing and
reopening the portable process must retain it. An installed Windows client uses
the separate service-owned machine store instead.

On Windows, Ctrl+Shift/Alt+Shift layout synchronization waits for Windows to
commit the controller's local change (including key-up) and then sends that
exact KLID to the controlled endpoint. Mismatched controller/controlled layouts
must therefore converge after the first physical shortcut.
To publish a release, first upload and verify the release assets, then allow the
manifest refresh service to promote it. This ordering prevents clients from
being directed to an incomplete release.

## MasterDesk branding

The approved MasterDesk artwork is stored in `res/masterdesk-source.png`.
Run `scripts/Generate-MasterDeskBrandAssets.py` with Pillow to regenerate the
Windows executable, portable packer, tray and Flutter UI icons, together with
the light and dark `MasterDesk` wordmarks used on the home page.

## Direct server routing on Windows

Connections to the compiled-in ID/relay server do not follow a TUN/VPN default
route. The client enumerates connected Windows interfaces and accepts an
operational hardware interface with an IPv4 gateway. If Hyper-V owns the
physical NIC, its external Hyper-V Ethernet adapter is accepted as the direct
egress instead. The client binds the RustDesk socket to that interface's local
address and applies the Winsock `IP_UNICAST_IF` option. This is done
independently for TCP and UDP and does not add or modify system routes, require
administrator rights or require per-customer VPN rules.

The policy is strict: server sockets do not silently fall back to the VPN
interface if no usable direct interface exists. The selected interface or a
failure reason is written to the RustDesk log with the
`Direct-server bypass` prefix.

A VPN product can still block these packets with a Windows Filtering Platform
kill switch. That is outside normal route selection and cannot be bypassed by
an unprivileged application socket. Such a configuration needs either a VPN
policy exception or a separately installed network driver/service.

## Windows RDS sessions

RustDesk's Windows service keeps one machine ID and switches its privileged
`--server` process to the RDP session selected by the remote controller. On an
RDS host the active `--server` process can therefore be in a different session
from the local administrator GUI.

The RDS handover waits for the old `--server` child to exit before starting the
replacement, verifies the replacement's actual Windows session ID and attaches
it to the selected session's interactive `winsta0\default` desktop. This avoids
both a stale main-IPC race and screen capture from a noninteractive service
desktop.

This build allows an unelevated member of the local Administrators group to
connect to that cross-session main IPC channel. The peer must still resolve to
the exact same RustDesk executable. Standard RDS users remain restricted to
their own session and cannot use this path to read the machine password or
change machine-wide settings.

## Build target

The first release target is the upstream-compatible Windows x64 Flutter
self-extracting executable. It can run portably as one file and can install the
RustDesk service through the normal client UI.

During installation the embedded `rustdesk.exe` payload is renamed to
`MasterDesk.exe` before service and shortcut registration. Installation errors
are shown instead of being silently discarded.

Use `scripts/Build-CustomWindows.ps1` from PowerShell to reproduce the build.
The script pins Rust 1.75.0, Flutter 3.24.5, LLVM 15.0.6, the upstream vcpkg
baseline and flutter-rust-bridge 1.80.1. It also generates bridge files when a
fresh Git checkout does not contain them.

The packaged RDS build is written to a beta/date-qualified path under `dist/`.

For an intermediate Rust-only candidate, reuse the existing Flutter release
runner with:

`scripts/Build-CustomWindows.ps1 -SkipVcpkg -SkipFlutterSetup -IncrementalRustOnly -BetaNumber <N>`

This mode rebuilds `librustdesk.dll` and the portable container only. It does
not run Flutter AOT, CMake, vcpkg installation, `build.py`, or `cargo clean`.
It requires a previously verified `flutter/build/windows/x64/runner/Release`
directory and is not a substitute for the final release validation.

For repeatable short edit/test cycles, use
`scripts/Test-TargetedWindowsClient.ps1`. It keeps verbose Cargo output under
`artifacts/targeted-windows-client/` and prints only compact PASS/FAIL lines.
After those tests pass, `scripts/Build-IncrementalBeta.ps1` runs the same
targeted gate, selects `max(existing beta) + 1`, and delegates to the cached
Rust-only packaging path above. An explicit `-BetaNumber <N>` is accepted only
when it is newer than every existing dated beta. Use `-SkipTargetedTests` only
when the exact current tree has already passed that gate in the same task.
Neither wrapper clears caches or touches VMware.

If the same intermediate candidate also contains a targeted Dart UI change,
add `-RefreshFlutterAot`. This invokes Flutter's cached Windows release AOT
backend directly and copies the resulting `app.so`, then performs the same
incremental Rust/package step. It does not run the outer CMake wrapper,
`build.py`, vcpkg setup, `cargo clean`, or the full Windows build.

The incremental AOT path includes a bounded watchdog for Flutter 3.24: after a
new `app.so` has remained unchanged for 15 seconds, it stops only the stale
hidden `tool_backend.bat` wrapper and continues with that verified output. A
ten-minute deadline fails with paths to the isolated stdout/stderr logs under
`.tools\logs\` instead of leaving the build waiting indefinitely.

On this Codex Windows sandbox the legacy Flutter 3.24 backend can finish a new
`flutter\.dart_tool\flutter_build\...\app.so` and its stamps but leave idle Dart
wrapper processes. Do not rerun AOT or clear caches. Confirm the newest
`app.so` is complete and stable, stop only that build wrapper, copy the exact
new AOT to `flutter\build\windows\x64\runner\Release\data\app.so`, and resume
the same beta with `-SkipTargetedTests` and without `-RefreshFlutterAot`.

Use `scripts/Test-CustomDefaults.ps1` to run the offline tests that verify the
resolved clean-profile server, permission, local/display and direct-routing
settings.

For edit/test iterations, use the economical sequence
`FAST → INCREMENTAL BUILD → TARGETED VM RUNTIME → FINAL CANDIDATE → FULL REGRESSION / CLEAN BUILD only when required`.
Run targeted tests first, preserve the existing build caches, use only the
applicable VMware lab scenario, and create one full local candidate EXE after
the whole change set has passed those checks. Full regression or a clean build
is reserved for a release/final candidate that requires it, a build-system or
toolchain change, proven cache incompatibility, or an explicit request. The lab
is driven by `scripts/lab/Test-MasterDeskLab.ps1`; detailed output is kept under
`artifacts/lab/` instead of being printed to the working context.

## GitHub Actions and releases

`.github/workflows/masterdesk-windows.yml` runs on a GitHub-hosted
`windows-2022` runner. It checks out recursive submodules, installs the pinned
toolchain, invokes the same PowerShell build script, runs the defaults tests,
and publishes the EXE with its SHA-256 and source commit.

Tags matching `v*` create a GitHub Release. Until SignPath Foundation approves
the project, these release artifacts remain unsigned. After approval, the
maintainer enables the guarded SignPath step with repository variables and the
`SIGNPATH_API_TOKEN` Actions secret. The artifact submitted to SignPath is the
one uploaded by the same GitHub-hosted build job.

## Distribution and AGPL-3.0

This modified client remains licensed under GNU AGPL-3.0. Keep `LICENCE` and
the upstream copyright notices, mark modified releases as modified, and give
recipients access to the complete corresponding source and build scripts.

Windows artifacts are unsigned until an Authenticode certificate is configured.
