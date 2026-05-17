#!/usr/bin/env python3
"""Static contracts for shared log endpoint helper functions."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot"
PHP_DIR = PLUGIN / "php"
LOG_HELPERS = PHP_DIR / "log-helpers.php"
LOG_TAIL = PHP_DIR / "log-tail.php"
LOG_STREAM = PHP_DIR / "log-stream.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def assert_not_contains(text: str, needle: str, message: str) -> None:
    if needle in text:
        raise AssertionError(message)


def main() -> int:
    if not LOG_HELPERS.is_file():
        raise AssertionError("log-helpers.php must hold shared log endpoint helpers")

    helpers = LOG_HELPERS.read_text()
    tail = LOG_TAIL.read_text()
    stream = LOG_STREAM.read_text()

    for function_name in [
        "zfsas_log_is_safe_path",
        "zfsas_log_tail_file_lines",
        "zfsas_log_resolve_type_and_file",
    ]:
        assert_contains(
            helpers,
            f"function {function_name}",
            f"log-helpers.php must define {function_name}",
        )

    for endpoint_name, endpoint_text in [("log-tail.php", tail), ("log-stream.php", stream)]:
        assert_contains(
            endpoint_text,
            "require_once __DIR__ . '/log-helpers.php';",
            f"{endpoint_name} must load shared log helpers",
        )
        for old_function_name in ["isSafeLogPath", "tailFileLines", "resolveLogTypeAndFile"]:
            assert_not_contains(
                endpoint_text,
                f"function {old_function_name}",
                f"{endpoint_name} must not duplicate {old_function_name}",
            )

    print("PASS: log helper static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
