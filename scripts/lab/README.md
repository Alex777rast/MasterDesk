# MasterDesk VMware runtime lab

Current cross-account state and next scenario work are documented in
`CODEX_HANDOFF.md` and `CODEX_NEXT_PLAN.md`. The existing candidate has fresh
isolated PASS results for Portable, Install, Service, and SingleGui. Wss remains
an application-protocol FAIL even though generic endpoints pass. Direct and
Relay must be implemented as real two-VM sessions before the corrected security
server can be considered for deployment.

The low-level lab entry point is `scripts/lab/Test-MasterDeskLab.ps1`. The
preferred two-VM entry point is `scripts/lab/Invoke-MasterDeskRdpLab.ps1`.
VMware paths, guest names, addresses, RDP user name, and snapshots stay outside
the repository in `D:\Vms\MasterDeskLab\lab-config.psd1`.

Set `MASTERDESK_LAB_PASSWORD` in the launching process. The scripts keep the
value in memory only and redact it from vmrun command records and captured
output. Do not put it in the config file, command line, documentation, or lab
artifacts.

## Current RDP topology

- VM A is `VM10-A` / `md-w10-a` / `192.168.7.14`. It is the controlled
  MasterDesk target.
- VM B is `VM10-B` / `md-w10-b` / `192.168.7.15`. It is the MasterDesk
  controller.
- Both VMs have `00-CLEAN-MASTERDESK-ON` and
  `00-CLEAN-MASTERDESK-OFF`. Routine preparation uses the ON snapshot.
- RDP files contain the address and user name only. They never contain a
  password or credential blob.

VMware remains responsible for exact snapshot restore, power, privileged
installation, hashes, probes, and artifacts. RDP is responsible for the
interactive desktop, MasterDesk connection UI, and real keyboard input.

## Preferred commands

```powershell
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Status
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Restore
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Deploy -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Install -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Prepare -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Open
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Test -ExePath .\dist\MasterDesk-candidate.exe -KeepVmState
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action IdentityTest -Vm A -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action PasswordTest -Vm All -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action InputTest -Vm All -ExePath .\dist\MasterDesk-candidate.exe
```

`Restore` reverts the selected VM(s) to `00-CLEAN-MASTERDESK-ON`, starts them,
and waits for TCP 3389. `Install` runs the isolated privileged Install scenario
on each selected clean VM and checks the outer package plus installed runner
hash. `Prepare` performs that install and opens password-free RDP files.

