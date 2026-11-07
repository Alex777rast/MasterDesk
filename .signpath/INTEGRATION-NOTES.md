# Integration boundary

The new scripts/docs/preflight workflow are committed independently from the
already-dirty client/signing preparation work. The current branch starts at the
preserved local base, not at the published reviewed build source.

Two integration changes are visible in the working tree but must NOT cause the
entire pre-existing dirty files to be staged as this task's changes:

- masterdesk-windows.yml: new builds110+, produce payload-manifest.json before
  uploading the unsigned evidence; existing package/payload layout unchanged.
- .github/CODEOWNERS: add /scripts/signing/ and /docs/signing/ coverage.

These require review/porting into the reviewed complete source branch together
with the existing signing work. The new preflight deliberately fails on old
artifacts without a build-time payload manifest; do not fabricate one after the
fact to make a historic run eligible. It is not yet a hosted-tested pipeline.

No commit here makes the whole dirty tree a valid release source. No push,
signing request or source promotion is authorized by the existence of these
files. The submission fragment remains hard-disabled outside workflows.
