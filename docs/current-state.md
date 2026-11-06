# Current public source state

## 2026-11-06 unsigned hosted client preparation, candidate108+

The Foundation acknowledged the project application; it remains under review.
This is not an active certificate, signed release or SmartScreen acceptance.
Existing beta105 releases and the website/server are unchanged by this branch.

The reviewed source snapshot includes corresponding hbb_common source and the
installed-client DPAPI import fix, existing WinPE/transfer/profile code and x64
signing preparation. Source publication does not rewrite older release tags or
make historical automatic source archives exact sources for local dirty builds.

Local unsigned106 and hosted107 are reserved and must not be reissued. Hosted107
successfully built its EXE, but the later mixed client/server defaults gate
failed because private server deployment files were intentionally not published.
No107 artifact upload or complete pipeline acceptance was obtained.

This branch retains the full defaults gate by default and adds explicit public
client-only selection. All client source/Rust/update/IPC/portable assertions
remain enabled. Server patch and update-API service checks are available in
Test-ServerDefaults.ps1 and still run from the default full gate; client-only
CI reports them NOT_RUN, never server PASS. Dedicated fixtures verify separation
and fail-closed source/security guards. Stale implementation-name assertions
were aligned to the current incremental AOT and installed-server/handoff paths,
with IPC/handoff Rust regression filters included. No runtime behavior changed.

The manual GitHub-hosted workflow builds a new unsigned beta108 or later from
the exact source checkout, validates it and uploads package/payload inventories.
It has read-only repository permissions, no signing credential/submission,
automatic release/site update or production deployment. Do not represent local
binaries as GitHub-hosted output. Successful compilation alone is not a passed
pipeline, new GUI/runtime acceptance or provider-verified provenance.

Pending: successful hosted artifacts and their independent hash/extraction/
identity checks, complete dependency licensing/SBOM review, maintainer MFA,
Foundation eligibility and later reviewed origin/artifact policy configuration.
Actual signing must cover owned payload first, package exact signed bytes,
then sign/verify the outer package. Provider setup and public release remain
separate authorized stages. x86/WinPE signing is outside this x64 application.

See docs/signing-x64-preparation.md, SIGNING_POLICY.md and PRIVACY.md. Private
contact data, lab logs and deployment configuration are not newly published.
