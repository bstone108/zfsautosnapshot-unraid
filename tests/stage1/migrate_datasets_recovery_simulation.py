#!/usr/bin/env python3
"""Non-destructive simulation for Dataset Migrator boot recovery."""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-recovery-") as tmp:
        root = Path(tmp)
        plugin_root = root / "plugin"
        fakebin = root / "fakebin"
        temp_source = root / "mnt/user/app.__migration_tmp__.123"
        destination = root / "mnt/user/app"
        operation_log = root / "operations.log"
        plugin_root.mkdir(parents=True)
        fakebin.mkdir()
        temp_source.mkdir(parents=True)
        destination.mkdir(parents=True)

        (temp_source / "kept.txt").write_text("fresh data\n", encoding="utf-8")
        (temp_source / "nested").mkdir()
        (temp_source / "nested" / "file.txt").write_text("nested fresh\n", encoding="utf-8")
        (destination / "stale.txt").write_text("must be deleted\n", encoding="utf-8")

        (plugin_root / "recovery.env").write_text(
            f'''RECOVERY_PHASE="dataset_created"\n'''
            f'''RECOVERY_FOLDER_INDEX="0"\n'''
            f'''RECOVERY_SOURCE_PATH="{destination}"\n'''
            f'''RECOVERY_TEMP_PATH="{temp_source}"\n'''
            f'''RECOVERY_TARGET_DATASET="tank/user/app"\n'''
            f'''RECOVERY_BATCH_CONTAINERS="0 1"\n'''
            f'''DATASET="tank/user"\n'''
            f'''STARTED_EPOCH="100"\n''',
            encoding="utf-8",
        )
        (plugin_root / "folders.tsv").write_text(
            f"app\t{destination}\ttank/user/app\t123\tmigrating\t50\tInterrupted\n",
            encoding="utf-8",
        )
        (plugin_root / "containers.tsv").write_text(
            "cid111\tapp-db\talways\t0\t1\t1\trecovery_pending\t\n"
            "cid222\tapp-web\ton-failure\t3\t1\t1\trecovery_pending\t\n"
            "cid333\tunrelated\talways\t0\t1\t1\trunning\t\n",
            encoding="utf-8",
        )

        fake_common = "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$(basename \"$0\") $*\" >> \"$ZFSAS_TEST_OPERATION_LOG\"\n"
        write_executable(
            fakebin / "zfs",
            fake_common
            + "case \"${1:-}\" in\n"
            + "  list) if [[ \" $* \" == *\" -o avail \"* ]]; then printf '9999999999\\n'; fi; exit 0 ;;\n"
            + "  create) mkdir -p \"$ZFSAS_TEST_DESTINATION\"; exit 0 ;;\n"
            + "  get) printf '%s\\n' \"$ZFSAS_TEST_DESTINATION\"; exit 0 ;;\n"
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
            + "  stop) cid=\"$1\"; state_var=\"ZFSAS_TEST_STATE_${cid}\"; printf 'false' > \"${!state_var}\"; exit 0 ;;\n"
            + "  start) cid=\"$1\"; state_var=\"ZFSAS_TEST_STATE_${cid}\"; printf 'true' > \"${!state_var}\"; exit 0 ;;\n"
            + "  inspect)\n"
            + "    if [[ \"${1:-}\" == '-f' ]]; then shift; fmt=\"$1\"; shift; cid=\"$1\"; else cid=\"$1\"; fi\n"
            + "    state_var=\"ZFSAS_TEST_STATE_${cid}\"\n"
            + "    if [[ \"${fmt:-}\" == '{{.State.Running}}' ]]; then cat \"${!state_var}\" 2>/dev/null || printf 'true'; else printf '\\n'; fi\n"
            + "    exit 0 ;;\n"
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

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{fakebin}:{env['PATH']}",
                "ZFSAS_MIGRATOR_PLUGIN_ROOT": str(plugin_root),
                "ZFSAS_MIGRATOR_LOG_FILE": str(root / "worker.log"),
                "ZFSAS_MIGRATOR_LOG_ARCHIVE_FILE": str(root / "worker.archive.log"),
                "ZFSAS_MIGRATOR_LOCK_FILE": str(root / "migrator.lock"),
                "ZFSAS_MIGRATOR_RECOVERY_BOOT_DELAY_SECONDS": "0",
                "ZFSAS_MIGRATOR_RESTART_RETRY_DELAY": "0",
                "ZFSAS_TEST_OPERATION_LOG": str(operation_log),
                "ZFSAS_TEST_DESTINATION": str(destination),
                "ZFSAS_TEST_STATE_cid111": str(root / "cid111.running"),
                "ZFSAS_TEST_STATE_cid222": str(root / "cid222.running"),
                "ZFSAS_TEST_STATE_cid333": str(root / "cid333.running"),
            }
        )
        for cid in ("cid111", "cid222", "cid333"):
            (root / f"{cid}.running").write_text("true", encoding="utf-8")

        try:
            result = subprocess.run(
                [str(WORKER), "--recover-pending"],
                cwd=str(ROOT),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
            )
        except subprocess.TimeoutExpired as exc:
            ops = operation_log.read_text(encoding="utf-8") if operation_log.exists() else ""
            raise AssertionError(
                f"recovery simulation timed out\n--- operations ---\n{ops}\n--- output ---\n{exc.output or ''}"
            ) from exc
        if result.returncode != 0:
            raise AssertionError(f"recovery simulation failed with {result.returncode}:\n{result.stdout}")

        ops = operation_log.read_text(encoding="utf-8") if operation_log.exists() else ""
        expected_order = [
            "sleep 0",
            "docker stop cid222",
            "docker stop cid111",
            "rsync -aHAXx --delete --numeric-ids",
            "docker start cid111",
            "docker start cid222",
            "docker update --restart=always cid111",
            "docker update --restart=on-failure:3 cid222",
        ]
        cursor = 0
        for marker in expected_order:
            found = ops.find(marker, cursor)
            if found == -1:
                raise AssertionError(f"operation log missing/in wrong order: {marker}\n--- operations ---\n{ops}\n--- output ---\n{result.stdout}")
            cursor = found + len(marker)
        if "cid333" in ops:
            raise AssertionError(f"recovery touched unrelated container cid333:\n{ops}")
        if (destination / "stale.txt").exists():
            raise AssertionError("recovery rsync did not delete stale destination files")
        if not (destination / "kept.txt").exists() or (destination / "kept.txt").read_text(encoding="utf-8") != "fresh data\n":
            raise AssertionError("recovery did not copy fresh source contents into destination")
        if (plugin_root / "recovery.env").exists():
            raise AssertionError("recovery.env should be cleared after successful exact-sync recovery")
        status = (plugin_root / "status.env").read_text(encoding="utf-8")
        if 'STATE="complete"' not in status or 'CURRENT_STEP="recovery_complete"' not in status:
            raise AssertionError(f"status.env did not report recovery completion:\n{status}")

    print("PASS: Dataset Migrator recovery simulation")


if __name__ == "__main__":
    main()
