# Contributing to MasterDesk

MasterDesk tracks RustDesk and keeps its modifications deliberately small.

Before submitting a change:

1. describe the user-facing reason;
2. avoid unrelated refactoring or formatting;
3. do not commit credentials, certificates, private keys, server passwords,
   `.env` files, generated binaries, build caches, or personal data;
4. run `scripts/Test-CustomDefaults.ps1`;
5. document changes that affect compiled defaults, network routing, branding,
   packaging, or code signing.

Security vulnerabilities must follow [SECURITY.md](SECURITY.md) and should not
be disclosed in a public issue.

Contributions are accepted under GNU AGPL-3.0 and must be compatible with the
licenses of upstream RustDesk and its dependencies.
