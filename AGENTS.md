# RustDesk Guide

Before changing or building MasterDesk, read `CODEX_START_HERE.md` completely.
It is the compact current-state handoff and tells you which detailed section to
open for the task. Do not read `CODEX_HANDOFF.md`, `CODEX_NEXT_PLAN.md` and
`PROJECT_CONTEXT.md` in full by default; use the routing table and targeted
`rg`/line reads from `CODEX_START_HERE.md`. This keeps context usage small while
retaining detailed history when it is actually needed.

## Current Production Safety Invariant

* Production runs the WSS registration plus authenticated-installation lease-fix
  image
  `sha256:bada4754be4c41e5fef6cc9ce8540c7c13d19a93a36eb44969df569d3f2049a1`
  in compatibility mode `N/N`. The fresh backup, stopped recovery containers on
  the prior exact image and canary evidence are recorded in `CODEX_HANDOFF.md`.
* Never deploy the known failed image
  `sha256:7d6bc23de9290baa3404c248b671b5dab89e797d5198a3f73167ebda8aa3707f`
  or enable strict relay on production.
* Generic TCP/TLS/WebSocket endpoint success is not proof of MasterDesk registration or relay operation.
* Any production mutation requires a new explicit user instruction, a fresh verified backup, exact image/key/config attribution, a tested rollback, and real direct/relay canaries.
* Keep direct TCP 21118/21119 blocked externally; WSS is exposed only through Caddy/HTTPS 443.
* External application-level WSS registration/reconnect/routing and relay
  canaries pass. Until a real MasterDesk client-to-client WSS session is
  confirmed, keep ordinary client validation on native transport and enable
  **Use WebSocket** only for the controlled WSS runtime check.

## Portable Update Invariant

* A no-argument `MasterDesk-*.exe` launch is always portable, including when MasterDesk is already installed.
* Portable startup must never query the MasterDesk update manifest, show an automatic/modal update prompt, or route automatically to `--install`/`--update`.
* A newer portable build must compare its embedded beta/date identity with the installed MasterDesk locally and show the standard **Update** button in its already-open GUI. Updating starts only after the user explicitly clicks that button.
* Never create or distribute a `MasterDesk-*-install.exe`; packages remain portable-by-default and update an older installed copy only through the standard GUI flow.
* Installed descendants must not inherit the portable `RUSTDESK_APPNAME` marker.
* When an installed MasterDesk exists, a portable main GUI must attach to the
  single installed `--server` through the versioned `_gui_compat` IPC channel;
  it must not start a second host server or register the same ID twice.
* Keep the exact-executable check on main IPC. `_gui_compat` is a separate,
  protected same-Windows-account pipe with an explicit GUI command allowlist;
  it must never expose the machine password verifier or protected API/key values.
* The first transition from beta 7 to beta 8 is necessarily limited: beta 7
  does not implement `_gui_compat`. The beta 8 portable remains portable and
  offers GUI Update without starting a second server; full attachment is
  available after beta 8 is installed and for later portable builds.
* Keep regression coverage for portable-by-default and the skipped automatic portable update check. Never reintroduce the `.5`/`.6` startup chain that created multiple argument-less GUI processes.

## Build Identity Invariant

* Every newly built or changed EXE has a monotonically increasing positive numeric beta and build date in its filename: `MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86_64.exe`.
* `scripts/Build-CustomWindows.ps1` injects the same beta number and `YYYY-MM-DD HH:mm` build date into the Rust DLL, including incremental Rust-only builds.
* The **About MasterDesk** page must always show the full branded build version (`<version> beta <N>`) and exact build date.
* Never hand-rename an EXE to simulate another build identity or installer mode. Rebuild/package through the script so filename, embedded identity, registry version, About page, and GUI upgrade comparison agree.

## Economical Validation Workflow

Use this sequence for MasterDesk changes:

`FAST → INCREMENTAL BUILD → TARGETED VM RUNTIME → FINAL CANDIDATE → FULL REGRESSION / CLEAN BUILD only when required`

