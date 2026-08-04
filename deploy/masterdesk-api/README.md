# MasterDesk API test deployment

This directory contains the reproducible test deployment for MasterDesk
accounts and address books. It runs the MIT-licensed `rustdesk-api` v2.7 as a
separate container and does not replace or restart the production `hbbs` and
`hbbr` containers.

## Network layout

- API container: `127.0.0.1:21114` only
- Public API: `https://api.masterdesk.online`
- ID server: `hbbs.masterdesk.online:21116`
- Relay server: `hbbr.masterdesk.online:21117`
- Persistent API data: `/opt/masterdesk-api/data`

The Caddy snippet terminates TLS and proxies the public API hostname to the
loopback-only container port. Public self-registration and the bundled web
client are disabled for the test deployment. Users are created by an
administrator.

The same HTTPS virtual host serves
`/var/lib/caddy/masterdesk-updates/latest.json` as
`/masterdesk/version/latest`. Publish a release and verify its downloadable
assets before replacing this file with a higher branded version. The client
shows the release in its main window. Installed Windows clients can perform an
interactive in-place update after verifying the EXE against the release's
`SHA256.txt`; unattended background installation remains disabled. Release
binaries remain unsigned until Authenticode signing is enabled.

`masterdesk-update-manifest.timer` performs this promotion automatically once
per hour. Its refresh script accepts only stable tags in the form
`v1.4.9-masterdesk.3`, verifies that the Windows EXE and all provenance files
are present, and atomically replaces the public manifest. A failed GitHub
request or incomplete release leaves the previous manifest untouched.

## Upstream and license

- Source: <https://github.com/lejianwen/rustdesk-api>
- Pinned test release: `v2.7`
- License: MIT

Before a production launch, create a visible MasterDesk fork of the upstream
API repository, build the image from that fork, add automated backups and run
a dedicated security review.
