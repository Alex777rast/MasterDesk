# MasterDesk self-hosted Windows build

This repository is based on the upstream RustDesk `1.4.9` tag
(`6c578292e8ebbbec708b76986ba8c4bc7c509747`).

## Compiled defaults

The client loads the following values before it reads a user profile:

- Product name, Windows service and configuration namespace: `MasterDesk`
- ID server: `hbbs.masteronline.space`
- Relay server: `hbbr.masteronline.space`
- Account/address-book API: `https://api.masteronline.space`
- Server public key:
  `oxdGP9iGMJ1gA3gmyAyjUNmgNAx6F4kD6Z3sLRjY7G4=`
- Codec: `VP9`
- Image quality: `Best`
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
- Windows socket-level direct routing to `hbbs.masteronline.space`,
  `hbbr.masteronline.space` and `api.masteronline.space` (with
  `176.123.167.146` retained as a hidden resolved-address alias)
- Windows RDS cross-session GUI access for local administrators
- MasterDesk release checks: enabled through the compiled HTTPS manifest
- Automatic installation: disabled until Authenticode signing is available

The implementation is in `src/custom_defaults.rs`. The settings are defaults,
not locked policy overrides, so an administrator can change them in the UI.
Profiles that still contain the previous combined `desk.masteronline.space`
value are migrated once to the separate ID and relay hostnames.

An unauthorized incoming request restores and foregrounds the connection
manager on the client machine. The local user can accept or reject the request
while the remote operator is still at the password prompt.

The Community `hbbs`/`hbbr` deployment remains responsible only for ID and
relay traffic. Account and address-book requests use the separate HTTPS API at
`api.masteronline.space`; its reproducible test deployment is stored in
`deploy/masterdesk-api/`.

## MasterDesk update channel

At startup the client reads
`https://api.masteronline.space/masterdesk/version/latest`. The manifest
contains an independent branded release sequence and an HTTPS release-page
URL. A newer sequence displays a dismissible update card in the main window.

Until SignPath signing is enabled, the card opens the release page and leaves
download and installation under user control. The background auto-installer is
disabled for branded clients. To publish a release, first upload and verify the
release assets, then update `deploy/masterdesk-api/latest.json` and deploy that
file to the server. This ordering prevents clients from being directed to an
incomplete release.

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

The packaged RDS build is written to
`dist/MasterDesk-1.4.9-RDS-x86_64.exe`.

Use `scripts/Test-CustomDefaults.ps1` to run the offline tests that verify the
resolved clean-profile server, permission, local/display and direct-routing
settings.

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
