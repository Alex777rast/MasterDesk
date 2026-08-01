# MasterDesk Code signing policy

This policy is intended for the SignPath Foundation open-source application
and the subsequent GitHub Actions integration.

Free code signing provided by [SignPath.io](https://signpath.io/), certificate
by [SignPath Foundation](https://signpath.org/).

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

## Team roles

- Committer and reviewer:
  [Alex777rast](https://github.com/Alex777rast)
- Signing approver:
  [Alex777rast](https://github.com/Alex777rast)

Changes proposed by contributors who do not have direct commit access require
review before they are merged. Every production signing request requires
manual approval by the signing approver.

## Privacy and network communication

MasterDesk is remote-access software. When the user or system administrator
starts the program, it connects to the configured ID/relay infrastructure at
`hbbs.masteronline.space` and `hbbr.masteronline.space` so that the explicitly
requested remote-access service can work. That infrastructure may process the
IP address, MasterDesk device ID, connection timestamps, and routing metadata
required to establish and relay connections.

When the user signs in to a MasterDesk account, the client also connects to
`https://api.masteronline.space`. The API processes the account identifier,
authentication token, device metadata and address-book content required to
provide account and synchronization features. Passwords must be stored only as
one-way hashes by the API; plaintext passwords are never included in logs.

The client checks
`https://api.masteronline.space/masterdesk/version/latest` for a small release
manifest. It contains only the latest branded version and its HTTPS release
page. The request is not used for advertising or behavioral analytics.

MasterDesk does not intentionally send analytics, advertising identifiers, or
unrelated telemetry to third-party services. A user may replace the default
ID/relay server in the application settings; any independently operated server
is then governed by that operator's privacy policy.

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it. Running MasterDesk with the preconfigured service is such a
request because network communication is the program's documented core
function.

The current privacy notice is published in [PRIVACY.md](PRIVACY.md).

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
