# Technical decisions

Only settled, high-impact choices belong here. Volatile implementation status
belongs in [current-state.md](current-state.md).

## Portable packages remain portable by default

**Decision:** Every no-argument `MasterDesk-*.exe` launch is portable, even
when MasterDesk is installed. It may compare embedded local identity and offer
the standard GUI **Update** action, but may not query/update/install
automatically. There is no `*-install.exe` product.

**Why:** Earlier automatic `.5`/`.6` startup routing created duplicate GUI/server
processes and ambiguous ownership. Explicit UI action preserves user control
and one machine server.

**Rejected:** filename-driven installer mode and automatic startup update.

## Portable GUI attaches through a restricted compatibility pipe

**Decision:** A newer portable GUI attaches to the installed `--server` through
the protected versioned `_gui_compat` IPC pipe. Main IPC keeps exact-executable
authorization. The compatibility allowlist never returns the machine password
verifier or protected API/key options.

**Why:** Starting a second portable host server would register the same machine
twice; relaxing main IPC would expose privileged state.

**Rejected:** a second `--server`, globally weakening main IPC, or copying
protected config into the portable process.

## Service supervises one interactive-session server

**Decision:** LocalSystem remains the privileged supervisor, while capture and
input run in one verified Console/RDP `--server` child on
`winsta0\default`. Session replacement uses an explicit ready/go handoff.

**Why:** Session 0 is noninteractive, and overlapping old/new children caused
stale IPC, password authority and wrong-desktop capture races.

**Rejected:** capture/input in the service desktop and fire-and-forget RDP
process replacement.

## GUI testing uses RDP plus interactive Windows-MCP baselines

**Decision:** Preserve the original snapshots and use separate
`00-CLEAN-RDP-MCP-ON/OFF` snapshots for repeatable GUI tests. MCP runs as the
interactive user with separate bearer tokens and host-only firewall access.

**Why:** VMware console automation was unreliable, and Session 0 MCP cannot
observe or operate the user desktop.

**Rejected:** reinstalling MCP for every test, storing credentials in the repo,
or running MCP as a Windows service.

## Synthetic input is not proof of a physical hook

**Decision:** Use MCP for ordinary GUI automation, but require one user-operated
physical action for low-level keyboard hooks, Explorer clipboard chords and OLE
D&D when synthetic input does not traverse the same path.

**Why:** Host SendKeys/MCP/VMware HID attempts have skipped hooks or failed to
reach the Viewer while the product path remained unclassified.

**Rejected:** calling an MCP shortcut PASS/FAIL evidence for a physical hook.

## Build identity is generated, monotonic and consistent

**Decision:** Build scripts generate the next beta/date filename and inject the
same identity into Rust, About, registry and update comparison. Mixed builds
write a manifest with Rust DLL, Flutter AOT and bridge hashes.

**Why:** Renamed or mixed-cache binaries make runtime evidence impossible to
attribute.

**Rejected:** hand-renaming an EXE or packaging stale Flutter/Rust components.

## Validation is incremental and evidence-driven

**Decision:** Use focused tests, cached incremental packaging and one applicable
VM scenario before a final/full build. Keep verbose evidence in `artifacts/`.

**Why:** Full Windows/Flutter builds and the complete VM matrix are expensive
and were obscuring the first failing stage.

**Rejected:** routine `cargo clean`, cache deletion, full rebuild after every
Rust edit, and repeating already-passing unrelated runtime tests.

## Clipboard files snapshot source state before advertisement

**Decision:** Snapshot `CF_HDROP` file paths before advertising
`FileGroupDescriptorW`/`FileContents`, and keep descriptor/content state stable
for lazy Explorer requests.

**Why:** Explorer reads OLE file data later. Referring back to mutable local
clipboard ownership caused hangs or missing copies.

**Rejected:** reading live `CF_HDROP` again for every remote content request.

## Parallel transfer negotiates and falls back safely

**Decision:** New peers may negotiate the parallel engine with Auto or fixed
1/2/4/8 stream policy. Unsupported peers and explicit 1x/off remain compatible
with the legacy path; worker/negotiation failures must be logged and fall back
without corrupting the destination.

**Why:** Multiple authenticated data streams materially improve large-file
throughput while compatibility and recoverability remain mandatory.

**Rejected:** unconditional parallel-only transfer or hidden unlogged fallback.

## Explorer 1x remains the native legacy clipboard path

**Decision:** The global Explorer/File Manager stream selector keeps `1x` as an
explicit legacy mode. For Explorer Ctrl+C/Ctrl+V and Drag&Drop, `1x` does not
advertise `MasterDeskParallelFileCacheV1`, does not pre-fill the parallel cache
and does not create a parallel diagnostics job. `Auto`, `2x`, `4x` and `8x` use
the negotiated parallel-cache path and may appear in the Viewer diagnostics
panel.

**Why:** Users need a compatibility escape hatch that reproduces Windows'
standard virtual-file clipboard behavior without MasterDesk's parallel cache.
Runtime beta 54 evidence proves both the unchanged 1 MiB legacy copy/hash path
and the eight-worker 512 MiB parallel path.

**Rejected:** implementing `1x` as a one-worker instance of the parallel cache,
because that changes timing and OLE behavior instead of preserving legacy
compatibility.

## Registration clock errors are explicit and do not allocate an ID

**Decision:** A signed registration rejected for clock skew returns a distinct
`CLOCK_MISMATCH`; the client exposes a date/time warning and does not treat it
as permission to rotate/allocate another ID.

**Why:** A real reinstalled PC with a clock two hours behind looked offline and
could not obtain the correct identity; after correcting time it registered.
Generating more IDs would hide the cause and worsen duplicate identity state.

**Rejected:** generic offline status or automatic ID rotation on timestamp
failure.

## Production WSS remains compatibility-first

**Decision:** Keep the verified production image
`sha256:bada4754be4c41e5fef6cc9ce8540c7c13d19a93a36eb44969df569d3f2049a1`
in N/N compatibility mode. External native 21118/21119 stay blocked and WSS is
exposed through Caddy/443. Strict relay remains disabled.

**Why:** Registration/reconnect/routing canaries pass on this image; a prior
strict image failed. Generic TCP/TLS success is not a MasterDesk canary.

**Rejected:** the failed image
`sha256:7d6bc23de9290baa3404c248b671b5dab89e797d5198a3f73167ebda8aa3707f`
and enabling strict relay without a separately authorized, backed-up and
rollback-tested production change.
