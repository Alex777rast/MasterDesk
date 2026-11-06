# Current public source state

## 2026-11-06 unsigned x64 preparation verified; Foundation review pending

The owner confirmed receipt of the Foundation application. This is not provider
approval, an active certificate, a signed release or SmartScreen acceptance.
Existing beta105 assets/tags and the website/server remain unchanged.

The complete hosted beta108 build and client validation succeeded:
https://github.com/Alex777rast/MasterDesk/actions/runs/42231650980
Exact build source:99441ca7182f49b55b6e62726b50850c24343018.
Exact shared gitlink:1afc2f9d89e0e462da2cbf080e54f80e8f6984a2.
Client assertions and22 Rust tests passed; the source gate and package/payload
inventories were uploaded. Server checks are explicitly NOT_RUN in client-only
CI, not a server validation PASS. The full defaults gate still includes them.

An independent disposable GitHub Windows VM verified those existing artifacts,
their archive digests, payload hashes, owned PE metadata and runner/core CLI:
https://github.com/Alex777rast/MasterDesk/actions/runs/42239997357
Verification-tool source:0be09bf23715e5b65a319902290d99969dfafcbd.
The build was not rerun and the package was not modified, signed or installed.

Artifact:MasterDesk-1.4.9-10-beta-108-2026-11-06-RDS-x86_64.exe
SHA256:0A21163AC5D3DA8448C645195E3F26746B43E772FF4E9CDDE74955CAD934E0E3
Actual CLI version:1.4.9-10 beta108; build date:2026-11-06 14:14.
These are packaging/identity checks, not GUI/install/update/network-performance
or SmartScreen acceptance. No signing credential/request or release step ran.

Local106, hosted107 and hosted108 identities are reserved. New full builds use
109+; artifact-only proof may inspect existing108 but must never rebuild or
rename old output. Source-only review/ownership changes do not change108 bytes.
CODEOWNERS now names its actual .github/CODEOWNERS location, with positive and
wrong-root regression cases; the file alone does not enforce branch protection.

Still open: maintainer MFA confirmation, dependency notices/license/SBOM review,
Foundation eligibility and later explicit origin/artifact/reviewer setup.
Cargo/Flutter/native inventories are supporting evidence, not legal clearance.
Signing must cover approved owned payload first, then its recomputed manifest,
then the exact packed outer EXE. x86/WinPE signing is outside this x64 scope.
Public default-branch/site promotion and release publication are separate owner
decisions. No personal contact details or private lab/deployment logs are added.

See docs/signing-x64-preparation.md, SIGNING_POLICY.md and PRIVACY.md.
