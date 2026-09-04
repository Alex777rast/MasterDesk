# Windows sessions, RDP and display capture

This document records the useful conclusions from the Windows/VMware work. Lab
addresses and commands are in [lab-environment.md](lab-environment.md).

## Console, RDP and Session 0 are different desktops

- The physical Console session and each RDP session have different Windows
  session IDs, window stations, foreground windows, keyboard layouts and
  display/capture state.
- The LocalSystem service runs in Session 0, which is noninteractive. A GUI,
  input hook, Windows-MCP process or capturer in Session 0 cannot validate the
  user's desktop.
- MasterDesk's service supervises one privileged `--server` child in the
  selected interactive session on `winsta0\default`. The Viewer can select
  `Console: <user>` or `RDP: <user> (running)`; that selection controls which
  desktop is captured and receives input.
- During Console/RDP handover the old child must exit before the replacement is
  released. The replacement session ID is verified to avoid stale IPC and
  capture from the wrong desktop.

This explains why the same machine can show Ready in one GUI while an incoming
connection sees another desktop or authorization path if process/session
ownership is wrong.

## Current capture path

On Windows `src/server/video_service.rs` creates normal monitor capture through
the portable-service capture client, which selects DXGI/GDI for the display in
the active interactive session. `libs/scrap/` supplies display enumeration and
capture support. The capturer is retained because recreation is expensive and
can cause prompts or visible resets.

Windows-MCP screenshots are separate evidence: they prove that MCP can capture
its own interactive RDP session, not that MasterDesk selected or captured that
same session. A MasterDesk runtime test must record both the selected Viewer
session and target evidence.

## RDP activation, minimization and disconnection

Reliable GUI automation needs an unlocked, rendered RDP session and a visible
host `mstsc` window:

- Opening RDP from a background/nonpersistent host task can establish the TCP
  session but lose the top-level window or produce a window that cannot receive
  host input.
- A minimized, disconnected or resumed RDP session can stop or reconfigure the
  render surface. Observed symptoms include black RDP windows, stale DXGI
  screenshots and input that never reaches the intended window.
- In the lab, restarting Windows-MCP after the final RDP activation fixes its
  stale DXGI state. The RDP window must then remain visible/unlocked for
  screenshot/click/typing evidence.
- VM10-B once required a VM reboot after an RDP black-screen state. That is lab
  recovery evidence, not proof of a MasterDesk capture defect.

Do not infer product failure from a black MCP/RDP frame or missing background
host input. Classify it as INCONCLUSIVE and restore a visible interactive
session first.

## Physical monitor disconnected / headless hosts

The codebase packages `libs/virtual_display/` and
`dylib_virtual_display.dll`, using the Windows Indirect Display Driver model.
The UI recognizes RustDesk IDD and Amyuni virtual displays. This is the intended
mechanism when Windows exposes no usable physical display.

Important limits:

- A disconnected monitor can make Windows remove or resize the display. A
  capturer cannot reliably capture a display that the selected session no
  longer enumerates.
- A virtual display must be installed, active and visible in the same selected
  interactive session; merely bundling the DLL does not create a display.
- The current VMware RDP/MCP baseline proves ordinary virtual-machine displays,
  not a real PC with a physically unplugged monitor. No current artifact proves
  the unplug/replug or IDD fallback scenario end to end.
- Privacy mode is a separate feature. Its legacy Windows magnifier capturer is
  single-monitor constrained and must not be presented as a general headless
  solution.

A future headless validation must record display enumeration before/after
unplug, driver/IDD state, selected Windows session, capture backend, resolution
and a nonblack changing frame.

## Approaches that worked

- RDP into both VMs, keep both sessions unlocked and select VM-A's running RDP
  session in the MasterDesk Viewer on VM-B.
- Run Windows-MCP as an interactive-user scheduled task, not a service.
- Restart MCP after the final RDP activation, then use live UI snapshots rather
  than hard-coded coordinates.
- For B-to-A tests, generate input only through VM-B/Viewer and use VM-A only to
  observe the result.
- Use user-operated physical keyboard/drag actions for low-level hooks and OLE
  paths that synthetic MCP input cannot prove.

## Approaches that did not prove the product path

- Background host-session SendKeys into `mstsc`: input did not reach Notepad;
  the result was correctly INCONCLUSIVE.
- VMware HID/synthetic shortcut injection for physical Alt+Shift/Ctrl+Shift:
  it bypassed or failed to trigger the low-level hook being tested.
- MCP Win+Space as proof of physical layout-chord detection: it can validate
  target layout application but not the controller's physical hook.
- Treating a plus/copy D&D cursor as file-transfer success: it proves only that
  the local OLE target accepted the drag.
- Safe Mode GUI validation over RDP: after reboot the VM lacked RDP and VMware
  guest services, so only reboot initiation/access-denied regression could be
  attributed; the postboot GUI test was infrastructure-INCONCLUSIVE.

## Current implementation status

RDS session selection/handover and normal B-to-A interactive capture/input have
previous PASS evidence. The current unfinished defect is not a black-screen
capture issue: the beta 43 Viewer renders and accepts a file drag, but Explorer
on the target never creates the file. See [current-state.md](current-state.md).
