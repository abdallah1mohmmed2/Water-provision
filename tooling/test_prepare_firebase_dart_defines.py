import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import prepare_firebase_dart_defines as target


class PrepareFirebaseDefinesTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.config_path = Path(self.temp_dir.name) / "google-services.json"
        self.original_path = target.CONFIG_PATH
        target.CONFIG_PATH = self.config_path
        self.config = {
            "project_info": {
                "project_id": "manzoma-ststion",
                "project_number": "1004981299919",
                "storage_bucket": "manzoma-ststion.firebasestorage.app",
            },
            "client": [{
                "client_info": {
                    "android_client_info": {
                        "package_name": target.EXPECTED_PACKAGE,
                    },
                    "mobilesdk_app_id":
                        "1:1004981299919:android:5bb7d98823849b43e565ba",
                },
                "api_key": [{"current_key": "public-client-api-key"}],
            }],
        }
        self.write_config()

    def tearDown(self):
        target.CONFIG_PATH = self.original_path
        self.temp_dir.cleanup()

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")

    def test_writes_expected_build_defines_to_github_env(self):
        env_file = Path(self.temp_dir.name) / "github-env"
        with mock.patch.dict(os.environ, {
            "GITHUB_ENV": str(env_file),
            "GITHUB_REF_NAME": target.PILOT_BRANCH,
        }, clear=True):
            target.main()

        output = env_file.read_text(encoding="utf-8")
        self.assertIn("SAQIA_FIREBASE_PROJECT_ID=manzoma-ststion", output)
        self.assertIn("SAQIA_FIREBASE_MESSAGING_SENDER_ID=1004981299919", output)
        self.assertIn("SAQIA_FIREBASE_APP_ID=1:1004981299919:android:", output)

    def test_rejects_another_project_on_the_pilot_branch(self):
        self.config["project_info"]["project_id"] = "another-station"
        self.write_config()
        with mock.patch.dict(os.environ, {
            "GITHUB_REF_NAME": target.PILOT_BRANCH,
        }, clear=True):
            with self.assertRaises(SystemExit):
                target.main()

    def test_rejects_a_mismatched_android_package(self):
        self.config["client"][0]["client_info"]["android_client_info"][
            "package_name"
        ] = "com.example.other"
        self.write_config()
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit):
                target.main()

    def test_prints_defines_for_local_builds(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                target.main()
        self.assertIn(
            "--dart-define=SAQIA_FIREBASE_PROJECT_ID=manzoma-ststion",
            output.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
