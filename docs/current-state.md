# Current public source state

## 2026-11-06 reviewed client snapshot and x64 signing preparation

This branch publishes reviewed current MasterDesk client sources and the
modified hbb_common commit. It includes the installed-client DPAPI import fix,
existing WinPE/parallel-transfer support, protected-profile code and tests, plus
local x64 signing-preparation work. It is not a new binary release and does not
rewrite the immutable beta105 tag or assets. Historical base commits and
automatic source archives at older tags must not be represented as exact
snapshots of locally modified beta binaries.

Published beta105 remains unsigned. A local unsigned beta106 packaging proof
was checked for metadata, self-extraction, runner/core DLL loading and exact
owned payload hashes. Its package SHA256 is
82A21B2FFBA8E1CE74DA9F08D27C96ACF90BAA77164465E8FBDC6152B47DE958.
It is not GitHub-hosted provenance and must not be reissued as a different106.
The next hosted proof candidate is107 or later.

The masterdesk-windows.yml workflow is manual, uses read-only repository
permissions and uploads unsigned evidence only. It verifies clean source and
submodules before building on GitHub-hosted Windows. It has no automatic
release/site update, signing secret or signing submission. Changes to GitHub
Release, the website, server configuration and signing/provider accounts need
separate explicit authority; source publication alone does not authorize them.

Local checks passed:7 metadata/guard cases,4 source-gate fixtures,5 PowerShell
syntax checks, actionlint, cached x64 build and package/CLI/hash smoke. This is
not GUI, installed-update, remote-session or signed-SmartScreen acceptance.
Previously reported field/lab results are not blanket acceptance for a new
hosted candidate.

Next: run the manual unsigned beta107+ proof from the reviewed source branch;
review dependency licenses/SBOM, public policies, MFA/review controls, origin and
artifact rules with SignPath. Foundation approval, certificate/timestamp and
payload-first/package-second signing activation have not been established.
Do not submit local binaries as hosted artifacts or claim SmartScreen bypass.
x86/Sciter signing and WinPE images are outside this x64 application scope.

See docs/signing-x64-preparation.md, SIGNING_POLICY.md and PRIVACY.md. Private
lab logs, snapshots, deployment secrets and handoff records are intentionally
not included in this public source snapshot. No credentials belong in source,
test output or published build artifacts.
