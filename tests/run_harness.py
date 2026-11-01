#!/usr/bin/env python3
"""Repository test harness for zfsautosnapshot-unraid.

Recovered 2026-11-01 from Kira's Hermes workspace at
/opt/data/workspace/Projects/zfsautosnapshot-unraid-harness (dated 2026-05-15)
and moved into this repo. It may build a throwaway package in a temporary copy,
but it never writes release artifacts into the real working tree.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


DEFAULT_REPO = Path(__file__).resolve().parents[1]
REQUIRED_COMMANDS = [
    "bash",
    "git",
    "python3",
    "php",
    "xmllint",
    "shellcheck",
    "shfmt",
    "tar",
    "xz",
    "jq",
]
SOURCE_ARTIFACT_PATTERNS = (
    re.compile(r"^dist/"),
    re.compile(r"^zfs\.autosnapshot\.plg$"),
)
REQUIRED_PACKAGE_MEMBERS = [
    "usr/local/sbin/zfs_autosnapshot",
    "usr/local/sbin/zfs_autosnapshot_delete_worker",
    "usr/local/sbin/zfs_autosnapshot_send_worker",
    "usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh",
    "usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php",
]


@dataclass
class Result:
    name: str
    ok: bool
    detail: str = ""


class Harness:
    def __init__(self, repo: Path, strict_clean: bool, skip_package_smoke: bool) -> None:
        self.repo = repo.resolve()
        self.strict_clean = strict_clean
        self.skip_package_smoke = skip_package_smoke
        self.results: list[Result] = []

    def run(self) -> int:
        tests = [
            self.test_repo_shape,
            self.test_required_tools,
            self.test_git_state,
            self.test_no_source_commit_artifacts,
            self.test_xml_contracts,
            self.test_php_lint,
            self.test_shell_syntax,
            self.test_shellcheck_errors,
            self.test_existing_stage1,
            self.test_recent_send_regression_cases,
            self.test_regression_contracts,
            self.test_history_derived_ui_button_contracts,
            self.test_history_derived_save_transport_contracts,
            self.test_history_derived_cron_install_contracts,
            self.test_history_derived_queue_state_contracts,
        ]
        if not self.skip_package_smoke:
            tests.append(self.test_isolated_package_smoke)

        for test in tests:
            name = test.__name__.removeprefix("test_").replace("_", "-")
            try:
                detail = test() or ""
            except Exception as exc:  # noqa: BLE001 - harness should report all failures uniformly
                self.results.append(Result(name, False, str(exc)))
                print(f"FAIL {name}: {exc}")
            else:
                self.results.append(Result(name, True, detail))
                suffix = f": {detail}" if detail else ""
                print(f"PASS {name}{suffix}")

        failed = [r for r in self.results if not r.ok]
        print()
        print(f"Summary: {len(self.results) - len(failed)} passed, {len(failed)} failed")
        if failed:
            for result in failed:
                print(f" - {result.name}: {result.detail}")
            return 1
        return 0

    def cmd(
        self,
        args: Sequence[str] | str,
        *,
        cwd: Path | None = None,
        timeout: int = 300,
        check: bool = True,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        shell = isinstance(args, str)
        proc = subprocess.run(
            args,
            cwd=str(cwd or self.repo),
            env=env,
            shell=shell,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        if check and proc.returncode != 0:
            raise AssertionError(
                f"command failed ({proc.returncode}): {args}\n{proc.stdout[-4000:]}"
            )
        return proc

    def git_files(self, patterns: Sequence[str]) -> list[str]:
        proc = self.cmd(["git", "ls-files", *patterns])
        return [line for line in proc.stdout.splitlines() if line]

    def test_repo_shape(self) -> str:
        required = [
            ".git",
            "VERSION",
            "README.md",
            ".github/workflows/build-release-artifacts.yml",
            "scripts/build-release.sh",
            "scripts/verify-release.sh",
            "zfs.autosnapshot.plg.in",
            "source/usr/local/sbin/zfs_autosnapshot",
            "source/usr/local/sbin/zfs_autosnapshot_send_worker",
            "source/usr/local/sbin/zfs_autosnapshot_delete_worker",
            "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php",
            "tests/stage1/run.sh",
        ]
        missing = [path for path in required if not (self.repo / path).exists()]
        if missing:
            raise AssertionError("missing required repo paths: " + ", ".join(missing))
        branch = self.cmd(["git", "branch", "--show-current"]).stdout.strip()
        return f"branch={branch or 'detached'}"

    def test_required_tools(self) -> str:
        missing = [cmd for cmd in REQUIRED_COMMANDS if shutil.which(cmd) is None]
        if missing:
            raise AssertionError("missing commands: " + ", ".join(missing))
        php = self.cmd(["php", "-r", "echo PHP_VERSION;"], cwd=self.repo).stdout.strip()
        return f"php={php}"

    def test_git_state(self) -> str:
        self.cmd(["git", "diff", "--check"])
        status = self.cmd(["git", "status", "--short"]).stdout.strip()
        if self.strict_clean and status:
            raise AssertionError("working tree is not clean:\n" + status)
        return "clean" if not status else "dirty allowed for patch verification"

    def test_no_source_commit_artifacts(self) -> str:
        proc = self.cmd(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
        changed = [line for line in proc.stdout.splitlines() if line]
        artifacts = [p for p in changed if any(pattern.search(p) for pattern in SOURCE_ARTIFACT_PATTERNS)]
        if artifacts:
            raise AssertionError(
                "current source commit includes generated artifacts; push source-only commits before Actions builds: "
                + ", ".join(artifacts)
            )
        return f"HEAD files={len(changed)} source-only"

    def test_xml_contracts(self) -> str:
        plg = self.repo / "zfs.autosnapshot.plg"
        self.cmd(["xmllint", "--noout", str(plg)], cwd=self.repo)
        root = ET.parse(plg).getroot()
        if root.tag != "PLUGIN":
            raise AssertionError("root .plg must have PLUGIN root")
        for attr in ["name", "version", "pluginURL", "min"]:
            if not root.attrib.get(attr):
                raise AssertionError(f"root .plg missing {attr} attribute")
        if root.attrib["name"] != "zfs.autosnapshot":
            raise AssertionError("unexpected plugin name")
        files = root.findall("FILE")
        if not files:
            raise AssertionError(".plg contains no FILE entries")
        run_blocks = [f for f in files if f.attrib.get("Run") == "/bin/bash"]
        if len(run_blocks) < 2:
            raise AssertionError(".plg must include install and remove bash blocks")
        return f"version={root.attrib['version']}"

    def test_php_lint(self) -> str:
        files = self.git_files(["*.php"])
        if not files:
            raise AssertionError("no PHP files found")
        for rel in files:
            self.cmd(["php", "-l", rel])
        return f"{len(files)} files"

    def test_shell_syntax(self) -> str:
        files = sorted(set(self.git_files(["*.sh"]) + self.git_files(["source/usr/local/sbin/*"])))
        if not files:
            raise AssertionError("no shell files found")
        self.cmd(["bash", "-n", *files])
        return f"{len(files)} files"

    def test_shellcheck_errors(self) -> str:
        files = sorted(set(self.git_files(["*.sh"]) + self.git_files(["source/usr/local/sbin/*"])))
        self.cmd(["shellcheck", "-S", "error", *files])
        return f"{len(files)} files at severity=error"

    def test_existing_stage1(self) -> str:
        boot = Path("/boot/config/plugins/zfs.autosnapshot")
        if os.geteuid() == 0:
            boot.mkdir(parents=True, exist_ok=True)
            self.cmd(["bash", "tests/stage1/run.sh"], timeout=900)
            return "stage1 ok"
        self.cmd(["sudo", "mkdir", "-p", str(boot)])
        self.cmd(["sudo", "bash", "tests/stage1/run.sh"], timeout=900)
        return "stage1 ok (sudo)"

    def test_regression_contracts(self) -> str:
        checks = {
            "send-helpers.php": [
                "function zfsas_send_normalize_dataset_path",
                "rename($tmpFile, $configFile)",
                "zfsas_send_write_config_atomically",
            ],
            "ops-queue-lib.sh": [
                "send checkpoint schedule ${send_schedule_job_id} is not loaded",
                "source=\"${source%/}\"",
                "dest=\"${dest%/}\"",
            ],
            "zfs_autosnapshot_delete_worker": [
                "Cannot safely delete send-managed snapshot ${snapshot} because schedule ${schedule_job_id} is not loaded.",
                "Cannot safely delete send-managed snapshot ${snapshot} because its schedule id could not be determined.",
                "destroy_snapshot_for_transport",
            ],
        }
        for filename, needles in checks.items():
            if filename == "send-helpers.php":
                path = self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php"
            elif filename == "ops-queue-lib.sh":
                path = self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
            else:
                path = self.repo / "source/usr/local/sbin/zfs_autosnapshot_delete_worker"
            text = path.read_text()
            missing = [needle for needle in needles if needle not in text]
            if missing:
                raise AssertionError(f"{filename} missing regression contracts: {missing}")
        self.cmd(["python3", "tests/stage1/send_settings_static_checks.py"])
        self.cmd(["bash", "tests/stage1/zero_change_common_harness.sh"])
        return "recent checkpoint/prefix regressions covered"

    def test_history_derived_ui_button_contracts(self) -> str:
        """Guard old save-button/theme-submit and broken-button regressions."""
        php_files = [self.repo / rel for rel in self.git_files(["source/usr/local/emhttp/plugins/zfs.autosnapshot/php/*.php"])]
        button_re = re.compile(r"<button\b(?P<attrs>[^>]*)>", re.IGNORECASE)
        missing_type: list[str] = []
        for path in php_files:
            text = path.read_text(errors="ignore")
            for match in button_re.finditer(text):
                attrs = match.group("attrs")
                if re.search(r"\btype\s*=", attrs, re.IGNORECASE):
                    continue
                line = text.count("\n", 0, match.start()) + 1
                missing_type.append(f"{path.relative_to(self.repo)}:{line}")
        if missing_type:
            raise AssertionError(
                "buttons must declare type=\"button\"/submit explicitly to avoid Unraid/theme implicit-submit races: "
                + ", ".join(missing_type[:20])
            )

        settings = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/settings.php").read_text()
        send_settings = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-settings.php").read_text()
        if not re.search(r'<button\b[^>]*\bid=["\']zfsas_save_btn["\'][^>]*\btype=["\']button["\']|<button\b[^>]*\btype=["\']button["\'][^>]*\bid=["\']zfsas_save_btn["\']', settings, re.I):
            raise AssertionError('main Save Settings button must be explicit type="button"')
        if not re.search(r'<button\b[^>]*\bid=["\']save_send_btn["\'][^>]*\btype=["\']button["\']|<button\b[^>]*\btype=["\']button["\'][^>]*\bid=["\']save_send_btn["\']', send_settings, re.I):
            raise AssertionError('send Save Settings button must be explicit type="button"')
        save_contracts = [
            "saveButton.addEventListener('click', startSave, true)",
            "saveForm.addEventListener('submit', startSave, true)",
            "event.preventDefault();",
            "event.stopImmediatePropagation",
            "event.stopPropagation",
            "setSaveButtonState(true)",
            "setSaveButtonState(false)",
            "showSaveButtonSavedState()",
        ]
        send_button_contracts = [
            "saveButton.addEventListener('click', startSave, true)",
            "saveForm.addEventListener('submit', startSave, true)",
            "setSaveButtonState(true)",
            "setSaveButtonState(false)",
        ]
        missing = [needle for needle in save_contracts if needle not in settings]
        missing.extend(f"send-settings.php: {needle}" for needle in send_button_contracts if needle not in send_settings)
        if missing:
            raise AssertionError("save buttons lost hardened click/submit contract: " + repr(missing))
        return f"{len(php_files)} PHP pages scanned; main/send save buttons hardened"

    def test_history_derived_save_transport_contracts(self) -> str:
        """Guard the long-running save/AJAX/JSON/CSRF reliability fixes."""
        settings = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/settings.php").read_text()
        response = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/response-helpers.php").read_text()
        save_main = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/save-settings.php").read_text()
        save_send = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/save-send-settings.php").read_text()
        send_settings = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-settings.php").read_text()
        for label, text in {"settings.php": settings, "send-settings.php": send_settings}.items():
            if 'data-ajax-action=' not in text:
                raise AssertionError(f"{label} form must expose data-ajax-action for reliable AJAX save")
            if 'name="csrf_token"' not in text:
                raise AssertionError(f"{label} must include csrf_token hidden input")
            if 'addEventListener(' not in text or ', true)' not in text:
                raise AssertionError(f"{label} must use capture-phase save handlers")
        contracts = {
            "settings.php": [
                "requestJsonFormPost",
                "requestJsonPost",
                "ZFSAS_JSON_BEGIN",
                "ZFSAS_JSON_END",
                "runSaveCompatibilityProbe();",
                "window.setTimeout(function ()",
                "Save is taking longer than expected",
            ],
            "response-helpers.php": [
                "function zfsas_get_csrf_token()",
                "function zfsas_validate_csrf_token(&$error = null)",
                "function zfsas_emit_marked_json($payload, $statusCode = 200)",
                "X-Zfsas-Response-Mode: marked-json",
                "while (ob_get_level() > 0)",
                "hash_equals($expectedToken, $submittedToken)",
            ],
            "save-settings.php": [
                "zfsas_emit_marked_json",
                "ZFSAS_FORCE_AJAX_SAVE",
                "$isProbeRequest",
                "$postAjax",
            ],
            "save-send-settings.php": [
                "zfsas_emit_marked_json",
                "$expectsJson",
                "$postAjax",
            ],
            "send-settings.php": [
                "requestJsonFormPost",
                "ZFSAS_JSON_BEGIN",
                "ZFSAS_JSON_END",
                "function startSave",
            ],
        }
        texts = {
            "settings.php": settings,
            "response-helpers.php": response,
            "save-settings.php": save_main,
            "save-send-settings.php": save_send,
            "send-settings.php": send_settings,
        }
        missing = []
        for label, needles in contracts.items():
            missing.extend(f"{label}: {needle}" for needle in needles if needle not in texts[label])
        if missing:
            raise AssertionError("save transport regression contracts missing: " + repr(missing[:20]))
        return "main/send save endpoints use marked JSON, CSRF, probes, capture handlers"

    def test_history_derived_cron_install_contracts(self) -> str:
        """Guard install, cron, package, permission, and flash-wear regressions."""
        sync = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/sync-cron.sh").read_text()
        repair = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/repair-permissions.sh").read_text()
        plg_template = (self.repo / "zfs.autosnapshot.plg.in").read_text()
        build = (self.repo / "scripts/build-release.sh").read_text()
        verify = (self.repo / "scripts/verify-release.sh").read_text()
        disks = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/event/disks_mounted").read_text()
        contracts = {
            "sync-cron.sh": [
                "# Unraid uses BusyBox crond format in /etc/cron.d: no username column.",
                "QUEUE_KICKER_CMD",
                "mktemp \"${CRON_FILE}.tmp.XXXXXX\"",
                "mv \"$CRON_FILE_TMP\" \"$CRON_FILE\"",
                "update_cron",
                "/etc/rc.d/rc.crond",
                "load_config_file \"$SEND_CONFIG_FILE\"",
                "validate_cron_5_fields",
                "validate_cron_safe_chars",
            ],
            "repair-permissions.sh": [
                "repair_system_log_dir_if_needed \"/var/log\"",
                "chown root \"$dir_path\"",
                "chmod 0755 \"$dir_path\"",
                "ensure_executable \"/usr/local/sbin/zfs_autosnapshot_delete_worker\"",
            ],
            "zfs.autosnapshot.plg.in": [
                "upgradepkg",
                "--install-new",
                "--reinstall",
                "verify_md5",
                "repair-permissions.sh",
                "sync-cron.sh",
                "removepkg zfs-autosnapshot",
            ],
            "build-release.sh": [
                "find \"$STAGING_DIR\" -name \".DS_Store\" -delete",
                "COPYFILE_DISABLE=1",
                "--owner=0",
                "--group=0",
                "md5sum",
            ],
            "verify-release.sh": [
                "tar -tJf",
                "source.list",
                "package.list",
                "comm -23",
                "Release package is missing source files",
                "Release package contains unexpected files",
                "Release package contains macOS metadata files.",
            ],
            "event/disks_mounted": [
                "sync-cron.sh",
                "|| true",
            ],
        }
        texts = {
            "sync-cron.sh": sync,
            "repair-permissions.sh": repair,
            "zfs.autosnapshot.plg.in": plg_template,
            "build-release.sh": build,
            "verify-release.sh": verify,
            "event/disks_mounted": disks,
        }
        missing = []
        for label, needles in contracts.items():
            missing.extend(f"{label}: {needle}" for needle in needles if needle not in texts[label])
        if missing:
            raise AssertionError("cron/install/package regression contracts missing: " + repr(missing[:25]))
        return "cron/install/package/permission pitfalls guarded"

    def test_history_derived_queue_state_contracts(self) -> str:
        """Guard recurring send/delete queue state-machine regressions from project history."""
        ops = (self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh").read_text()
        send_worker = (self.repo / "source/usr/local/sbin/zfs_autosnapshot_send_worker").read_text()
        delete_worker = (self.repo / "source/usr/local/sbin/zfs_autosnapshot_delete_worker").read_text()
        queue_handler = (self.repo / "source/usr/local/sbin/zfs_autosnapshot_queue_handler").read_text()
        queue_kicker = (self.repo / "source/usr/local/sbin/zfs_autosnapshot_queue_kicker").read_text()
        contracts = {
            "ops-queue-lib.sh": [
                "unraid_array_actionable()",
                "reconcile_stale_jobs()",
                "claim_send_job_path_for_launch",
                "WINDOW_KEY",
                "record_completed_schedule_window",
                "queue_snapshot_delete_job",
                "snapshot_delete_checkpoint_job_exists",
                "OPS_JOBS_DIR",
                "DELETE_QUEUE_INBOX_FILE",
                "PERSISTED_DELETE_QUEUE_FILE",
                "FAILED_SEND_LOGS_DIR",
                "latest_checkpoint_basename_for_schedule",
                "checkpoint_basename_is_latest_common_for_schedule",
                "SEND_SPACE_RESERVATION_DIR",
                "cleanup_stale_send_space_reservations_locked",
                "preserve_failed_send_log_for_job",
            ],
            "zfs_autosnapshot_send_worker": [
                "mark_job_failed_or_retry",
                "JOB_ACTION",
                "SOURCE_SNAPSHOT_NAME",
                "PREVIOUS_SNAPSHOT_NAME",
                "register_active_send_datasets_for_current_job",
                "cleanup_source_checkpoints_for_verified_member",
                "release_current_space_reservation",
                "mark_job_terminal_failure",
            ],
            "zfs_autosnapshot_delete_worker": [
                "load_legacy_runtime_state",
                "write_state_snapshot",
                "QUEUE_BY_SNAPSHOT",
                "QUEUE_BY_CHECKPOINT",
                "retry_wait",
                "snapshot_delete_target_is_safe",
                "process_send_checkpoint_delete",
                "destroy_snapshot_for_transport",
            ],
            "zfs_autosnapshot_queue_handler": [
                "reconcile_stale_jobs",
                "claim_send_job_path_for_launch",
                "zfs_autosnapshot_send_worker",
            ],
            "zfs_autosnapshot_queue_kicker": [
                "unraid_array_actionable",
                "start_queue_handler",
                "start_queue_handler",
            ],
        }
        texts = {
            "ops-queue-lib.sh": ops,
            "zfs_autosnapshot_send_worker": send_worker,
            "zfs_autosnapshot_delete_worker": delete_worker,
            "zfs_autosnapshot_queue_handler": queue_handler,
            "zfs_autosnapshot_queue_kicker": queue_kicker,
        }
        missing = []
        for label, needles in contracts.items():
            missing.extend(f"{label}: {needle}" for needle in needles if needle not in texts[label])
        if missing:
            raise AssertionError("send/delete queue regression contracts missing: " + repr(missing[:30]))
        return "send/delete queue history pitfalls guarded"


    def test_recent_send_regression_cases(self) -> str:
        """Guard the remote/local routing, retry, reseed, and schedule-window fixes."""
        ops_path = self.repo / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
        delete_path = self.repo / "source/usr/local/sbin/zfs_autosnapshot_delete_worker"
        send_path = self.repo / "source/usr/local/sbin/zfs_autosnapshot_send_worker"
        run_sh = (self.repo / "tests/stage1/run.sh").read_text()
        required = [
            "send_destination_transport_checks.sh",
            "send_remote_retry_and_listing_checks.sh",
            "send_schedule_failure_window_checks.sh",
            "send_transport_command_checks.sh",
            "history_regression_checks.sh",
            "unraid_array_status_checks.sh",
        ]
        missing = [name for name in required if name not in run_sh or not (self.repo / "tests/stage1" / name).exists()]
        if missing:
            raise AssertionError("stage1 is not running the send regression cases: " + ", ".join(missing))
        schedule_checks = (self.repo / "tests/stage1/send_schedule_failure_window_checks.sh").read_text()
        listing_checks = (self.repo / "tests/stage1/send_remote_retry_and_listing_checks.sh").read_text()
        if "America/Chicago" not in schedule_checks or "fall-back" not in schedule_checks:
            raise AssertionError("DST fall-back coverage is missing from send_schedule_failure_window_checks.sh")
        if "unverified listing must not suggest purge/reseed" not in listing_checks:
            raise AssertionError("failed-listing no-reseed coverage is missing from send_remote_retry_and_listing_checks.sh")
        if "SEND_REMOTE_RETRY_DELAY_SECONDS=300" not in listing_checks:
            raise AssertionError("5-minute retry coverage is missing from send_remote_retry_and_listing_checks.sh")

        ops = ops_path.read_text()
        delete_worker = delete_path.read_text()
        send_worker = send_path.read_text()
        needles = {
            "ops-queue-lib.sh": [
                "run_zfs_for_transport() {",
                "list_snapshots_for_transport() {",
                "destroy_snapshot_for_transport() {",
                "rollback_snapshot_for_transport() {",
                "destroy_dataset_recursive_for_transport() {",
                "DEFAULT_SEND_REMOTE_MAX_ATTEMPTS=5",
                "DEFAULT_SEND_REMOTE_RETRY_DELAY_SECONDS=300",
                "SEND_COMMON_LISTING_UNVERIFIED=1",
                "FAILED_JOB_TTL_SECONDS",
                "local remote=\"zfs\"",
            ],
            "zfs_autosnapshot_delete_worker": [
                "destroy_snapshot_for_transport",
                'delete_single_snapshot "$snapshot" ssh',
                "QUEUE_SEND_TRANSPORT",
            ],
            "zfs_autosnapshot_send_worker": [
                'build_ssh_zfs_command "zfs destroy -r --',
                "mark_job_terminal_failure",
            ],
        }
        texts = {
            "ops-queue-lib.sh": ops,
            "zfs_autosnapshot_delete_worker": delete_worker,
            "zfs_autosnapshot_send_worker": send_worker,
        }
        absent = []
        for label, needed in needles.items():
            absent.extend(f"{label}: {needle}" for needle in needed if needle not in texts[label])
        if absent:
            raise AssertionError("recent send regression contracts missing: " + repr(absent))

        match = re.search(r"schedule_job_blocked\(\) \{.*?\n\}", ops, re.S)
        if not match:
            raise AssertionError("schedule_job_blocked() was not found")
        body = match.group(0)
        if "queued|running|retry_wait) return 0" not in body or re.search(r"(^|\|)failed\)", body):
            raise AssertionError("schedule_job_blocked must block queued|running|retry_wait and must not block failed")
        if 'zfs "$@"' not in ops.split("run_zfs_for_transport() {", 1)[1].split("\n}\n", 1)[0]:
            raise AssertionError("local transport must call the zfs command directly so tests can stub it")
        return "destination transport, retry, reseed, failed window, and DST cases are wired"

    def test_isolated_package_smoke(self) -> str:
        with tempfile.TemporaryDirectory(prefix="zfsas-harness-") as td:
            tmp_root = Path(td)
            tmp_repo = tmp_root / "repo"
            self._copy_repo_source(tmp_repo)
            version = (tmp_repo / "VERSION").read_text().strip()
            base_url = "https://example.invalid/zfsautosnapshot-harness/dist"
            self.cmd(["bash", "scripts/build-release.sh", version, base_url], cwd=tmp_repo, timeout=300)

            pkg = tmp_repo / "dist" / f"zfs-autosnapshot-{version}-noarch-1.txz"
            plg = tmp_repo / "dist" / "zfs.autosnapshot.plg"
            root_plg = tmp_repo / "zfs.autosnapshot.plg"
            icon = tmp_repo / "dist" / "zfs-autosnapshot.png"
            for path in [pkg, plg, root_plg, icon]:
                if not path.exists():
                    raise AssertionError(f"isolated build missing {path.relative_to(tmp_repo)}")

            md5 = hashlib.md5(pkg.read_bytes()).hexdigest()  # noqa: S324 - packaging compatibility check
            plg_text = plg.read_text()
            if md5 not in plg_text:
                raise AssertionError("isolated .plg MD5 does not match generated package")
            if "__VERSION__" in plg_text or "__BASE_URL__" in plg_text or "__PKG_MD5__" in plg_text:
                raise AssertionError("isolated .plg contains unreplaced template placeholders")
            self.cmd(["xmllint", "--noout", str(plg)], cwd=tmp_repo)

            with tarfile.open(pkg, "r:xz") as tf:
                names = [member.name.lstrip("./") for member in tf.getmembers()]
                missing = [member for member in REQUIRED_PACKAGE_MEMBERS if member not in names]
                if missing:
                    raise AssertionError("package missing members: " + ", ".join(missing))
                bad_metadata = [name for name in names if ".DS_Store" in name or "/._" in name or name.startswith("._")]
                if bad_metadata:
                    raise AssertionError("package contains macOS metadata: " + ", ".join(bad_metadata[:5]))

                fake_root = tmp_root / "fake-unraid-root"
                fake_root.mkdir()
                tf.extractall(fake_root)
                for member in REQUIRED_PACKAGE_MEMBERS:
                    if not (fake_root / member).exists():
                        raise AssertionError(f"fake install missing {member}")

            # Ensure the real repo was not contaminated by the package smoke test.
            real_status = self.cmd(["git", "status", "--short"], cwd=self.repo).stdout
            if "dist/" in real_status:
                raise AssertionError("real repo dist/ changed during isolated package smoke")
            return f"temp package {pkg.name} verified"

    def _copy_repo_source(self, destination: Path) -> None:
        ignore = shutil.ignore_patterns(
            ".git",
            ".pytest_cache",
            "__pycache__",
            "*.pyc",
        )
        shutil.copytree(self.repo, destination, ignore=ignore)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run external reusable tests for zfsautosnapshot-unraid.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """
            Modes:
              default: patch-verification mode; dirty working tree is allowed.
              --strict-clean: pre-push mode; fail if working tree is dirty.

            Rule: run this harness before every GitHub push, and before/after
            every patch verification. Source pushes must be source-only; GitHub
            Actions owns release artifact commits.

            Example:
              python3 tests/run_harness.py
              python3 tests/run_harness.py --strict-clean
            """
        ),
    )
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO, help=f"repo path (default: {DEFAULT_REPO})")
    parser.add_argument("--strict-clean", action="store_true", help="fail when repo has uncommitted changes; use before push")
    parser.add_argument("--skip-package-smoke", action="store_true", help="skip isolated temp package-generation smoke test")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    return Harness(args.repo, args.strict_clean, args.skip_package_smoke).run()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
