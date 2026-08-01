# MasterDesk API test deployment

This directory contains the reproducible test deployment for MasterDesk
accounts and address books. It runs the MIT-licensed `rustdesk-api` v2.7 as a
separate container and does not replace or restart the production `hbbs` and
`hbbr` containers.

## Network layout

- API container: `127.0.0.1:21114` only
- Public API: `https://api.masteronline.space`
- ID server: `desk.masteronline.space:21116`
- Relay server: `desk.masteronline.space:21117`
- Persistent API data: `/opt/masterdesk-api/data`

The Caddy snippet terminates TLS and proxies the public API hostname to the
loopback-only container port. Public self-registration and the bundled web
client are disabled for the test deployment. Users are created by an
administrator.

## Upstream and license

- Source: <https://github.com/lejianwen/rustdesk-api>
- Pinned test release: `v2.7`
- License: MIT

Before a production launch, create a visible MasterDesk fork of the upstream
API repository, build the image from that fork, add automated backups and run
a dedicated security review.
