# MasterDesk architecture

This document describes stable component boundaries. For the exact dirty
worktree and unfinished work, see [current-state.md](current-state.md).

## Product shape

MasterDesk is based on RustDesk 1.4.9 and produces one Windows x64 Flutter
self-extracting EXE. The same package runs portably or, after an explicit GUI
action, installs `MasterDesk.exe` and the Windows service.

The major layers are:

1. Flutter desktop UI and multi-window Viewer/File Manager.
2. Rust FFI/API boundary and session models.
3. Client/server protocol, rendezvous, relay, media, input and file transfer.
4. Windows service, interactive-session process, native hooks and capture.
5. Shared protocol/config crates and the self-hosted hbbs/hbbr deployment.

## UI and Rust boundary

- `flutter/lib/desktop/`: desktop home, Viewer, File Manager, install/update UI
  and session toolbars.
- `flutter/lib/models/`: UI state for sessions, input, service state and file
  transfer.
- `flutter/windows/runner/`: Windows Flutter runner and registration of plugins
  for both the main engine and `desktop_multi_window` child engines.
- `src/flutter.rs`, `src/flutter_ffi.rs`, `src/ui_interface.rs` and
  `src/ui_cm_interface.rs`: bridge Flutter actions/events to Rust. File Manager
  writes and parallel-receive state are primarily in `ui_cm_interface.rs`.
- Generated bridge files are build inputs. The build script verifies that they
  are not stale before packaging.

## Connection and transport

- `src/rendezvous_mediator.rs`: ID registration, authenticated installation
  leases, online state, direct/relay negotiation and WSS/native registration.
- `src/client.rs` and `src/client/io_loop.rs`: controller-side session loop,
  ordinary file jobs, parallel worker negotiation, upload workers, telemetry,
  fallback and resume initiation.
- `src/server/connection.rs`: controlled-side authorization, input queue,
  clipboard/file messages, parallel receive/finalize and session permissions.
- `libs/hbb_common/`: protobufs, config, security payloads, identity and shared
  filesystem logic. It is a Git submodule and can be dirty independently.
- `deploy/masterdesk-server/`: reproducible production server patches,
  inspection, cutover, canary and rollback scripts. It is not client build
  input and must not be deployed as part of a client-only change.

Compiled client defaults point at `hbbs.masterdesk.online`,
`hbbr.masterdesk.online` and the separate account API. Administrator-defined
ID/relay endpoints remain configurable; protected API/key values are not
exposed by the generic options bridge.

## Windows service and interactive sessions

The Windows service runs in Session 0 only as supervisor/privileged authority.
It launches one service-owned `--server` child in the selected interactive
Console or RDP session on `winsta0\default`. On session handover it uses a
ready/go event, waits for the previous child, verifies the replacement process
session ID, then releases it. Capture and input must never run in Session 0.

The main IPC pipe retains exact-executable authorization. A separate protected
`_gui_compat` pipe lets a newer portable GUI attach to an installed compatible
server without starting a second host server. Its allowlist excludes password
verifiers and protected API/key values. See [decisions.md](decisions.md).

## Capture and display

- `src/server/video_service.rs`: display service and capturer lifetime.
- `libs/scrap/`: display enumeration and capture backends.
- Windows normal capture is created through the portable-service capture path,
  which selects DXGI/GDI as available in the interactive session.
- `libs/virtual_display/` and `dylib_virtual_display.dll`: upstream Windows IDD
  integration for hosts without a physical monitor. Flutter also recognizes
  RustDesk IDD and Amyuni virtual displays.
- Privacy mode has a separate Windows magnifier path; its legacy capturer is
  single-monitor even where privacy overlays cover multiple monitors.

Session/capture limitations and proven lab behavior are in
[rdp-display.md](rdp-display.md).

## Input

- `flutter/lib/models/input_model.dart`: maps Viewer pointer/keyboard events and
  desktop actions to session input calls.
- `src/server/connection.rs`: receives, orders and queues remote input.
- `libs/enigo/` and `src/platform/windows.rs`: apply input to Windows.
- `src/platform/windows.cc`: low-level keyboard hook and system-hotkey policy.

Keyboard-layout synchronization detects a physical controller chord, resolves
the committed controller KLID, sends it through the protocol, queues it at the
target, and applies it to the target foreground thread. Tests must distinguish
physical-hook behavior from synthetic MCP/RDP keystrokes.

## Clipboard, Explorer copy/paste and Drag&Drop

- `libs/clipboard/src/windows/wf_cliprdr.c`: Windows OLE/CLIPRDR formats,
  `CF_HDROP`, `FileGroupDescriptorW` and `FileContents`.
- `libs/clipboard/src/platform/windows.rs`: Rust callbacks/messages around the
  native clipboard context.
- `flutter/lib/desktop/pages/remote_page.dart`: Viewer `DropTarget`; it converts
  local paths to MasterDesk file clipboard data and asks `InputModel` to focus
  the remote point and send remote Ctrl+V.
- `desktop_drop` must be registered in every Flutter child Viewer engine, not
  only the main engine.

Explorer transfer is lazy: advertising descriptors does not copy bytes.
Explorer later requests size/content through OLE. Source paths must therefore
be snapshotted before remote formats are advertised and remain valid until all
content requests finish.

## File transfer engine

The dedicated File Manager and clipboard-file path share negotiated parallel
transfer support. The sender uses a reusable worker pool and a dynamic work
queue; the receiver performs positioned writes and final verification. The
configured modes are Auto, 1x/off, 2x, 4x and 8x. A peer without the feature or
a negotiation/worker failure must fall back safely to the legacy stream.

Resume state is intended to preserve a contiguous completed prefix and restart
parallel workers at that offset. Current runtime gaps are listed only in
[current-state.md](current-state.md).
