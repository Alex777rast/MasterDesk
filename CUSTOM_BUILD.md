# Self-hosted Windows build

This repository is based on the upstream RustDesk `1.4.9` tag
(`6c578292e8ebbbec708b76986ba8c4bc7c509747`).

## Compiled defaults

The client loads the following values before it reads a user profile:

- ID server: `176.123.167.146`
- Relay server: `176.123.167.146`
- Server public key:
  `oxdGP9iGMJ1gA3gmyAyjUNmgNAx6F4kD6Z3sLRjY7G4=`
- Codec: `VP9`
- Image quality: `Best`
- Official-client automatic updates: disabled

The implementation is in `src/custom_defaults.rs`. The settings are defaults,
not locked policy overrides, so an administrator can change them in the UI.

No API server is configured because the target is RustDesk Community Server.

## Build target

The first release target is the upstream-compatible Windows x64 Flutter
self-extracting executable. It can run portably as one file and can install the
RustDesk service through the normal client UI.

Use `scripts/Build-CustomWindows.ps1` from PowerShell to reproduce the build.
The script pins Rust 1.75.0, Flutter 3.24.5, LLVM 15.0.6, the upstream vcpkg
baseline and flutter-rust-bridge 1.80.1. It also generates bridge files when a
fresh Git checkout does not contain them.

Use `scripts/Test-CustomDefaults.ps1` to run the offline tests that verify the
resolved clean-profile server and display settings.

## Distribution and AGPL-3.0

This modified client remains licensed under GNU AGPL-3.0. Keep `LICENCE` and
the upstream copyright notices, mark modified releases as modified, and give
recipients access to the complete corresponding source and build scripts.

Windows artifacts are unsigned until an Authenticode certificate is configured.
