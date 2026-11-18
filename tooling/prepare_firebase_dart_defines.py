#!/usr/bin/env python3
"""Load the current station's public Firebase Android config into CI env."""
from __future__ import annotations

import json
import os
from pathlib import Path

CONFIG_PATH = Path("android/app/google-services.json")
EXPECTED_PACKAGE = "com.saqia.saqia_station"
PILOT_BRANCH = "feature/firebase-station-foundation"
PILOT_PROJECT_ID = "manzoma-ststion"


def main() -> None:
    if not CONFIG_PATH.is_file():
        raise SystemExit(f"Missing Firebase config: {CONFIG_PATH}")

    try:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Invalid Firebase config JSON: {error}") from error

    project = config.get("project_info") or {}
    project_id = str(project.get("project_id") or "").strip()
    sender_id = str(project.get("project_number") or "").strip()
    clients = config.get("client") or []
    matching = [
        client for client in clients
        if (
            (client.get("client_info") or {})
            .get("android_client_info", {})
            .get("package_name")
            == EXPECTED_PACKAGE
        )
    ]

    if not project_id or not sender_id:
        raise SystemExit("Firebase project_id/project_number is missing.")
    if len(matching) != 1:
        raise SystemExit(
            f"Expected exactly one Android client for {EXPECTED_PACKAGE}; "
            f"found {len(matching)}."
        )

    client = matching[0]
    app_id = str(
        (client.get("client_info") or {}).get("mobilesdk_app_id") or ""
    ).strip()
    api_keys = client.get("api_key") or []
    api_key = str((api_keys[0] if api_keys else {}).get("current_key") or "").strip()
    storage_bucket = str(project.get("storage_bucket") or "").strip()

    if not app_id or not api_key:
        raise SystemExit("Firebase mobilesdk_app_id/api_key is missing.")

    current_branch = os.environ.get("GITHUB_HEAD_REF") or os.environ.get(
        "GITHUB_REF_NAME", ""
    )
    if current_branch == PILOT_BRANCH and project_id != PILOT_PROJECT_ID:
        raise SystemExit(
            f"{PILOT_BRANCH} must target {PILOT_PROJECT_ID}, "
            f"not {project_id}."
        )

    values = {
        "SAQIA_FIREBASE_API_KEY": api_key,
        "SAQIA_FIREBASE_APP_ID": app_id,
        "SAQIA_FIREBASE_MESSAGING_SENDER_ID": sender_id,
        "SAQIA_FIREBASE_PROJECT_ID": project_id,
        "SAQIA_FIREBASE_STORAGE_BUCKET": storage_bucket,
    }

    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    else:
        for key, value in values.items():
            print(f"--dart-define={key}={value}")


if __name__ == "__main__":
    main()
