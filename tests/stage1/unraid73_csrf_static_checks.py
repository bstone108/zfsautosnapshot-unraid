#!/usr/bin/env python3
"""Static contracts for Unraid 7.3+ CSRF pre-validation compatibility."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot"
RESPONSE_HELPERS = PLUGIN / "php/response-helpers.php"
SETTINGS_PAGE = PLUGIN / "php/settings.php"
SEND_SETTINGS_PAGE = PLUGIN / "php/send-settings.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    helpers = RESPONSE_HELPERS.read_text()
    settings = SETTINGS_PAGE.read_text()
    send_settings = SEND_SETTINGS_PAGE.read_text()

    assert_contains(
        helpers,
        "function zfsas_unraid_global_csrf_guard_active",
        "CSRF helper must detect Unraid WebGUI global CSRF pre-validation",
    )
    assert_contains(
        helpers,
        "ini_get('auto_prepend_file')",
        "global CSRF guard detection must key off PHP's configured auto_prepend_file",
    )
    assert_contains(
        helpers,
        "'/local_prepend.php'",
        "global CSRF guard detection must recognize Dynamix local_prepend.php",
    )
    assert_contains(
        helpers,
        "if (zfsas_unraid_global_csrf_guard_active()) {\n            return true;\n        }",
        "missing submitted token must be accepted only after Unraid's global guard consumed it",
    )
    assert_contains(
        helpers,
        "Security token is missing. Reload the page and try again.",
        "missing-token failures must still exist when no Unraid global guard is active",
    )
    assert_contains(
        helpers,
        "hash_equals($expectedToken, $submittedToken)",
        "explicit submitted tokens must still be compared with hash_equals",
    )

    for page_name, page_text in [("settings.php", settings), ("send-settings.php", send_settings)]:
        assert_contains(
            page_text,
            'name="csrf_token"',
            f"{page_name} must keep a hidden csrf_token field for Unraid's WebGUI layer",
        )
        assert_contains(
            page_text,
            "X-CSRF-Token",
            f"{page_name} AJAX calls must keep sending X-CSRF-Token for Unraid's WebGUI layer",
        )
        if "requestParams.append('csrf_token', csrfToken)" not in page_text and "params.append('csrf_token', csrfToken)" not in page_text:
            raise AssertionError(
                f"{page_name} AJAX calls must keep csrf_token in the POST body for Unraid's WebGUI layer"
            )

    print("PASS: Unraid 7.3 CSRF compatibility contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