`Open` creates two windowed 900x700 mstsc sessions and records their process
IDs under `artifacts\lab\rdp\`. Run `Open` and `Test` from a persistently active,
visible Windows desktop. A background/disconnected task can establish RDP while
mstsc has no top-level window or while its window cannot receive real host
input. The runner checks WTS state/window handles and verifies a plain `A` in
remote Notepad before layout hotkeys. Missing physical input returns exit code
`2`/`INCONCLUSIVE`; it is never turned into a PASS or a MasterDesk failure.

`IdentityTest` uses `00-CLEAN-RDP-MCP-ON`, installs the candidate, restarts the
service three times in a non-interactive administrative guest context and
records every ID plus service/`--server` PID. Add `-UseCurrentPreparedState`
only when the exact candidate was already verified by the immediately preceding
Install result.

`InputTest` also uses the MCP baseline. After installation and reboot it opens
RDP first, then restarts Windows-MCP so DXGI capture does not retain a stale
display mode. The active RDP option and Connect button are located from live
Snapshot data instead of fixed Viewer coordinates. Evidence is written under
`artifacts\gui-runs\<timestamp>\`.

`PasswordTest` uses the same clean baseline and explicitly opens the installed
main GUI even when interactive background MasterDesk descendants already
exist. VM-B then connects without a supplied password. PASS requires the
temporary-password entry field to remain visible after five seconds and the
mandatory local-approval wait dialog to be absent. The test never clicks
Accept on VM-A and never reads or types the temporary password. With the
default `Both` approval mode, VM-A may still offer Accept as an alternative.

## Commands

```powershell
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Status
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Start -Vm A
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Stop -Vm B
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Reset -Vm A
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Reset -Vm B -SnapshotName 00-CLEAN-MASTERDESK-ON
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Deploy -Vm All -ExePath .\dist\MasterDesk-1.4.9-RDS-x86_64.exe
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Smoke -Vm All
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Scenario -Scenario Portable -Vm A -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Scenario -Scenario Install -Vm A -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Scenario -Scenario Service -Vm A -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Scenario -Scenario SingleGui -Vm A -ExePath .\dist\MasterDesk-candidate.exe
.\scripts\lab\Test-MasterDeskLab.ps1 -Action Scenario -Scenario Wss -Vm A -ExePath .\dist\MasterDesk-candidate.exe
```

`Start` uses headless VMware startup. `Stop` requests a soft guest shutdown.
`Reset` performs that soft stop and reverts to the VM's configured snapshot; it
leaves the VM powered off. `Deploy` starts the VM when necessary and copies the
EXE to `C:\MasterDeskLab\` using VMware Tools, without SMB or RDP.

`Smoke` starts the VM when necessary, waits for VMware Tools, checks guest
access, desktop session, MasterDesk service/processes, network, DNS and
ID/relay TCP/WSS endpoints, then collects MasterDesk logs and a VM screenshot.

## Targeted runtime scenarios

`Deploy` writes guest-side package and installed-payload hashes after copying the
EXE. Relative host paths are resolved from the caller's current PowerShell
location. Deploy never installs or launches the EXE. Every implemented scenario
requires an explicit `-ExePath`, selects its own baseline, resets the VM, boots,
deploys, and prepares all prerequisites; state left by an earlier scenario is
never a prerequisite. The current deterministic baseline matrix is:

| Scenario | VM / snapshot | Required initial state | Scenario preparation |
| --- | --- | --- | --- |
| Portable | A or B / `00-CLEAN-MASTERDESK-ON` | no service, installed EXE, or processes | deploy only |
| Install | A or B / `00-CLEAN-MASTERDESK-ON` | no service, installed EXE, or processes | deploy, then install under test |
| Service | A or B / `00-CLEAN-MASTERDESK-ON` | clean Windows | deploy and verified prerequisite install |
| SingleGui | A or B / `00-CLEAN-MASTERDESK-ON` | clean Windows | deploy and verified prerequisite install |
| Wss | A or B / `00-CLEAN-MASTERDESK-ON` | clean Windows with working network | deploy and verified prerequisite install |

If the required VM or snapshot is unavailable, scenario orchestration returns
`SETUP REQUIRED`/FAIL instead of selecting another baseline.

- `Portable` launches the deployed package without arguments in the interactive
  session. It requires a stable new portable process and verifies that service
  count/configuration and the installed executable hash do not change.
- `Install` runs the deployed package with `--silent-install` in the privileged
  VMware Tools context. It requires an observed installation effect, exactly
  one automatic/running service, a matching `--service` PID and the expected
  installed executable path. On PASS it records an installed-candidate hash
  marker for later scenarios.
- `Service` restarts the existing service, verifies a replacement `--service`
  PID and checks that state/PID remain stable across three samples.
- `SingleGui` issues two GUI launches in the interactive session and requires
  exactly one argument-less GUI in a desktop session, one service process, and
  no duplicate tray/server role in one session. Service-owned processes whose
  command lines are protected are classified by service PID and parent PID.
- `Wss` performs a verified prerequisite install, validates the outer package
  SHA-256 and the embedded installed-payload SHA-256, then performs an `N` to `Y`
  WebSocket transition, and looks for new candidate log evidence for the exact
  `wss://hbbs.masterdesk.online/ws/id` path. It also rejects insecure downgrade
  and immediate WebSocket errors, probes both TCP and WSS endpoints, and restores
  the previous WebSocket boolean state. A relay WSS handshake is tested, but an
  actual relay session is not claimed unless a remote connection is added later.
  Saved logs are analyzed offline into `wss-timeline.json` and
  `wss-diagnostic-summary.json`, separating DNS, TCP, TLS/Upgrade, `/ws/id`,
  application response, registration, reset/reconnect, and generic relay WSS.

Each scenario saves its criteria, process/service evidence, logs and screenshot
under the normal timestamped artifact directory. A missing prerequisite or
missing runtime evidence is a FAIL, never an assumed PASS.

## Planned scenarios

`Direct`, `Relay`, `CloneId`, `Update`, and `Full` are not implemented
yet. In particular, `CloneId` must separately capture the ID before cloning, the
clone ID before its first network connection, the ID after server connection,
simultaneous duplicate behaviour, local hardware identity inputs, server-side
handling and silent rotation. The observed offline ID change on a copied VM is
recorded as test motivation, not as a confirmed MasterDesk defect.

Keyboard layout synchronization has a dedicated two-VM runner:

```powershell
.\scripts\lab\Test-MasterDeskKeyboard.ps1
```

The RDP wrapper invokes this runner with VM B as controller and VM A as target.
It installs or verifies the exact candidate on both, disables WSS, opens a real
B-to-A session, uses the normal incoming-connection Accept action, and checks a
host-RDP `A`, controller Ctrl+Shift, controller Alt+Shift, target Alt+Shift, and
stuck modifier state. It does not store a connection password and restores both
normal snapshots unless `-KeepVmState` is explicitly requested for diagnosis.

The runner first proves that an ordinary host key travels through mstsc, VM B,
MasterDesk, and remote Notepad on VM A. If the host Windows session disconnects,
mstsc has no visible window, or the key does not reach A, the run is
`INCONCLUSIVE`, never a false layout PASS/FAIL. This replaces the old VMware HID
path, which was rejected as synthetic input by the guest/client stack.

Stdout contains compact `PASS`/`FAIL` lines only. Full vmrun output, guest JSON,
screenshots, and collected logs are stored under
`artifacts\lab\<timestamp>\`. A failure line includes its stage, exit code,
log path, and a short redacted tail.
