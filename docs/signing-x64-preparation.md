# x64 signing preparation

Status: local preparation, **not Foundation approval and not a signed release**.
The Foundation acknowledged the project application on2026-11-06; approval is
pending. Reviewed sources are public on `codex/x64-signing-source-20261106`.
The current scope is Windows x64 Flutter only. Published beta105, its GitHub
tag/assets, website, API and mirrors must remain unchanged. x86/Sciter and
WinPE images are excluded. No credentials belong in source or review artifacts.

## What is prepared

- Manual GitHub-hosted unsigned proof workflow, read-only repository access,
  no source push, no signing request and no GitHub/site publication.
- Source gate: exact tracked inputs, clean root and recursive submodules,
  private-file/high-confidence credential indicators reported by path only.
  This guard is not a complete secret/security/license review.
- New-beta filename and PE product/version/company metadata for owned payload
  files and the outer package. Unsigned outputs only; signed files, beta105,
  third-party filenames and paths outside build outputs are rejected.
- Preserved upstream copyright strings plus bundled NOTICE and PRIVACY.md.
- Binary inventory, ownership scope, final unsigned hashes and a draft
  application outline below. It is not a full SBOM/license clearance.

## Remaining decisions and review before any public source push

1. Review the existing accumulated product changes and required untracked
   sources, including `install_import.rs`, Flutter helpers and hbb_common.
   Do not commit the whole dirty worktree. Exclude lab credentials, logs,
   deployment secrets, VM files, private configs and unrelated changes.
2. Publish reviewed corresponding submodule source and root source only with
   explicit owner permission. Use new commits/tags; never rewrite beta105.
   Source provenance must identify the actual build commit, not just a base.
3. Review all Rust/Flutter/native transitive dependencies, their licenses,
   available source and notices. Custom engine archive is pinned to SHA256
   `EC8CABF36EE4FF24C8D98DE25B00E70781EB03876265AEE84D0FE554A110036E`;
   a changed upstream `main` asset fails closed rather than silently changing
   the runtime. No existing local cache is cleared by this preparation.
4. Verify maintainer MFA, review/access controls and signing roles. Actual
   account/certificate settings have not been inspected or changed.
5. After publishing the reviewed source, manually run the unsigned preparation
   workflow on that branch with a beta newer than every existing release.
   Local proof beta106 is already reserved; the next hosted candidate starts
   at108 or higher: local106 and the built-but-not-uploaded hosted107 are
   reserved, never reissue a different binary under either identity.
   All steps use GitHub-hosted agents; application/native caches are not restored.
   Inspect the exact build, tests, inventory and artifact provenance.

Local helper checks (do not publish artifacts as signed):

```powershell
.\scripts\Test-MasterDeskSigningPreparation.ps1
.\scripts\Test-MasterDeskSigningSource.ps1 -ReportOnly `
  -OutputPath artifacts/signing/source-readiness.json
```

The hosted client gate uses `Test-CustomDefaults.ps1 -ClientOnly`, retaining
client source, Rust defaults/IPC/update and portable checks. Server deployment
and API-service checks remain enabled by default in the full defaults gate and
in `Test-ServerDefaults.ps1`; they are explicitly NOT_RUN in client-only CI.
No private deployment files need publication. `Test-DefaultsScope.ps1` checks
the separation and negative fixtures before the expensive hosted build.

An optional local new-beta verification build can use the existing caches:

```powershell
.\scripts\Build-CustomWindows.ps1 -SkipVcpkg -SkipFlutterSetup `
  -IncrementalRustOnly -BetaNumber <new-beta> -PrepareSigning
.\scripts\New-MasterDeskSigningInventory.ps1 -BetaNumber <same-beta> `
  -OutputDirectory artifacts/signing/evidence
```

That local build is NOT eligible hosted-build provenance. Do not submit it
as though GitHub Actions had produced it. The source gate should currently
report NOT_READY while source/submodule changes remain uncommitted.

For beta106+ the wrapper also keeps PE metadata consistent on ordinary x64
builds, so a cached runner cannot retain the previous beta. -PrepareSigning
additionally requires the pinned custom-engine archive on full setup; it does
not enable any certificate, upload, automatic install or update.

## Draft application outline — review, do not send automatically

- Project: MasterDesk, Windows x64 Flutter remote-support client.
- Maintainer/reviewer/signing approver: Alex777rast (GitHub).
- Source: https://github.com/Alex777rast/MasterDesk, explicit RustDesk fork.
- Shared fork: https://github.com/Alex777rast/MasterDesk-hbb-common.
- Declared main-project license: AGPL-3.0; transitive review still pending.
- Website: https://masterdesk.online/.
- Policies: SIGNING_POLICY.md and PRIVACY.md; public default-branch copies
  must be updated to the reviewed current source before applying.
- Purpose: authorized remote support on systems the operator owns or has
  permission to manage. Document ID/relay/API communication and installation
  choices; ask the Foundation to assess the use case and signed-upstream fork
  relationship. Do not claim prior approval or a guaranteed SmartScreen result.
- Proposed owned payload: MasterDesk.exe, libmasterdesk.dll,
  dylib_virtual_display.dll. Proposed outer package: generated
  MasterDesk-<version>-beta-<N>-<YYYY-MM-DD>-RDS-x86_64.exe.
- Unmodified upstream Flutter/plugins remain separate third-party components;
  do not re-sign them with a project certificate as if maintained here.

## After Foundation approval (separate explicit activation)

The present workflow deliberately has no signing submission. Review/configure
the Foundation project, artifact and origin policies, MFA/manual approver and
protected signing credentials. Never send a token in chat or put it in files.

The reviewed future chain must sign owned payload files first, verify each
signature/identity/timestamp, recompute payload hashes/manifest, package those
exact signed bytes, and sign/verify the outer EXE. The custom portable format
cannot be assumed to support automatic deep signing like an MSI. Check that
third-party files remain unchanged. Compute final public hashes only after
signing and require explicit release/site publication permission. Test the
downloaded package and installed copy; no SmartScreen guarantee follows merely
from a certificate or from passing local helper tests.

References: https://signpath.org/terms.html and
https://docs.signpath.io/trusted-build-systems/github.
