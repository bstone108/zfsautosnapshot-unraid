#!/usr/bin/env python3
"""Behavioral checks for interrupted Dataset Migrator alerts, temp-folder recovery, and kicker restart."""
from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"

ALERT_SNIPPETS = (
    "Dataset migration was interrupted",
    "Apps may not function properly until the migration completes",
    "about 15 minutes",
    "ignore any non-functioning apps",
)


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def base_env(root: Path, plugin_root: Path, **extra: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "ZFSAS_MIGRATOR_PLUGIN_ROOT": str(plugin_root),
            "ZFSAS_MIGRATOR_LOG_FILE": str(root / "worker.log"),
            "ZFSAS_MIGRATOR_LOG_ARCHIVE_FILE": str(root / "worker.archive.log"),
            "ZFSAS_MIGRATOR_LOCK_FILE": str(root / "migrator.lock"),
            "ZFSAS_MIGRATOR_RECOVERY_BOOT_DELAY_SECONDS": "0",
            "ZFSAS_MIGRATOR_RESTART_RETRY_DELAY": "0",
            "ZFSAS_NOTIFY_BIN": str(root / "fakebin" / "notify"),
        }
    )
    env.update(extra)
    return env


def install_command_stubs(fakebin: Path) -> None:
    for name in ("zfs", "rsync", "docker"):
        write_executable(fakebin / name, "#!/usr/bin/env bash\nexit 0\n")


