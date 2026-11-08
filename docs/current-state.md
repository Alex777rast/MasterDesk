# Current public source state

## 2026-11-09 clean SignPath integration; signing remains BLOCKED

Owner requested the available technical work after final review. Clean worktree
branch codex/signpath-integration-20261109 starts at public reviewed726b3ce,
shared1afc2f9d89e0e462da2cbf080e54f80e8f6984a2. ONLY preparation commits ported:
0c6d88a/6a68fae/8333e30 (original c1b27d9/98b6e81/4a2bb58). Original dirty root,
index and shared8449b7e9 retained; no client/Free-Pro source copied or changed.

Integrated unsigned/manual workflow, complete tracked prerequisites, real
CODEOWNERS paths,110+ gate, build-time all-file manifest, reusable preflight
from existing dispatcher, atomic non-release beta reservation, inert request
state model and explicit3600s manual-approval wait. No actual submit implementation
or signing secret; approvedScope=[] and activation guard always refuses. Durable
provider submit/resume/repack chain still requires reviewed activation/approval.

Local PASS45 Python tests,7 metadata guards/4 source cases/4 ownership cases,
13 defaults-scope fixtures,6 signing PS syntax/2 real signature rejections,
2 workflow actionlint and diff-check. No product build/new beta, no actual
signature/provider approval, no new GUI/install/update/direct/relay/SmartScreen.
Prior22 client Rust tests retained, not rerun for signing-only changes. Old
SBOM/license reports remain historical supporting evidence, not exact candidate
legal clearance.14 inherited actionlint diagnostics remain outside this path.

Remote exact-scoped setup verified: active branch ruleset26814262 forbids
deletion/force-push ONLY for this integration branch; active tag ruleset26814264
forbids update/deletion ONLY masterdesk-beta-reserved/*, no bypass. Environment
masterdesk-signing26655560539 has owner required reviewer, admin bypassfalse,
prevent-self-reviewfalse pending second reviewer/solo choice, exactly one allowed
Branch policy for this integration branch, no secret created. This is NOT
required PR/codeowner enforcement. No default/release writes; default SHA and
release metadata unchanged. Setup backup/results under original workspace
artifacts/signpath-integration-20261109. No unrelated settings/automations touched.

Source-only branch published, hosted tooling run42526916619 PASS at integration
commit61d8e96c0365a7ec22c88c7caf345b1195443d23 (first attempt, hosted Windows):
45 Python tests,6 PS syntax/2 real signature rejections,7 metadata guards,
4 source/4 ownership cases,13 defaults-scope fixtures. All reserve/build/product
proof jobs SKIPPED as intended for tooling_only=true. Logs retrieved with no
authorization forwarded to storage; new5 product hash checks PASS unchanged.
Later changes are handoff/docs and review-packet helper only (locally checked).
Review packer now binds committed clean source, includes actual policies/CI,
supports explicit bounded evidence selection and rejects reparse ancestors.
Do NOT infer full hosted build/preflight/real reservation acceptance from this run.
Owner steps and independent external blockers: docs/signing/INTEGRATION-STATUS.md.

105..109 remain reserved/immutable; the next actual product identity is110+.
No signature/release/site/production/VM action is authorized by this preparation.

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
Actual CLI version:1.4.9-10 beta 108; build date:2026-11-06 14:14.
Local pure portable decoding also matched all100 payload files byte-for-byte;
the extraction wrapper and client CLI were not run on the maintainer host.
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
