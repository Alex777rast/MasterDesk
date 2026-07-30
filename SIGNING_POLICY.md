# MasterDesk code-signing policy

This policy is intended for the SignPath Foundation open-source application
and the subsequent GitHub Actions integration.

## Scope

Only release artifacts built from the public
`Alex777rast/MasterDesk` repository may be signed with the MasterDesk
certificate. The current signing target is:

`MasterDesk-1.4.9-RDS-x86_64.exe`

The project will not sign externally uploaded binaries, local developer
builds, pull-request artifacts, forks owned by third parties, debug builds, or
artifacts whose source commit cannot be identified.

## Trusted build

- source and build scripts are public;
- release builds run on GitHub-hosted Windows runners;
- the workflow checks out the release commit and recursive submodules;
- toolchain versions and the vcpkg baseline are pinned;
- the unsigned EXE is uploaded as a GitHub Actions artifact before submission
  to SignPath;
- the SignPath GitHub connector verifies build origin;
- the signed output is published together with SHA-256 and source commit.

## Authorization

- GitHub and SignPath accounts must use multi-factor authentication;
- the SignPath API token is stored only as a GitHub Actions secret;
- certificate configuration and signing-policy changes are restricted to the
  project maintainer;
- production signing requests require the SignPath policy configured for the
  Foundation project;
- `.github/workflows/`, `.signpath/`, `CODEOWNERS`, and this policy are treated
  as security-sensitive files.

## Review and incident response

Release commits and workflow changes are reviewed before a release tag is
created. If a signing credential, maintainer account, workflow, or release is
suspected to be compromised:

1. disable the signing policy and release workflow;
2. revoke affected tokens and sessions;
3. remove the affected release from distribution without destroying audit
   evidence;
4. notify SignPath Foundation;
5. investigate and publish a security advisory when appropriate.

Signing audit logs and GitHub Actions provenance are retained by their
respective services.