def install_notify(fakebin: Path, log_path: Path) -> None:
    write_executable(
        fakebin / "notify",
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            printf '%s\\n' "$*" >> {str(log_path)!r}
            """
        ),
    )


def run_worker(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [str(WORKER), *args],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"worker timed out running {args}:\n{exc.output or ''}") from exc


def assert_ok(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(f"{label} failed with {result.returncode}:\n{result.stdout}")


def assert_alert(notify_log: Path) -> None:
    text = notify_log.read_text(encoding="utf-8") if notify_log.exists() else ""
    missing = [snippet for snippet in ALERT_SNIPPETS if snippet not in text]
    if missing:
        raise AssertionError(f"Unraid alert missing {missing!r}:\n{text}")
    if " -i alert" not in f" {text}":
        raise AssertionError(f"Unraid alert must use importance alert:\n{text}")


def install_recovery_fakes(fakebin: Path, operation_log: Path, destination: Path) -> None:
    fake_common = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$(basename \"$0\") $*\" >> \"$ZFSAS_TEST_OPERATION_LOG\"\n"
    )
    write_executable(
        fakebin / "zfs",
        fake_common
        + "case \"${1:-}\" in\n"
        + "  list) if [[ \" $* \" == *\" -o avail \"* ]]; then printf '9999999999\\n'; fi; exit 0 ;;\n"
        + "  create) mkdir -p \"$ZFSAS_TEST_DESTINATION\"; exit 0 ;;\n"
        + "  get) printf '%s\\n' \"$ZFSAS_TEST_MOUNTPOINT\"; exit 0 ;;\n"
        + "  *) exit 0 ;;\n"
        + "esac\n",
    )
    write_executable(
        fakebin / "docker",
        fake_common
        + "cmd=\"${1:-}\"; shift || true\n"
        + "case \"$cmd\" in\n"
        + "  info) exit 0 ;;\n"
        + "  update) exit 0 ;;\n"
        + "  stop) exit 0 ;;\n"
        + "  start) exit 0 ;;\n"
        + "  inspect) printf 'true\\n'; exit 0 ;;\n"
        + "  ps) exit 0 ;;\n"
        + "esac\n",
    )
    write_executable(
        fakebin / "rsync",
        fake_common
        + "python3 - \"$@\" <<'PY'\n"
        + "import os, shutil, sys\n"
        + "src = sys.argv[-2].rstrip('/')\n"
        + "dst = sys.argv[-1].rstrip('/')\n"
        + "os.makedirs(dst, exist_ok=True)\n"
        + "for name in os.listdir(dst):\n"
        + "    path = os.path.join(dst, name)\n"
        + "    shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.unlink(path)\n"
        + "for name in os.listdir(src):\n"
        + "    s = os.path.join(src, name); d = os.path.join(dst, name)\n"
        + "    shutil.copytree(s, d, symlinks=True) if os.path.isdir(s) and not os.path.islink(s) else shutil.copy2(s, d)\n"
        + "PY\n",
    )
    write_executable(fakebin / "sleep", fake_common + "exit 0\n")
    os.environ["ZFSAS_TEST_OPERATION_LOG"] = str(operation_log)
    os.environ["ZFSAS_TEST_DESTINATION"] = str(destination)


def test_kick_restarts_recovery_and_alerts_once() -> None:
    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-kick-") as tmp:
        root = Path(tmp)
        plugin_root = root / "plugin"
        fakebin = root / "fakebin"
        plugin_root.mkdir()
        fakebin.mkdir()
        notify_log = root / "notify.log"
        spawn_log = root / "spawn.log"
        install_command_stubs(fakebin)
        install_notify(fakebin, notify_log)
        (plugin_root / "recovery.env").write_text(
            'RECOVERY_PHASE="renamed_source"\nRECOVERY_TEMP_PATH="/tmp/app.__migration_tmp__.1.2.3"\n'
            'RECOVERY_TARGET_DATASET="tank/user/app"\nDATASET="tank/user"\n',
            encoding="utf-8",
        )
        (plugin_root / "migration.inprogress").write_text('DATASET="tank/user"\nSTARTED_EPOCH="10"\nPID="10"\n', encoding="utf-8")
        env = base_env(
            root,
            plugin_root,
            PATH=f"{fakebin}:{os.environ.get('PATH', '')}",
            ZFSAS_MIGRATOR_SPAWN_LOG=str(spawn_log),
        )
        first = run_worker(["--kick-if-idle"], env)
        assert_ok(first, "kick recovery")
        second = run_worker(["--kick-if-idle"], env)
        assert_ok(second, "kick recovery duplicate")
        spawned = spawn_log.read_text(encoding="utf-8") if spawn_log.exists() else ""
        if spawned.strip().count("--recover-pending") != 2:
            raise AssertionError(f"idle kicker should restart --recover-pending once per idle check:\n{spawned}")
        if "--dataset" in spawned:
            raise AssertionError(f"recovery state must win over a fresh dataset restart:\n{spawned}")
        assert_alert(notify_log)
        alerts = notify_log.read_text(encoding="utf-8").strip().splitlines()
        if len(alerts) != 1:
            raise AssertionError(f"interruption alert must be sent once per recovery episode:\n{alerts}")


def test_kick_restarts_dataset_without_fifteen_minute_alert() -> None:
    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-kick-dataset-") as tmp:
        root = Path(tmp)
        plugin_root = root / "plugin"
        fakebin = root / "fakebin"
        plugin_root.mkdir()
        fakebin.mkdir()
        notify_log = root / "notify.log"
        spawn_log = root / "spawn.log"
        install_command_stubs(fakebin)
        install_notify(fakebin, notify_log)
        (plugin_root / "migration.inprogress").write_text('DATASET="tank/user"\nSTARTED_EPOCH="10"\nPID="10"\n', encoding="utf-8")
        env = base_env(
            root,
            plugin_root,
            PATH=f"{fakebin}:{os.environ.get('PATH', '')}",
            ZFSAS_MIGRATOR_SPAWN_LOG=str(spawn_log),
        )
        result = run_worker(["--kick-if-idle"], env)
        assert_ok(result, "kick dataset")
        spawned = spawn_log.read_text(encoding="utf-8") if spawn_log.exists() else ""
        if spawned.strip() != "--dataset tank/user":
            raise AssertionError(f"in-progress flag should restart the recorded dataset:\n{spawned!r}")
        if notify_log.exists() and notify_log.read_text(encoding="utf-8").strip():
            raise AssertionError("dataset resume without recovery.env must not send the 15-minute interruption alert")


def test_kick_skips_running_migrator_and_stopped_array() -> None:
    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-kick-skip-") as tmp:
        root = Path(tmp)
        plugin_root = root / "plugin"
        fakebin = root / "fakebin"
        plugin_root.mkdir()
        fakebin.mkdir()
        notify_log = root / "notify.log"
        spawn_log = root / "spawn.log"
        install_command_stubs(fakebin)
        install_notify(fakebin, notify_log)
        (plugin_root / "recovery.env").write_text('DATASET="tank/user"\nRECOVERY_TEMP_PATH="/tmp/x"\n', encoding="utf-8")
        lock = root / "migrator.lock"
        lock.touch()
        holder = subprocess.Popen(["flock", "-x", str(lock), "sleep", "20"])
        deadline = time.time() + 2
        while time.time() < deadline:
            probe = subprocess.run(["flock", "-n", str(lock), "true"], check=False)
            if probe.returncode != 0:
                break
            time.sleep(0.05)
        else:
            holder.kill()
            raise AssertionError("failed to hold the migrator lock for the idle-kicker check")
        try:
            env = base_env(
                root,
                plugin_root,
                PATH=f"{fakebin}:{os.environ.get('PATH', '')}",
                ZFSAS_MIGRATOR_SPAWN_LOG=str(spawn_log),
            )
            result = run_worker(["--kick-if-idle"], env)
            assert_ok(result, "kick while locked")
            spawned = spawn_log.read_text(encoding="utf-8") if spawn_log.exists() else ""
            if spawned.strip():
                raise AssertionError(f"kicker must not restart a migrator that still holds the lock:\n{spawned}")
        finally:
            holder.terminate()
            holder.wait(timeout=5)

        stopped = root / "var.ini"
        stopped.write_text('mdState="STOPPED"\n', encoding="utf-8")
        env = base_env(
            root,
            plugin_root,
            PATH=f"{fakebin}:{os.environ.get('PATH', '')}",
            ZFSAS_MIGRATOR_SPAWN_LOG=str(spawn_log),
            ZFSAS_UNRAID_VAR_INI=str(stopped),
        )
        result = run_worker(["--kick-if-idle"], env)
        assert_ok(result, "kick while array stopped")
        spawned = spawn_log.read_text(encoding="utf-8") if spawn_log.exists() else ""
        if spawned.strip():
            raise AssertionError(f"kicker must wait until the array is actionable:\n{spawned}")
        if notify_log.exists() and notify_log.read_text(encoding="utf-8").strip():
            raise AssertionError("kicker must not alert when it cannot resume yet")


def test_recover_pending_synthesizes_temp_folder_and_alerts() -> None:
    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-temp-") as tmp:
        root = Path(tmp)
        plugin_root = root / "plugin"
        fakebin = root / "fakebin"
        mount = root / "mnt" / "user"
        temp_source = mount / "app.__migration_tmp__.100.200.300"
        destination = mount / "app"
        ignored = mount / "notes.__migration_tmp__.bak"
        operation_log = root / "operations.log"
        notify_log = root / "notify.log"
        plugin_root.mkdir()
        fakebin.mkdir()
        temp_source.mkdir(parents=True)
        destination.mkdir()
        ignored.mkdir()
        (temp_source / "kept.txt").write_text("fresh data\n", encoding="utf-8")
        (destination / "stale.txt").write_text("must be deleted\n", encoding="utf-8")
        (ignored / "leave.txt").write_text("not a migration temp\n", encoding="utf-8")
        (plugin_root / "migration.inprogress").write_text('DATASET="tank/user"\nSTARTED_EPOCH="10"\nPID="10"\n', encoding="utf-8")
        install_notify(fakebin, notify_log)
        install_recovery_fakes(fakebin, operation_log, destination)
        env = base_env(root, plugin_root)
        env["PATH"] = f"{fakebin}:{env['PATH']}"
        env["ZFSAS_TEST_OPERATION_LOG"] = str(operation_log)
        env["ZFSAS_TEST_DESTINATION"] = str(destination)
        env["ZFSAS_TEST_MOUNTPOINT"] = str(mount)
        result = run_worker(["--recover-pending"], env)
        assert_ok(result, "synthesized recovery")
        assert_alert(notify_log)
        if (destination / "stale.txt").exists():
            raise AssertionError("synthesized recovery did not replace the destination from the temp folder")
        if (destination / "kept.txt").read_text(encoding="utf-8") != "fresh data\n":
            raise AssertionError("synthesized recovery did not keep the original folder contents")
        if temp_source.exists():
            raise AssertionError("synthesized recovery left the deterministic temp folder behind")
        if not ignored.exists():
            raise AssertionError("recovery removed a directory that is not a deterministic migration temp folder")
        if (plugin_root / "recovery.env").exists():
            raise AssertionError("recovery.env should be cleared after synthesized recovery")
        if not (plugin_root / "migration.inprogress").exists():
            raise AssertionError("recovering one folder must keep the in-progress flag so remaining folders can resume")
        log_text = (root / "worker.log").read_text(encoding="utf-8") if (root / "worker.log").exists() else ""
        output = f"{result.stdout}\n{log_text}"
        if "original folder 'app'" not in output and 'original folder "app"' not in output:
            raise AssertionError(f"recovery did not record the original folder name:\n{output}")


def main() -> None:
    test_kick_restarts_recovery_and_alerts_once()
    test_kick_restarts_dataset_without_fifteen_minute_alert()
    test_kick_skips_running_migrator_and_stopped_array()
    test_recover_pending_synthesizes_temp_folder_and_alerts()
    print("PASS: Dataset Migrator interruption alert and kicker restart")


if __name__ == "__main__":
    main()