* Start with targeted tests for only the components changed in the task.
* During one task, do not run a full Windows build after every edit.
* Use incremental component builds and only the relevant VMware lab runtime scenario while iterating; do not run the full VM matrix after every small edit.
* Build one full local candidate EXE only after the complete change set passes its targeted tests and applicable VM runtime tests.
* Do not run `cargo clean`, clear Flutter/vcpkg/build caches, or force a full rebuild without a specific diagnosed reason.
* A Rust-only change must not automatically rebuild Flutter AOT.
* A server-only change must not start a Windows client build.
* Do not reread successful verbose build/test logs; retain them as artifacts and report only the compact result.
* The PROJECT_CONTEXT rule requiring a local EXE means one final candidate after the internal edit/test cycle, never one EXE per attempted fix.
* Run full regression or a clean build only for a release/final candidate that requires it, a substantial build-system/toolchain change, proven cache corruption/incompatibility, or an explicit user request.

## Project Layout

### Directory Structure
* `src/` Rust app
* `src/server/` audio / clipboard / input / video / network
* `src/platform/` platform-specific code
* `src/ui/` legacy Sciter UI (deprecated)
* `flutter/` current UI
* `libs/hbb_common/` config / proto / shared utils
* `libs/scrap/` screen capture
* `libs/enigo/` input control
* `libs/clipboard/` clipboard
* `libs/hbb_common/src/config.rs` all options

### Key Components
- **Remote Desktop Protocol**: Custom protocol implemented in `src/rendezvous_mediator.rs` for communicating with rustdesk-server
- **Screen Capture**: Platform-specific screen capture in `libs/scrap/`
- **Input Handling**: Cross-platform input simulation in `libs/enigo/`
- **Audio/Video Services**: Real-time audio/video streaming in `src/server/`
- **File Transfer**: Secure file transfer implementation in `libs/hbb_common/`

### UI Architecture
- **Legacy UI**: Sciter-based (deprecated) - files in `src/ui/`
- **Modern UI**: Flutter-based - files in `flutter/`
  - Desktop: `flutter/lib/desktop/`
  - Mobile: `flutter/lib/mobile/`
  - Shared: `flutter/lib/common/` and `flutter/lib/models/`

## Rust Rules

* Avoid `unwrap()` / `expect()` in production code.
* Exceptions:

  * tests;
  * lock acquisition where failure means poisoning, not normal control flow.
* Otherwise prefer `Result` + `?` or explicit handling.
* Do not ignore errors silently.
* Avoid unnecessary `.clone()`.
* Prefer borrowing when practical.
* Do not add dependencies unless needed.
* Keep code simple and idiomatic.

## Tokio Rules

* Assume a Tokio runtime already exists.
* Never create nested runtimes.
* Never call `Runtime::block_on()` inside Tokio / async code.
* Do not hide runtime creation inside helpers or libraries.
* Do not hold locks across `.await`.
* Prefer `.await`, `tokio::spawn`, channels.
* Use `spawn_blocking` or dedicated threads for blocking work.
* Do not use `std::thread::sleep()` in async code.

## Editing Hygiene

* Change only what is required.
* Prefer the smallest valid diff.
* Do not refactor unrelated code.
* Do not make formatting-only changes.
* Keep naming/style consistent with nearby code.

## Localization (`src/lang/*.rs`)

Each file is a `HashMap<key, translation>`. Layout:

* `template.rs` is the master list of every key. **Never edit it** as part of translation work.
* `en.rs` holds only the keys whose English display text differs from the key itself.
* Every other file (`de.rs`, `fr.rs`, …) carries the full key set; an untranslated entry has an empty value: `("key", "")`.

### Finding the English source for a key

When filling an empty entry, determine the source English text with this rule:

* If `key` exists in `en.rs` **with a non-empty value**, that value is the source text (look it up in `en.rs`).
* Otherwise the **key string itself is the source text** (the key is already plain English).

Then translate that source into the file's target language (infer the language from the file's existing non-empty entries / filename).

### Translation hygiene

* Only fill empty values. Never change keys, and never touch existing non-empty translations.
* Preserve placeholders (`{}`) and escape sequences (`\n`, `\"`) exactly as in the source.
* Do not translate brand or technical tokens: `RustDesk`, `Socks5`, `TLS`, `UAC`, `Wayland`, `X11`, `TCP`, `UDP`, `2FA`, `RDP`, `D3D`, etc.
* Copy URL values (e.g. `doc_*` keys) verbatim from `en.rs`.
