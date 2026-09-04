# Validation and evidence

This is the stable validation policy. Exact current results and pending runtime
checks are in [current-state.md](current-state.md); lab commands and topology
are in [lab-environment.md](lab-environment.md).

## Economical order

Use the narrowest evidence that can falsify the change:

1. syntax/unit test for the changed function or protocol stage;
2. `cargo check --features flutter` or the applicable Flutter test;
3. cached incremental candidate with a new embedded beta identity;
4. one targeted VM runtime scenario;
5. one final candidate and broader regression only when release risk requires
   it.

Do not repeat a previously passing unrelated test, reread full verbose logs, or
run the entire VM matrix after each edit. Save verbose output under `artifacts/`
and report compact paths, hashes and verdicts.

## Static and component checks

For Rust/client changes:

```powershell
.\scripts\Test-TargetedWindowsClient.ps1 -Filter '<relevant-filter>'
cargo check --features flutter
```

For custom defaults:

```powershell
.\scripts\Test-CustomDefaults.ps1
```

For Flutter transfer telemetry/UI model changes:

```powershell
. .\scripts\Initialize-MasterDeskBuildEnvironment.ps1
Push-Location .\flutter
& (Join-Path $env:MASTERDESK_FLUTTER_ROOT 'bin\flutter.bat') `
    test .\test\file_transfer_telemetry_test.dart
Pop-Location
```

For every handoff involving scripts or source:

- parse each edited PowerShell script with the PowerShell parser;
- run `git diff --check`;
- verify the package's filename, embedded identity, build date and SHA-256;
- inspect `git status` and preserve unrelated dirty files.

## Windows smoke checks

Select only those affected by the change:

- no-argument package remains portable;
- explicit GUI install/update/uninstall completes without a hanging console or
  duplicate `MasterDesk.exe`/`--server` processes;
- the installed service is Running and exactly one selected interactive
  `--server` owns the machine session;
- ID reaches Ready/online state without unexplained replacement;
- B connects to A by temporary or permanent password as intended;
- direct/relay/WSS behavior is tested only when that transport changed.

## GUI, mouse, keyboard and layout

For automated B-to-A input, all input must originate on VM-B inside its Viewer.
VM-A is observation-only: use it to read state and capture evidence, never to
type the expected probe. Record screenshots before connection, after
connection, before input, after input and after target verification, plus
foreground window, process/service state and timestamps.

For layout synchronization, prove the entire relevant path:

```text
physical hook -> chord detection -> controller KLID -> protocol send ->
target receive -> queue -> Windows apply -> verified target KLID
```

MCP `Shortcut` and host-RDP synthetic keys do not prove the physical hook.
Physical chord behavior therefore requires a user-operated key action when the
hook itself is under test.

For special keys, test the consuming application, not only a text box. Examples
are Space in Total Commander, `P` in TestDisk and local Alt+PrintScreen handling
by FastStone.

## Clipboard, Explorer and Drag&Drop

Clipboard-file and D&D runtime checks require physical user actions when
synthetic shortcuts fail to reach the Viewer:

1. use a uniquely named source file with known length and SHA-256;
2. copy/paste or drag from VM-B local Explorer into VM-A Explorer inside the
   MasterDesk Viewer;
3. verify the exact destination path, length and SHA-256 on VM-A;
4. verify all Explorer and MasterDesk processes remain responsive;
5. inspect fresh logs for format advertisement, descriptor/size/content
   requests, transfer mode/fallback and completion.

A plus/copy cursor proves only OLE drop acceptance. It is not PASS until the
destination file exists and matches. A `FileGroupDescriptorW` request or a
size-only `dw_flags=1` request also does not prove content transfer; the path
must progress to content requests/writes/final hash.

Test both directions if clipboard-file code changed. D&D into a Viewer is a
controller-to-target path; reverse direction needs its own supported UI action.

## Parallel transfer and resume

For the dedicated File Manager and clipboard-file paths, test Auto, 1x/off and
at least one fixed multi-stream mode. Record negotiated mode, selected stream
count, fallback reason (if any), bytes, elapsed time and exact hashes.

Resume PASS requires more than a completed file:

- interrupt a large transfer after a recorded offset;
- continue in the same session and verify negotiated parallel resume starts at
  that offset without an overwrite prompt;
- disconnect/reconnect, reopen File Manager and verify the saved job is still
  offered;
- complete at comparable parallel throughput, with no silent legacy fallback,
  and verify exact SHA-256;
- test cancel/overwrite/conflict cleanup separately.

## Verdicts

**PASS**: the observable end-to-end result is exact, hashes/state match, the
connection stays stable, and no unexpected fallback or hanging/duplicate
process remains.

**FAIL**: prerequisites and focus are proven, the relevant MasterDesk path was
executed, but the expected result is absent, incorrect, corrupt, unstable or
uses a forbidden fallback.

**INCONCLUSIVE**: infrastructure prevents attribution: MCP unavailable, RDP or
Console locked/disconnected, black screenshot, no reliable focus, synthetic
input did not reach the Viewer, Safe Mode removed RDP/VMware services, or the
tested binary/hash cannot be proven. Never relabel infrastructure-inconclusive
input as a product PASS or FAIL.

## Production evidence

Endpoint/TLS/WebSocket reachability is not an application canary. A production
server change requires a fresh backup and rollback plus real registration,
reconnect, direct connection and relay canaries with exact image/config/key
attribution. Client VM tests do not authorize or substitute for these checks.
