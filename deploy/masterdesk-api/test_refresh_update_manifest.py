import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("refresh-update-manifest.py")
SPEC = importlib.util.spec_from_file_location("refresh_update_manifest", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def release(**overrides):
    value = {
        "tag_name": "v1.4.9-masterdesk.3",
        "html_url": (
            "https://github.com/Alex777rast/MasterDesk/releases/"
            "tag/v1.4.9-masterdesk.3"
        ),
        "draft": False,
        "prerelease": False,
        "assets": [
            {"name": "MasterDesk-1.4.9-RDS-x86_64.exe"},
            {"name": "AUTHENTICODE.txt"},
            {"name": "SHA256.txt"},
            {"name": "SOURCE_COMMIT.txt"},
        ],
    }
    value.update(overrides)
    return value


class UpdateManifestTests(unittest.TestCase):
    def test_accepts_complete_stable_release(self):
        self.assertEqual(
            MODULE.build_manifest(release()),
            {
                "version": "1.4.9-3",
                "url": (
                    "https://github.com/Alex777rast/MasterDesk/releases/"
                    "tag/v1.4.9-masterdesk.3"
                ),
            },
        )

    def test_rejects_prerelease(self):
        with self.assertRaisesRegex(ValueError, "draft or prerelease"):
            MODULE.build_manifest(release(prerelease=True))

    def test_rejects_unexpected_tag(self):
        with self.assertRaisesRegex(ValueError, "Unexpected release tag"):
            MODULE.build_manifest(release(tag_name="v1.4.9-test"))

    def test_rejects_missing_executable(self):
        with self.assertRaisesRegex(ValueError, "Windows x64 executable"):
            MODULE.build_manifest(
                release(
                    assets=[
                        {"name": "AUTHENTICODE.txt"},
                        {"name": "SHA256.txt"},
                        {"name": "SOURCE_COMMIT.txt"},
                    ]
                )
            )


if __name__ == "__main__":
    unittest.main()
