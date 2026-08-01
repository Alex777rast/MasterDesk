#!/usr/bin/env python3
"""Refresh the public MasterDesk update manifest from the latest GitHub release."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.request


RELEASE_API = "https://api.github.com/repos/Alex777rast/MasterDesk/releases/latest"
RELEASE_URL_PREFIX = "https://github.com/Alex777rast/MasterDesk/releases/tag/"
DEFAULT_OUTPUT = Path("/var/lib/caddy/masterdesk-updates/latest.json")
TAG_PATTERN = re.compile(r"^v(\d+\.\d+\.\d+)-masterdesk\.(\d+)$")
WINDOWS_ASSET_PATTERN = re.compile(r"^MasterDesk-\d+\.\d+\.\d+-RDS-x86_64\.exe$")
REQUIRED_METADATA_ASSETS = {
    "AUTHENTICODE.txt",
    "SHA256.txt",
    "SOURCE_COMMIT.txt",
}
MAX_RESPONSE_BYTES = 1024 * 1024


def fetch_latest_release() -> dict:
    request = urllib.request.Request(
        RELEASE_API,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "MasterDesk-update-manifest/1",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("GitHub release response is too large")
    release = json.loads(body)
    if not isinstance(release, dict):
        raise ValueError("GitHub release response is not an object")
    return release


def build_manifest(release: dict) -> dict[str, str]:
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("Latest release is a draft or prerelease")

    tag = release.get("tag_name")
    if not isinstance(tag, str):
        raise ValueError("Release tag is missing")
    match = TAG_PATTERN.fullmatch(tag)
    if match is None:
        raise ValueError(f"Unexpected release tag: {tag!r}")

    release_url = release.get("html_url")
    if not isinstance(release_url, str) or not release_url.startswith(RELEASE_URL_PREFIX):
        raise ValueError("Release URL is outside the MasterDesk GitHub repository")

    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("Release assets are missing")
    asset_names = {
        asset.get("name")
        for asset in assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    if not any(WINDOWS_ASSET_PATTERN.fullmatch(name) for name in asset_names):
        raise ValueError("Release does not contain a MasterDesk Windows x64 executable")
    missing_metadata = REQUIRED_METADATA_ASSETS - asset_names
    if missing_metadata:
        raise ValueError(
            "Release is missing metadata assets: " + ", ".join(sorted(missing_metadata))
        )

    return {
        "version": f"{match.group(1)}-{match.group(2)}",
        "url": release_url,
    }


def write_manifest_atomic(manifest: dict[str, str], output: Path) -> None:
    import grp

    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(manifest, stream, ensure_ascii=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o640)
        os.chown(temporary, 0, grp.getgrnam("caddy").gr_gid)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        type=Path,
        help="Read a saved GitHub release response instead of using the network.",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.input is None:
        release = fetch_latest_release()
    else:
        release = json.loads(args.input.read_text(encoding="utf-8"))
    manifest = build_manifest(release)
    write_manifest_atomic(manifest, args.output)
    print(f"Published MasterDesk update manifest {manifest['version']}")


if __name__ == "__main__":
    main()
