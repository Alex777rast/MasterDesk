# Current state handoff

## 2026-09-04 beta 60 Flutter icon asset integrity

Beta 60 is the current local-only candidate:

```text
dist\MasterDesk-1.4.9-10-beta-60-2026-09-04-RDS-x86_64.exe
SHA-256 A26D047CFB37ED33CAB9284ADCB826B5751A85720AC74824D76DE2B536B54339
libmasterdesk.dll 28F8489AF7A383EFD05DB966342AD6382CB80401F0C8104E5793AD7DB68524C1
Flutter app.so C595A0E6581289684DBE9F1690D20FB9D90F2D54A5797F6712472AE93A0D15DC
runner 264937CF60E9BEB84DD985CAD5DA6650403BB4D70DC8EC1DD6BC1F69CEBBDB74
```

The beta 59 package contained the full `MaterialIcons-Regular.otf`, but its
`FontManifest.json` and `AssetManifest.bin` were both zero bytes. Flutter could
therefore render normal Russian text while showing empty squares for Material
icons such as the diagnostics close and drop-down controls. A failed cached AOT
refresh had truncated the manifests; the following Rust-only package reused the
damaged Release directory because package consistency checked `app.so` but not
the Flutter asset bundle.

The Windows build now validates non-empty asset/font manifests, parses the font
manifest and requires the Material Icons registration before packaging. The
incremental AOT path validates the generated `flutter\build\flutter_assets`
bundle, waits for both AOT and assets to become stable, stops the exact wrapper
process tree, and copies the validated assets into the Release directory. It
uses `System.Diagnostics.Process` so retained Dart output handles cannot prevent
the watchdog from running.

Validation:

- the strict-mode focused validator accepts the good bundle and rejects empty
  `FontManifest.json` and `AssetManifest.bin` fixtures;
