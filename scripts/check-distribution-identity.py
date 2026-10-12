#!/usr/bin/env python3
"""Reject implicit release signing. This does not verify certificate ownership."""

import os
import re
import sys


def main() -> int:
    # Existing development builds keep their identity and privacy grants. Unsigned
    # compile checks may explicitly disable signing; they are not distributable.
    if os.environ.get("CONFIGURATION") != "Release":
        return 0
    if os.environ.get("CODE_SIGNING_ALLOWED") == "NO":
        print("note: Unsigned verification build; not a Mengoh Labs distribution artifact.")
        return 0

    app_store = os.environ.get("TARGET_NAME") == "OmniFlowAppStore"
    key = "OMNIFLOW_APP_STORE_TEAM" if app_store else "OMNIFLOW_RELEASE_TEAM"
    expected = os.environ.get(key, "").strip()
    actual = os.environ.get("DEVELOPMENT_TEAM", "").strip()
    publisher = os.environ.get("OMNIFLOW_INTENDED_PUBLISHER", "")
    if publisher != "Mengoh Labs" or not re.fullmatch(r"[A-Z0-9]{10}", expected) or actual != expected:
        print(
            f"error: OmniFlow distribution requires the verified Mengoh Labs team via {key}. "
            "Apple Developer enrollment is pending; legacy development teams must not be used as a publisher fallback. "
            "See docs/public/development.md. This check does not establish certificate ownership.",
            file=sys.stderr,
        )
        return 1
    print("note: Explicit distribution team configured; verify Mengoh Labs certificate ownership before publishing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
