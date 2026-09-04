# VMware/RDP/Windows-MCP lab

The lab is for local Windows client validation. It is not production and does
not authorize server deployment.

## Topology

| Role | VMware VM | Windows name | Address |
| --- | --- | --- | --- |
| controlled target | `VM10-A` | `md-w10-a` | `192.168.7.14` |
| controller/Viewer | `VM10-B` | `md-w10-b` | `192.168.7.15` |

Normal direction is B -> A. The VMware host address allowed to reach MCP is
`192.168.7.3/32`. The external configuration is
`D:\Vms\MasterDeskLab\lab-config.psd1`; VM-B's real VMX filename is the unusual
`D:\Vms\MasterDeskLab\VM10-B\VM10-A.vmx`.

The RDP/guest account name is `MasterDeskTest`/`masterdesktest` as represented
by the external config. Do not write its password into this repository or pass
it visibly on a command line. Lab scripts read `MASTERDESK_LAB_PASSWORD` from
the host User environment and redact it.

## Snapshots

Both VMs retain the original, never-overwritten snapshots:

- `00-CLEAN-MASTERDESK-ON`
- `00-CLEAN-MASTERDESK-OFF`

Both also have clean automation baselines with RDP and MCP but no MasterDesk:

- `00-CLEAN-RDP-MCP-ON`
- `00-CLEAN-RDP-MCP-OFF`

Use the MCP ON snapshots for GUI/input tests. Do not delete, rename or overwrite
either snapshot family.

Current wrapper nuance: `InputTest`, `PasswordTest` and `IdentityTest` select
the `Vm*SnapshotMcpOn` values. Plain `Restore`/other basic actions select the
external `Vm*SnapshotRdpOn` values, which currently refer to the original
MasterDesk snapshot family. Check the action and config before any revert.

## Windows-MCP

Windows-MCP 0.8.5 runs in each unlocked interactive RDP session through a
hidden interactive-logon scheduled task. It is not a Session 0 service.

- A: `http://192.168.7.14:8000/mcp`
- B: `http://192.168.7.15:8000/mcp`
- Codex names: `masterdesk_vm_a`, `masterdesk_vm_b`
- token variables: `MASTERDESK_VM_A_MCP_TOKEN`,
  `MASTERDESK_VM_B_MCP_TOKEN`
- exact allowlist: Screenshot, Snapshot, Click, Type, Shortcut, Wait, WaitFor,
  App, Process

Use canonical `/mcp`, not `/mcp/`: the redirect can lose Authorization. Port
8000 is firewalled to the VMware host only; an unauthenticated probe should
return 401. Tokens belong only in host User environment variables or Credential
Manager, never in repository/config/artifacts.

MCP availability can require restarting Codex after its server configuration
changes. It also requires the VM user session to remain unlocked and rendered.

## Entry points

Preferred compact wrapper:

```powershell
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 -Action Status -Vm All
```

Supported actions in the current script are:

- `Status`: VM/RDP state.
- `Restore`: revert/start the configured basic snapshot; heed the snapshot
  nuance above.
- `Deploy`: copy the exact EXE into `C:\MasterDeskLab`; it does not install or
  launch it.
- `Install`: privileged install scenario and hash verification.
- `Prepare`: install and prepare RDP.
- `Open`: open password-free, windowed `mstsc` files; credentials are acquired
  outside the repository.
- `Test`: low-level lab scenario.
- `InputTest`: clean MCP baselines, install, active RDP, B-to-A mouse/text/layout
  test.
- `PasswordTest`: verify the temporary-password prompt without reading or
  typing the password and without clicking Accept on A.
- `IdentityTest`: record ID, service PID and `--server` PID across three service
  restarts.
- `DiagnosticDll`, `Trace`, `ReconnectTrace`: narrow diagnostics on an existing
  prepared state; use only when the active task requires them.

Low-level scenario runner: `scripts\lab\Test-MasterDeskLab.ps1`. MCP helpers
install/restart/probe/call the server and capture guest state. Read
`scripts\lab\README.md` for script parameters, but prefer this file for current
snapshot/MCP policy because some old README examples predate the MCP baseline.

## Typical clean GUI scenario

```powershell
$exe = Resolve-Path '.\dist\MasterDesk-<exact-beta>.exe'
.\scripts\lab\Invoke-MasterDeskRdpLab.ps1 `
    -Action InputTest -Vm All -ExePath $exe
```

The wrapper restores the MCP baselines, installs the exact candidate, activates
RDP, restarts MCP after final activation, selects A's running RDP session in the
Viewer on B, and stores evidence below
`artifacts\gui-runs\<timestamp>\wrapper\input-test`.

For iterative testing of an already prepared state, use the applicable action's
`-UseCurrentPreparedState`/`-KeepVmState` support only after verifying hashes and
VM roles. Never assume the newest file in `dist` is the installed binary; verify
the installed EXE and DLL hashes.

## Artifacts

- `InputTest`/`PasswordTest`: `artifacts\gui-runs\<timestamp>\wrapper\...`
- other wrapper actions: `artifacts\lab\<timestamp>\rdp\...`
- current manual runtime investigation may use a named folder such as
  `artifacts\lab\beta43-runtime\`.

Evidence should include exact candidate/installed hashes, VM/session identity,
foreground window, service and MasterDesk process state, timestamps,
screenshots and compact PASS/FAIL/INCONCLUSIVE result. Secrets are forbidden.

## Reliability limits and recovery

- RDP must be visible, unlocked and active. A background or minimized `mstsc`
  window may be black or ignore input.
- Restart MCP after final RDP activation to avoid stale DXGI capture.
- MCP synthetic keyboard input is not authoritative for physical low-level
  hooks; D&D and some clipboard tests require the user to perform the physical
  action manually.
- The user prefers to perform required physical copy/paste/drag actions
  manually to keep automation efficient. Prepare the exact source/target
  windows and ask for one concise action rather than attempting repeated
  synthetic substitutes.
- Safe Mode normally removes RDP and VMware guest services; postboot GUI
  validation is therefore INCONCLUSIVE until the VM is recovered.
- If RDP remains black after reconnect, verify VM power/session state, then use
  the least destructive recovery. A VM reboot has recovered VM10-B before.
- Do not revert a VM while an uncollected manual result or required runtime log
  exists.