- the standard targeted Windows client gate passed under
  `artifacts\targeted-windows-client\20260904-111457\`; final build-script
  syntax and validator checks passed after the watchdog refinement;
- the final Release bundle has `AssetManifest.bin` = 4448 bytes,
  `FontManifest.json` = 483 bytes and a registered 1,645,184-byte
  `MaterialIcons-Regular.otf` with SHA-256
  `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`;
- clean beta 60 installs on VM10-A and VM10-B match the runner and DLL hashes
  above; the installed manifests and Material Icons font match the Release
  bundle on both VMs;
- host-driven RDP mouse input on VM10-B opened the beta 60 B-to-A Viewer and its
  transfer diagnostics panel. The toolbar icons, drop-down arrow and close icon
  render normally with no square glyphs.

Final hashes and manifest evidence are in
`artifacts\build-system\beta60-final-verification.json`; the validator fixture
result is under `artifacts\build-system\beta60-flutter-bundle-validator\`, and
installed/visual evidence is under
`artifacts\lab\beta60-font-assets-20260904\`. No transfer implementation source
changed between beta 59 and beta 60, so the accepted beta 59 two-drop result
below remains the transfer-path evidence for beta 60. Production was not
changed. The next changed executable identity is beta 61.

## 2026-09-04 beta 59 Explorer paste and AppData branding

Beta 59 is superseded by beta 60, but remains the accepted transfer-path
candidate:

```text
dist\MasterDesk-1.4.9-10-beta-59-2026-09-04-RDS-x86_64.exe
SHA-256 DA0FF532E3AB814E61975A49128049A39267697DEC6D282EFE727249B30E55FC
libmasterdesk.dll A9AD7370BEC27F99826DAE43A47FDB7EE68DB503E3D848CAD456B34EE75DF15F
Flutter app.so C595A0E6581289684DBE9F1690D20FB9D90F2D54A5797F6712472AE93A0D15DC
runner 264937CF60E9BEB84DD985CAD5DA6650403BB4D70DC8EC1DD6BC1F69CEBBDB74
```

The AppData archives from the affected beta 57 workstation prove that transfer
`d25b4da5-db9d-4c70-9cef-722d94fb659d` completed all eight ranges and published
the parallel cache, but Explorer never requested its contents. The Viewer used
layout-dependent `Key::Chr('v')` for the final synthetic Ctrl+V, so the command
could be lost on a non-English keyboard layout. The beta 57 bounded retry also
explains the later replacement prompt: after the first paste succeeded, a retry
could send Ctrl+V again because a target-local cache paste did not necessarily
advance the controller's content-request generation.

Beta 59 sends the Viewer drop paste as physical Windows scan codes (left Ctrl
`0x1D`, V `0x2F`) and consumes a pending-drop flag exactly once. There is no
timer or content-request-based paste retry. The parallel clipboard cache remains
owned by its transfer UUID while Explorer can still read it and is released by
the existing clipboard ownership/refcount lifecycle; it is not reused by a new
drop. This makes the second replacement prompt a duplicate-command fix, not a
cache-deletion workaround.

The Windows on-disk branding is also complete for new portable extractions:
the bundle contains `MasterDesk.exe`, `libmasterdesk.dll` and
`RuntimeBroker_MasterDesk.exe`, and its extraction root is
`%LOCALAPPDATA%\MasterDesk`. A legacy `%LOCALAPPDATA%\rustdesk` cache is migrated
only when its MasterDesk build marker proves ownership; known payload files and
legacy `rustdesk` log names are renamed without overwriting an existing branded
file. Unrelated upstream RustDesk data is deliberately not claimed. The examined
workstation's `%LOCALAPPDATA%\rustdesk` directory was an old MasterDesk portable
cache, not the cause of the clipboard failure.

Validation completed so far:

- the layout-independent paste and one-shot pending-state Rust tests passed;
- all five portable AppData migration/name-collision tests passed;
- the `hbb_common` release check passed (only its six pre-existing warnings);
- the release bundle contains no filename containing `rustdesk`;
- clean beta 59 installations on VM10-A and VM10-B match the runner and DLL
  hashes above;
- the final host-driven RDP mouse check verified `8x`, transferred the exact
  beta 59 package from VM10-B to VM10-A, verified its 28,555,776-byte length and
  SHA-256, deleted that exact target, then physically dragged the same source a
  second time;
- the second transfer recreated exactly one matching file without an overwrite
  prompt; an additional delayed capture still showed no replacement dialog.

The successful build log is
`artifacts\incremental-beta\20260904-020213\build-beta-59.log`; focused test
evidence is under `artifacts\targeted-windows-client\20260904-001723\`, and the
current lab evidence is under
`artifacts\lab\beta59-dnd-repeat-20260904\`. Its first and second hash records
are `37-a-first-transfer-verify.json` and `42-a-second-transfer-verify.json`; the
post-delete/second-drop captures are
`host-rdp-B-20260904T070724454Z.png`,
`host-rdp-B-20260904T070745118Z.png`,
`host-rdp-B-20260904T070810696Z.png` and
`host-rdp-B-20260904T070849194Z.png`. Beta 58 was superseded before final
acceptance by the non-overwriting legacy-name collision fix. Production was not
changed. The next changed executable identity is beta 60.

## 2026-09-03 beta 57 Explorer mode routing and materialization

Beta 57 is the current local-only candidate:

```text
dist\MasterDesk-1.4.9-10-beta-57-2026-09-03-RDS-x86_64.exe
SHA-256 CD3169AFC2CD83C2FCD26EF1C718128A0D710683314FBE446EE32F412A2001EC
librustdesk.dll 4D72D7015D5B3160F887B278DE71C7574636AEEA88780118351D02B5445F5951
Flutter app.so 6EB1E913589CE43CEDEEE77E902750B532C24EA60701BE673A412C22F2C8E55F
runner 3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
```

Beta 56 applied the Explorer parallel-cache selector only after the native
clipboard format list had already been generated. This made Ctrl+C/Ctrl+V use
the previous legacy state and Drag&Drop retain the previous parallel state.
Beta 57 synchronizes the native clipboard flag when peer capabilities arrive,
when the global selector changes, and immediately before the Viewer publishes
a Drag&Drop file list. `1x` therefore advertises only the standard Explorer
formats; `Auto/2x/4x/8x` add `MasterDeskParallelFileCacheV1`.

The reported missing-file failure was not lost transfer data: the completed
payload remained in `%LOCALAPPDATA%\Temp\MasterDesk\clipboard-cache`, but
Explorer never issued a content request because the final Viewer Ctrl+V was
occasionally lost after cache publication. The Viewer drop path now arms a
bounded paste retry and stops retrying as soon as the clipboard layer observes
an Explorer content request.

Host-driven RDP runtime validation passed on exact beta 57 installations on
VM10-B -> VM10-A:

- `8x` Drag&Drop created `DND8X.bin` (32 MiB) and `FOLDER8X` with two files
  (8 MiB and 12 MiB); all destination SHA-256 values matched the sources;
- `8x` Ctrl+C/Ctrl+V created `PASTE8X.bin` (32 MiB), and the diagnostics panel
  showed `FIXED 8x`, eight completed workers and 100%; its SHA-256 matched;
- `1x` Drag&Drop created `DND1X.bin` (4 MiB) and `1x` Ctrl+C/Ctrl+V created
  `PASTE1X.bin` (4 MiB); both SHA-256 values matched;
- the target CM log contains the parallel marker/cache lifecycle for the three
  `8x` transfers at 22:10, 22:13 and 22:18. The `1x` format lists at 22:22 and
  22:23 contain only `FileGroupDescriptorW` and `FileContents`, with no cache
  marker or parallel job.

Evidence is under `artifacts\lab\beta57-explorer-transfer\`. The targeted
Windows client gate passed under
`artifacts\targeted-windows-client\20260903-205613\`; `git diff --check`
passed. Both VM installations match the runner and DLL hashes above. Production
was not changed.

The worktree intentionally remains dirty with the accumulated earlier beta
changes and unrelated user files. The next changed executable identity is beta
58.

## 2026-09-03 beta 56 native Print Screen routing

Beta 56 is the current local-only candidate:

```text
dist\MasterDesk-1.4.9-10-beta-56-2026-09-03-RDS-x86_64.exe
SHA-256 F83EC6EAACE4C3386010888F7F7E96748190FE88910AEDDA7C5062E917C4031F
librustdesk.dll E06E46F7207D685E8EA0D8FD281426493F767DA713EDE3AD1A6DEB6505DBDB8B
Flutter app.so 6EB1E913589CE43CEDEEE77E902750B532C24EA60701BE673A412C22F2C8E55F
runner 3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
```

The beta 55 runtime report proved that its Flutter/native-system-hotkey filters
did not cover the active default input path: `Input source 1` uses the global
`rdev` grab loop in `src/keyboard.rs`, which sent `Key::PrintScreen` to the peer
before Flutter saw the event. Beta 56 returns both Print Screen key-down and
key-up directly to the controller Windows from that grab callback before
`client::process_event()`. Alt is still observed normally, but the Print Screen
event itself is never sent to the controlled peer, so both `Print Screen` and
`Alt+Print Screen` are local-only. The beta 55 Flutter filter remains as the
equivalent guard for `Input source 2`.

The focused `windows_native_grab_keeps_print_screen_local_only` test passed,
the standard targeted Windows client gate passed, and `git diff --check`
passed. The pinned `rdev` Windows map confirms VK 44 (`VK_SNAPSHOT`) maps to
`Key::PrintScreen`. The cached beta 56 build completed with embedded beta 56
identity. A physical consuming-application check with FastStone on both
controller and controlled computers is still required before runtime PASS.

Production was not changed.

## 2026-09-03 beta 55 local Print Screen routing

Beta 55 is superseded and failed the physical FastStone runtime check:

```text
dist\MasterDesk-1.4.9-10-beta-55-2026-09-03-RDS-x86_64.exe
SHA-256 298FE0DB628F59416B38FDBC2AE371A7FB0F38361833ECA50FDC6C056D72CDF9
librustdesk.dll 518FEA3671227E37E7E4489AF1BB5AC6A47A92067A09D425D51DB72657592DCE
Flutter app.so 6EB1E913589CE43CEDEEE77E902750B532C24EA60701BE673A412C22F2C8E55F
runner 3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
```

Beta 55 attempted to keep both `Print Screen` and `Alt+Print Screen` on the
Windows controller in the native system-hotkey hook and Flutter input path.
The user's physical FastStone check proved both shortcuts still activated
FastStone on the controlled peer. The missed default `Input source 1` route is
fixed in beta 56; do not use beta 55 for this behavior.

The focused Flutter regression suite passed 15/15 and the standard targeted
Windows client gate passed. The build log is
`artifacts/incremental-beta/20260903-153912/build-beta-55.log`; `git diff
--check` passed. A physical consuming-application runtime check with Windows
clipboard/FastStone is still required before calling the behavior a runtime
PASS.

The beta 54 Explorer transfer diagnostics below remain valid and unchanged.
Production was not changed.

## 2026-09-03 beta 54 Explorer transfer diagnostics

Beta 54 is the current local-only candidate:

```text
dist\MasterDesk-1.4.9-10-beta-54-2026-09-03-RDS-x86_64.exe
SHA-256 FEAAEC2FA167CDD44AFB8E72D29BF12B82BAB64D211804BB71FB546B3302AB86
librustdesk.dll C1C5A41D81A8CDA570B2B41891C317118D589AEA6C9A7D30D706E7AFD13C3CFC
Flutter app.so A57490F7848D63139A400FFFFA1ED6164C426386216155C454D19596D32B518E
runner 3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
```

Beta 54 adds a Viewer-side `Диагностика передачи` panel for Explorer
parallel-cache jobs. The toolbar transfer button shows/hides it. The panel owns
the global Auto/1x/2x/4x/8x selector and shows the same progress, speed, ETA,
worker, queue and speed-graph details as File Manager. Negative Explorer cache
job IDs are materialized in Flutter and completed or failed from the Rust job
lifecycle.

The mode contract is intentional:

- `1x` is the unchanged standard Explorer clipboard path, without parallel
  cache or a diagnostics job. A 1 MiB Ctrl+C/Ctrl+V copied B-to-A with identical
  source/destination SHA-256
  `30E14955EBF1352266DC2FF8067E68104607E750ABB9D3B36582B8AF909FCB58`;
- `8x` displayed `FIXED 8x`, opened and used eight worker connections, and
  completed a 512 MiB cache with all 64 chunks acknowledged;
- beta 52 remains the final physical functional acceptance for 128-file
  Ctrl+C/Ctrl+V, file Drag&Drop, folder Drag&Drop and overlapping-drag
  serialization. Beta 54 does not change those backend mechanisms.

Both VM10-A and VM10-B have the exact beta 54 runner/DLL/app.so hashes above and
running services. Evidence is under
`artifacts\lab\20260903-beta54-transfer-panel\`; beta 52 physical evidence is
under `artifacts\lab\20260903-beta52-final\`. The beta 54 host driver could list
both visible mstsc windows but could not foreground VM10-B, so beta 54 GUI input
is diagnostic VM input, not a new host-driven physical acceptance.

This Explorer transfer/diagnostics task is closed. Do not create beta 55 or
reopen clipboard/OLE routing without a new concrete failure. The older beta 52
and beta 44 sections below are retained as historical evidence and their
`current`/`unfinished` wording is superseded by this section.

### Beta 54 implementation map

- `flutter/lib/models/file_model.dart`: `JobController.tryUpdateJobProgress()`
  parses `parallel_stats` before job lookup and creates an Explorer transfer job
  for an unknown negative ID. `JobProgress.isExplorerClipboardTransfer` is the
  UI discriminator. Speed samples feed the graph.
- `flutter/lib/desktop/widgets/explorer_transfer_panel.dart`: Viewer overlay,
  global mode selector, transfer cards, worker bars, completion summary and
  speed sparkline. It intentionally lists only negative Explorer cache jobs.
- `flutter/lib/desktop/widgets/remote_toolbar.dart`: transfer toolbar button,
  visible/active state and hidden-panel activity indicator.
- `flutter/lib/desktop/pages/remote_page.dart`: positions the diagnostics panel
  over the right side of the Viewer without changing the remote canvas.
- `src/client/io_loop.rs`: uses the real single source filename for clipboard
  telemetry, emits the final progress plus `job_done`, emits `job_error` on
  cache failure/fallback, and releases the pending Viewer cache on cancel.
- `flutter/test/file_transfer_telemetry_test.dart`: verifies that negative
  Explorer telemetry creates, updates and completes a visible job.

Do not remove the two `Fixed(1)` gates around
`set_parallel_file_cache_enabled()`. They implement the accepted product
contract: `1x` uses the old standard Explorer clipboard mechanism. Modes
`Auto/2x/4x/8x` advertise `MasterDeskParallelFileCacheV1` and use the new cache.
The selector writes the existing global `kOptionParallelFileTransferMode`, so a
new clipboard generation reads the chosen value without another settings path.

### Beta 54 validation and evidence map

- Build log:
  `artifacts/incremental-beta/20260903-125010/build-beta-54.log`; it contains
  `BUILD_SUCCESS`, exact component hashes and package SHA-256. Flutter AOT had
  completed before an idle wrapper was stopped; do not rebuild beta 54.
- Targeted build gate:
  `artifacts/targeted-windows-client/20260903-125010/`.
- Flutter telemetry tests: 3/3 passed. Targeted Dart analysis found no errors;
  remaining messages were pre-existing deprecation/info findings.
- Exact A/B installed attribution:
  `artifacts/lab/20260903-beta53-transfer-panel/upgrade-beta54-A.json` and
  `upgrade-beta54-B.json` (the directory name predates beta 54).
- `1x` source/destination proof:
  `artifacts/lab/20260903-beta54-transfer-panel/verify-source-fixed1-b.json`
  and `verify-fixed1-legacy.json`.
- Final `8x` telemetry:
  `artifacts/lab/20260903-beta54-transfer-panel/masterdesk_rCURRENT-B-final.log`;
  transfer `efe12a49-83b1-4a87-bbe1-7e25ebf596a5` completed 512 MiB in 16.390 s
  with eight open connections and 64 completed chunks.
- `git diff --check` and syntax parsing of the diagnostic PowerShell helpers
  passed. No production environment was changed.

Lab note: exact beta 54 DLL/app.so deployment reused the existing authorized A
and B scheduled-task hooks, then restored both original hook scripts. Direct
VM-B MCP was sufficient for diagnostic GUI operation. The host RDP driver listed
one visible mstsc window for each VM but returned foreground HWND 0 on capture;
under the lab skill that makes a new host-driven physical run inconclusive, not
a product failure. VMware `captureScreen` showed the locked console rather than
the active RDP user session and should not be used as Viewer GUI evidence.

The worktree intentionally remains dirty with the accumulated beta 20-54 work
and unrelated user files. Never reset, clean or reconstruct it from Git history.
The next changed executable identity is beta 55, but only after a new confirmed
code change; logging, documentation or evidence collection alone does not earn
a beta number.

## 2026-09-03 Explorer clipboard/Drag&Drop completion

Beta 52 is the current local-only candidate:

```text
dist\MasterDesk-1.4.9-10-beta-52-2026-09-03-RDS-x86_64.exe
SHA-256 BBD9247A72FD80737A8D69C96F51CDCD28E79AF7DE1F09E71680B9F7809CC3E1
librustdesk.dll 12024C4063FCB0E4DEFD80B6DC9CC69999CA5F62CE6E4DB351ABE5230652C2FC
Flutter app.so 6EF9E24FF0DFBD6ABC05E297D014273BFC053F762117BB3847C6990B8B05AAB2
runner 3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
```

The beta 51 wait-before-paste implementation fixed the folder race but allowed
a second drag gesture to replace the single pending cache wait. Logs from the
user-observed 512 MiB case proved two gestures 5.08 seconds apart: the first
cache completed while the second registration owned the wait state, causing a
false `superseded` error even though the first data transfer continued. Beta 52
serializes Viewer drop gestures in Flutter, shows `Preparing` while the full
parallel cache is populated, and defensively refuses a second Rust registration.
Internal file/chunk parallelism remains unchanged.

Final host-driven RDP acceptance on beta 52:

- two 512 MiB drags three seconds apart produced exactly one transfer ID; the
  first file completed with 4 streams, 64/64 range ACKs, cache ready in 16.1 s,
  and exact SHA-256
  `4819868C543A63084E4AA8AC111B67B76920E32BACA50184494EC3D745364110`;
  the second gesture did not supersede it and no second destination appeared;
- Explorer Ctrl+C/Ctrl+V copied `SMALL_128_B44`: 128/128 files, 32 MiB total,
  zero path/length/SHA mismatches;
- folder Drag&Drop copied `DND_FOLDER_B50`: 8/8 files, 512 KiB total, zero
  path/length/SHA mismatches.

Both VM10-A and VM10-B are installed with the exact beta 52 DLL/app.so hashes
above and have running services. Evidence is under
`artifacts\lab\20260903-beta52-final\`, especially `physical-overlap-final`,
`physical-128-clipboard`, `physical-folder-dnd`, and the final installed-hash
JSON files. The large-file delay is deliberate wait-before-paste cache filling,
not a backend stall; the Viewer now provides a `Preparing` indication during it.

**Updated:** 2026-09-03. This is the authoritative volatile handoff. Do not use
old “current beta” statements in the historical `CODEX_*` or
`PROJECT_CONTEXT.md` files.

## Repository state

The last commit containing MasterDesk feature work is `d6ae829` (“prepare
MasterDesk beta 19 release”, 2026-08-21). All beta 20 through beta 44 work is in
the current dirty worktree; do not reset or reconstruct it from the commit.

Latest candidate:

```text
dist\MasterDesk-1.4.9-10-beta-44-2026-09-01-RDS-x86_64.exe
SHA-256 DDACC4BBE3F316D957D684466867EAC7E035B5AA0FAF9B23D66EB4DD85ABD332
length 26976768; embedded 1.4.9-10 beta 44; build date 2026-09-01 01:59
```

It is an unsigned, local-only candidate. It was not published and production
was not changed for beta 44. Beta 45 is the next changed EXE identity.

The beta 44 build/installed attribution for the current D&D test is:

```text
portable package       DDACC4BBE3F316D957D684466867EAC7E035B5AA0FAF9B23D66EB4DD85ABD332
installed runner       3ED4F1C2D0DFEDEE42FF6F630AEBF3E8A6BA290AB1D1A25ADB2A8FDD76ABCB30
installed identity     1.4.9-10 beta 44; build date 2026-09-01 01:59
```

The cached incremental packaging completed successfully once. Its required
targeted checks passed; the build log is
`artifacts\incremental-beta\20260901-015711\build-beta-44.log`. No broad/full
regression was run or is claimed.

Beta 44 was installed on VM10-B through the GUI update path. Installed identity
and running service evidence is in
`artifacts\lab\20260901-022806-682\vm-B\probe-status.json`. VM10-B controlled
VM10-A; VM10-A remained the beta 39 target and observation-only. The Viewer was
connected to A's `MasterDeskTest` RDP session.

## What currently works

- Normal B-to-A Viewer connection, RDP session selection, screen, mouse and
  keyboard have prior PASS evidence.
- Physical layout synchronization was accepted by the user after beta 19:
  mismatched EN/RU starts converge and switch together without the old EN loop.
- The production registration reconnect lease root cause was fixed earlier:
  a new process nonce for the same authenticated installation no longer waits
  behind the old 45-second lease. Do not reopen or replay that investigation.
- Incorrect client-clock handling exists in the dirty tree: server
  `CLOCK_MISMATCH` sets `registration-clock-error`; the UI shows “Possibly
  incorrect date and time…” and does not silently rotate an ID. The user's real
  machine obtained a new ID after its clock was corrected. No separate runtime
  artifact for the warning dialog was found in this inventory.
- Beta 31 is the last fully evidenced parallel-transfer performance baseline:
  Auto B-to-A transfers of 965 MiB/150 MiB/965 MiB completed with exact hashes,
  reused four cached streams after idle and showed about 422-478 Mbit/s. Focused
  parallel tests passed 9/9. Evidence:
  `artifacts\gui-runs\20260825-beta31-final\`.
- The beta 31 physical Explorer Ctrl+C/Ctrl+V test copied an 8 MiB file B-to-A
  with exact SHA-256
  `E1CCFFA614D1F4E12192F06ADC4DA2E2B9527D6FFF78A5C5D031E7FA062CCE30`.
  The fix snapshots local/OLE `CF_HDROP` paths before advertising lazy remote
  formats.
- Beta 44's Viewer accepts a local Explorer drag and completes the actual file
  copy. The beta 43 automatic paste used raw uppercase `V`; the Windows legacy
  mapper synthesized Shift, so it sent Ctrl+Shift+V. The minimal fix in
  `flutter/lib/models/input_model.dart` uses the physical `VK_V` mapping.
- Beta 43 already supplied the underlying drop path: the `desktop_drop` plugin
  is registered in the child Viewer engine, the dependency patch forces
  `DROPEFFECT_COPY`, and CF_HDROP extraction passes `STGMEDIUM.hGlobal` to
  `DragQueryFile` with dynamic path buffers.

Install/update and identity/clock fixes from the dirty tree must remain intact,
but they are not the active diagnostic path. Do not rewrite those areas while
fixing D&D unless new evidence directly points there.

## Most recent D&D result (do not reopen)

The beta 43 **Viewer Drag&Drop from VM10-B local Explorer into VM10-A
Explorer** defect is localized and fixed.

The beta 43 read-only VM10-A probe proved that the remote OLE object itself was
structurally valid: CLR type and `ToString()` were
`System.Windows.Forms.DataObject`; `FileGroupDescriptorW` and `FileContents`
were present; `FileDrop` was absent, as expected for a virtual file; the
descriptor was a 596-byte `MemoryStream` with `cItems=1`, attributes `0x20`,
size 1048576 and flags `0x00004024`. The filename was a leaf name, not a local
VM10-B path. The descriptor intentionally omitted `FD_FILESIZE`, so Explorer's
`dw_flags=1` size request was expected.

The first broken transition was the automatic paste in
`InputModel.pasteClipboardFilesAt()`: it sent raw uppercase `V`. The Windows
legacy mapper used by the remote input path interpreted that as Shift+V, turning
the requested Ctrl+V into Ctrl+Shift+V. Beta 44 now sends `VK_V`, matching the
working physical-key path. The narrow Flutter regression test passed.

One host-driven RDP drag on beta 44 copied:

```text
source B C:\MasterDeskLab\clip-src-b39\DND_B44_PASS_20260901_0233.bin
target A C:\MasterDeskLab\dnd-dst-b39\DND_B44_PASS_20260901_0233.bin
length   1048576
SHA-256  FBBAB289F7F94B25736C58BE46A994C441FD02552CC6022352E3D86D2FAB7C83
```

The destination path, length and hash match; Explorer stayed responsive and the
Viewer remained connected. Input was host-driven RDP mouse/keyboard through the
visible VM10-B mstsc window, not manual physical input. Evidence is under
`artifacts\lab\host-rdp-input\20260901T020500-beta44-pass\`, especially
`host-input-beta44-final-drag.json`, `beta44-file-verification.json`, and the
`final-pre-drag`/`final-post-drag` screenshots.

The strict logging gate is nevertheless **INCONCLUSIVE**. During the successful
01:37 transfer, fresh B/A logs contain format-list advertisement but no logged
`FileContents` request. A separate fresh clipboard probe produced five matching
`dw_flags=1` size requests and responses on each side, zero `dw_flags=2`
requests, then target `GetData("FileContents")` returned null. The current code
also has no log emitted by Explorer for destination write/finalize/completion.
Therefore do not label the beta 44 run a strict PASS even though the functional
copy is proven.

The missing `dw_flags=2`/write-finalize telemetry is a known evidence limitation,
not a reason to reopen the fixed uppercase-`V` diagnosis. A plus cursor or
`dw_flags=1` alone remains insufficient.

## Current unfinished task

The next task is **parallel B-to-A file transfer initiated from Windows
Explorer through the Viewer**, covering both entry paths:

1. Drag&Drop from local Explorer on VM10-B into remote Explorer on VM10-A.
2. Ctrl+C in local Explorer on VM10-B followed by Ctrl+V in remote Explorer on
   VM10-A.

“Parallel” means overlapping Explorer copy operations/streams, not merely a
multi-file selection and not the MasterDesk File Manager Auto-transfer path.
The beta 31 965/150/965 MiB Auto baseline proves the core parallel engine but is
not proof for these Explorer/OLE paths on beta 44.

Start from the installed beta 44 on VM10-B and beta 39 on VM10-A. Preserve the
current dirty tree and VM state; do not reset snapshots or build beta 45 before
a concrete failure is localized. Use `$masterdesk-rdp-lab` and the visible host
mstsc window for all B-to-A mouse/keyboard input. VM10-A remains
observation-only. Label the input `host-driven RDP mouse/keyboard`, not manual
physical.

Already proven; do not repeat as research:

- beta 31 copied one 8 MiB Explorer Ctrl+C/Ctrl+V file B-to-A with exact hash;
- beta 44 copied one 1 MiB Explorer Drag&Drop file B-to-A with exact path/hash;
- `InputModel.pasteClipboardFilesAt()` must keep `VK_V`;
- the virtual-file descriptor/stream contract is structurally valid;
- beta 44's strict D&D trace remains INCONCLUSIVE because accessible logs omit
  `dw_flags=2` and Explorer-owned write/finalize events.

What is not yet proven is that beta 44 can sustain two or more overlapping
Explorer-initiated transfers without serialization bugs, stream-ID/cached-stream
cross-talk, wrong file contents, hangs, disconnects or corruption.

## Next concrete step

1. Read-only verify beta 44 identity/service on VM10-B, beta 39 on VM10-A, the
   existing Viewer/RDP session and fresh log baselines. Do not rebuild.
2. Reuse or create the smallest deterministic corpus that keeps two operations
   overlapping; record each source path, length and SHA-256 before input.
3. Run one narrow mixed overlap: start a host-driven Drag&Drop transfer, then
   while it is active start a separate Explorer Ctrl+C/Ctrl+V transfer through
   the same Viewer. Do not add File Manager or other transfer paths.
4. Verify every exact target path, length and SHA-256; confirm both Explorers
   remain responsive and the Viewer stays connected.
5. Correlate only the fresh time window in Viewer/CM logs and identify the first
   missing or corrupted transition if either job fails. Preserve screenshots,
   input JSON, hashes and log tails in one new `artifacts\` directory.
6. Only after a concrete defect is localized, make the smallest fix, run narrow
   tests and assign the next changed EXE identity once.

PASS requires all overlapping jobs to finish at the intended paths with exact
sizes/hashes, no Explorer hang, no Viewer disconnect and sufficient fresh
per-job evidence to distinguish the streams. Functional file evidence and the
known logging limitation must be reported separately.

## Other pending runtime work

These remain separate and are not active while the parallel Explorer-transfer
task above is open:

- interrupted large transfers currently resume around 2 Mbit/s instead of the
  initial roughly 110 Mbit/s;
- after closing and reopening the remote session/File Manager, the resumable job
  is not reliably offered.

The dirty tree contains parallel resume offsets and persisted receiver digests,
but the required same-session and reconnect runtime matrix has not passed on the
latest candidate. Do not infer success from the beta 31 non-resume throughput.

Beta 43 also contains a local Alt+PrintScreen hook exception in
`src/platform/windows.cc`: Alt+PrintScreen should remain on the controller so
FastStone captures the active MasterDesk window, while ordinary PrintScreen
continues to the target. This has not received the required physical FastStone
runtime check.

## Changed product files in the dirty worktree

Flutter/UI and runner:

```text
flutter/lib/consts.dart
flutter/lib/desktop/pages/file_manager_page.dart
flutter/lib/desktop/pages/install_page.dart
flutter/lib/desktop/pages/remote_page.dart
flutter/lib/main.dart
flutter/lib/models/file_model.dart
flutter/lib/models/input_model.dart
flutter/lib/models/server_model.dart
flutter/lib/web/bridge.dart
flutter/windows/runner/flutter_window.cpp
flutter/windows/runner/main.cpp
flutter/test/file_transfer_telemetry_test.dart (untracked)
flutter/test/viewer_file_drop_input_test.dart (untracked)
```

Clipboard/protocol/shared submodule:

```text
libs/clipboard/src/platform/windows.rs
libs/clipboard/src/windows/wf_cliprdr.c
libs/hbb_common/protos/message.proto
libs/hbb_common/protos/rendezvous.proto
libs/hbb_common/src/config.rs
libs/hbb_common/src/fs.rs
libs/hbb_common/src/masterdesk_security.rs
```

Rust core/Windows/session/transfer:

```text
src/client.rs
src/client/io_loop.rs
src/core_main.rs
src/flutter.rs
src/flutter_ffi.rs
src/ipc.rs
src/lang/ru.rs
src/platform/windows.cc
src/platform/windows.rs
src/rendezvous_mediator.rs
src/server/connection.rs
src/ui_cm_interface.rs
src/ui_interface.rs
```

Build/lab:

```text
scripts/Build-CustomWindows.ps1
scripts/Build-IncrementalBeta.ps1
scripts/lab/Invoke-MasterDeskKeyboardGuest.ps1
scripts/lab/Invoke-MasterDeskRdpLab.ps1
scripts/Clear-MasterDeskWorkspaceJunk.ps1 (untracked)
scripts/Test-CodexWorkspaceReady.ps1 (untracked)
deploy/masterdesk-server/ (untracked server deployment source)
```

There are unrelated/unclassified untracked files and directories, including a
workspace ZIP, generated MSTSC assembly, a stray host file and a large
`Version 0.11.0.3 source code` tree. They were not deleted or incorporated.

## Production state

Production was not changed during beta 43 work. The exact verified/failed image
IDs, compatibility mode and port policy are maintained once in
[decisions.md](decisions.md#production-wss-remains-compatibility-first). The
reconnect root cause is closed and must not be retested unless new
contradictory evidence appears.
