#!/usr/bin/env python3
"""Nested mounts must not abort a dataset migration or leave containers stopped."""
from __future__ import annotations

import os
import stat
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def write_cmdline(proc: Path, pid: str, args: list[str]) -> None:
    pid_dir = proc / pid
    pid_dir.mkdir(parents=True, exist_ok=True)
    (pid_dir / "comm").write_text(f"{Path(args[0]).name}\n", encoding="utf-8")
    data = b"\0".join(arg.encode() for arg in args) + b"\0"
    (pid_dir / "cmdline").write_bytes(data)


def mountinfo_line(target: Path, fstype: str, source: str) -> str:
    return f"20 1 0:40 / {target} rw,relatime - {fstype} {source} rw,allow_other"


def install_fakes(fakebin: Path, state: Path, mount: Path, mountinfo: Path) -> None:
    common = textwrap.dedent(
        """\
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$(basename "$0") $*" >> "$ZFSAS_TEST_OPERATION_LOG"
        """
    )
    write_executable(
        fakebin / "zfs",
        common
        + textwrap.dedent(
            f"""\
            state="{state}"
            mount="{mount}"
            cmd="${{1:-}}"
            shift || true
            dataset="${{@: -1}}"
            case "$cmd" in
              list)
                if [[ " $* " == *" -o avail "* ]]; then
                  printf '999999999999\\n'
                  exit 0
                fi
                if [[ " $* " == *" -t filesystem "* ]]; then
                  printf '%s\\t%s\\n' "tank/cache" "$mount"
                  if [[ -d "$state/datasets" ]]; then
                    find "$state/datasets" -type f -printf '%P\\n' | while IFS= read -r name; do
                      [[ -n "$name" ]] || continue
                      printf '%s\\t%s\\n' "$name" "$mount/$(basename "$name")"
                    done
                  fi
                  exit 0
                fi
                if [[ "$dataset" == "tank/cache" || -f "$state/datasets/$dataset" ]]; then
                  printf '%s\\n' "$dataset"
                  exit 0
                fi
                exit 1
                ;;
              get)
                if [[ " $* " == *" mounted "* ]]; then
                  printf 'yes\\n'
                  exit 0
                fi
                if [[ "$dataset" == "tank/cache" ]]; then
                  printf '%s\\n' "$mount"
                else
                  printf '%s\\n' "$mount/$(basename "$dataset")"
                fi
                exit 0
                ;;
              create)
                mkdir -p "$state/datasets/$(dirname "$dataset")"
                printf '%s\\n' "$dataset" > "$state/datasets/$dataset"
                mkdir -p "$mount/$(basename "$dataset")"
                exit 0
                ;;
              destroy)
                rm -rf "$mount/$(basename "$dataset")"
                rm -f "$state/datasets/$dataset"
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
            """
        ),
    )
    write_executable(
        fakebin / "rsync",
        common
        + textwrap.dedent(
            f"""\
            python3 - "$@" <<'PY'
            import os, shutil, sys
            args = sys.argv[1:]
            if "--itemize-changes" in args:
                raise SystemExit(0)
            src = args[-2].rstrip("/")
            dst = args[-1].rstrip("/")
            mountinfo = os.environ["ZFSAS_MIGRATOR_MOUNTINFO"]
            mounted = set()
            if os.path.exists(mountinfo):
                for line in open(mountinfo, encoding="utf-8"):
                    parts = line.split()
                    if len(parts) > 4:
                        mounted.add(parts[4])
            os.makedirs(dst, exist_ok=True)
            for name in os.listdir(src):
                source = os.path.join(src, name)
                if source in mounted or os.path.join(source, "") in mounted:
                    continue
                target = os.path.join(dst, name)
                if os.path.isdir(source) and not os.path.islink(source):
                    shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
                else:
                    shutil.copy2(source, target)
            PY
            """
        ),
    )
    write_executable(
        fakebin / "docker",
        common
        + textwrap.dedent(
            """\
            cmd="${1:-}"
            shift || true
            running="$ZFSAS_TEST_RUNNING"
            case "$cmd" in
              info)
                exit 0
                ;;
              ps)
                if [[ -s "$running" ]]; then
                  cat "$running"
                fi
                exit 0
                ;;
              update)
                spec=""
                cid=""
                for arg in "$@"; do
                  case "$arg" in
                    --restart=*) spec="${arg#--restart=}" ;;
                    *) cid="$arg" ;;
                  esac
                done
                printf '%s\\n' "docker-update $spec $cid" >> "$ZFSAS_TEST_OPERATION_LOG"
                exit 0
                ;;
              stop)
                grep -vxF "$1" "$running" > "$running.next" || true
                mv "$running.next" "$running"
                exit 0
                ;;
              start)
                grep -vxF "$1" "$running" > "$running.next" || true
                printf '%s\\n' "$1" >> "$running.next"
                mv "$running.next" "$running"
                printf '%s\\n' "docker-start $1" >> "$ZFSAS_TEST_OPERATION_LOG"
                exit 0
                ;;
              inspect)
                fmt=""
                if [[ "${1:-}" == "-f" ]]; then
                  fmt="${2:-}"
                  cid="${3:-}"
                else
                  cid="${1:-}"
                fi
                if [[ "$fmt" == *".State.Running"* ]]; then
                  if grep -qxF "$cid" "$running"; then
                    printf 'true\\n'
                  else
                    printf 'false\\n'
                  fi
                  exit 0
                fi
                if [[ "$fmt" == *".Mounts"* ]]; then
                  printf '%s\\n' "${ZFSAS_TEST_CONTAINER_MOUNT}"
                  exit 0
                fi
                policy="${ZFSAS_TEST_RESTART_POLICY:-unless-stopped}"
                printf '%s\\n' "${cid}|roleplay|${policy}|0|default||"
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
            """
        ),
    )
    write_executable(
        fakebin / "umount",
        common
        + textwrap.dedent(
            f"""\
            target=""
            for arg in "$@"; do
              [[ "$arg" == "--" ]] && continue
              target="$arg"
            done
            printf '%s\\n' "UMOUNT $target" >> "$ZFSAS_TEST_OPERATION_LOG"
            if [[ -f "{state}/umount-fail" ]]; then
              exit 1
            fi
            python3 - "$target" "{mountinfo}" <<'PY'
            import sys
            target, mountinfo = sys.argv[1], sys.argv[2]
            lines = open(mountinfo, encoding="utf-8").read().splitlines()
            kept = []
            for line in lines:
                parts = line.split()
                if len(parts) > 4 and parts[4] == target:
                    continue
                kept.append(line)
            open(mountinfo, "w", encoding="utf-8").write("\\n".join(kept) + ("\\n" if kept else ""))
            PY
            rm -f -- "$target/remote-only.txt"
            exit 0
            """
        ),
    )
    write_executable(
        fakebin / "rclone",
        common
        + textwrap.dedent(
            f"""\
            printf '%s\\n' "REMOUNT $*" >> "$ZFSAS_TEST_OPERATION_LOG"
            target=""
            for arg in "$@"; do
              if [[ -d "$arg" ]]; then
                target="$arg"
              fi
            done
            if [[ -n "$target" ]]; then
              printf '20 1 0:40 / %s rw,relatime - fuse.rclone remote:library rw,allow_other\\n' "$target" >> "{mountinfo}"
            fi
            exit 0
            """
        ),
    )
    for name in ("sleep", "shutdown"):
        write_executable(fakebin / name, common + "exit 0\n")


def run_worker(root: Path, args: list[str], extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{root / 'fakebin'}:{env.get('PATH', '')}",
            "ZFSAS_MIGRATOR_PLUGIN_ROOT": str(root / "plugin"),
            "ZFSAS_MIGRATOR_LOG_FILE": str(root / "worker.log"),
            "ZFSAS_MIGRATOR_LOG_ARCHIVE_FILE": str(root / "worker.archive.log"),
            "ZFSAS_MIGRATOR_LOCK_FILE": str(root / "migrator.lock"),
            "ZFSAS_MIGRATOR_MOUNTINFO": str(root / "mountinfo"),
            "ZFSAS_MIGRATOR_PROC_ROOT": str(root / "proc"),
            "ZFSAS_MIGRATOR_RECOVERY_BOOT_DELAY_SECONDS": "0",
            "ZFSAS_MIGRATOR_SERVICE_SETTLE_SECONDS": "0",
            "ZFSAS_MIGRATOR_SERVICE_STOP_WAIT_SECONDS": "0",
            "ZFSAS_MIGRATOR_RESTART_RETRY_DELAY": "0",
            "ZFSAS_MIGRATOR_UNMOUNT_RETRY_DELAY": "0",
            "ZFSAS_MIGRATOR_SPACE_RECHECK_SECONDS": "1",
            "ZFSAS_TEST_OPERATION_LOG": str(root / "operations.log"),
            "ZFSAS_TEST_RUNNING": str(root / "running"),
            "ZFSAS_TEST_CONTAINER_MOUNT": str(root / "mount" / "roleplay"),
            "ZFSAS_MIGRATOR_SPAWN_LOG": str(root / "spawn.log"),
        }
    )
    if extra_env:
        env.update(extra_env)
    try:
        return subprocess.run(
            [str(WORKER), *args],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"migrator timed out running {args}:\n{exc.output or ''}") from exc


def combined(root: Path, result: subprocess.CompletedProcess[str]) -> str:
    parts = [result.stdout or ""]
    for name in ("worker.log", "operations.log"):
        path = root / name
        if path.exists():
            parts.append(path.read_text(encoding="utf-8"))
    return "\n".join(parts)


def assert_ok(result: subprocess.CompletedProcess[str], text: str, label: str) -> None:
    if result.returncode != 0:
        raise AssertionError(f"{label} exited {result.returncode}:\n{text}")
    if "FATAL:" in text:
        raise AssertionError(f"{label} used a fatal per-folder stop:\n{text}")
    if "kill -9" in text or "umount -l" in text or "umount -f" in text:
        raise AssertionError(f"{label} used a forbidden stop:\n{text}")


def prepare_tree(root: Path, *, fuse: bool, zfs_child: bool, rclone_command: bool, container_running: bool) -> None:
    mount = root / "mount"
    role = mount / "roleplay"
    library = role / "library"
    beta = mount / "beta"
    library.mkdir(parents=True)
    beta.mkdir(parents=True)
    (role / "keep.txt").write_text("role local\n", encoding="utf-8")
    (library / "remote-only.txt").write_text("remote bytes\n", encoding="utf-8")
    (beta / "keep.txt").write_text("beta local\n", encoding="utf-8")
    lines = [f"10 1 0:39 / {mount} rw,relatime - zfs tank/cache rw"]
    if fuse:
        lines.append(mountinfo_line(library, "fuse.rclone", "remote:library"))
    if zfs_child:
        child = role / "child"
        child.mkdir()
        lines.append(mountinfo_line(child, "zfs", "tank/cache/roleplay/child"))
    (root / "mountinfo").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if rclone_command:
        write_cmdline(
            root / "proc",
            "4242",
            ["rclone", "mount", "remote:library", str(library), "--allow-other"],
        )
    (root / "running").write_text("cid-role\n" if container_running else "", encoding="utf-8")
    (root / "plugin").mkdir()
    (root / "state" / "datasets").mkdir(parents=True)
    install_fakes(root / "fakebin", root / "state", mount, root / "mountinfo")


def test_fuse_unmount_migrate_remount(tmp: Path) -> None:
    root = tmp / "fuse-ok"
    prepare_tree(root, fuse=True, zfs_child=False, rclone_command=True, container_running=True)
    result = run_worker(root, ["--dataset", "tank/cache"])
    text = combined(root, result)
    assert_ok(result, text, "fuse remount")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    umount_at = ops.find("UMOUNT ")
    copy_at = ops.find("roleplay.__migration_tmp__.", umount_at if umount_at >= 0 else 0)
    remount_at = ops.find("REMOUNT ")
    if umount_at < 0 or copy_at < 0 or remount_at < 0 or not (umount_at < copy_at < remount_at):
        raise AssertionError(f"unmount, copy, and remount were not in order:\n{ops}")
    if "remote:library" not in ops.split("REMOUNT ", 1)[1].splitlines()[0]:
        raise AssertionError(f"remount did not reuse the rclone source:\n{ops}")
    role = root / "mount" / "roleplay"
    if (role / "keep.txt").read_text(encoding="utf-8") != "role local\n":
        raise AssertionError("local file was not preserved on the new dataset")
    if not (role / "library").is_dir():
        raise AssertionError("nested mountpoint directory was not recreated")
    if (role / "library" / "remote-only.txt").exists():
        raise AssertionError("remote mount contents were copied into the dataset")
    if list(root.glob("mount/roleplay.__migration_tmp__.*")):
        raise AssertionError("temporary source was left behind after a clean remount")
    beta = (root / "mount" / "beta" / "keep.txt").read_text(encoding="utf-8")
    if beta != "beta local\n":
        raise AssertionError("the next folder was not migrated")
    folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
    if "\tcomplete\t" not in folders:
        raise AssertionError(f"folders were not marked complete:\n{folders}")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag remained after a finished queue")
    if "docker-update no " not in ops or "docker-update unless-stopped " not in ops:
        raise AssertionError(f"restart policy was not disabled and restored:\n{ops}")
    if "docker-start cid-role" not in ops:
        raise AssertionError(f"container was not started again:\n{ops}")


def test_fuse_skip_when_unmount_fails(tmp: Path) -> None:
    root = tmp / "fuse-skip"
    prepare_tree(root, fuse=True, zfs_child=False, rclone_command=True, container_running=True)
    (root / "state" / "umount-fail").write_text("1\n", encoding="utf-8")
    result = run_worker(root, ["--dataset", "tank/cache"])
    text = combined(root, result)
    assert_ok(result, text, "fuse skip")
    folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
    if "roleplay\t" not in folders or "\tskipped\t" not in folders:
        raise AssertionError(f"roleplay was not skipped:\n{folders}")
    if "could not be safely unmounted" not in folders:
        raise AssertionError(f"skip reason was not recorded:\n{folders}")
    if "beta\t" not in folders or "\tcomplete\t" not in folders:
        raise AssertionError(f"beta did not continue after the skip:\n{folders}")
    if not (root / "mount" / "roleplay" / "keep.txt").exists():
        raise AssertionError("skipped folder source was removed")
    if not (root / "mount" / "roleplay" / "library" / "remote-only.txt").exists():
        raise AssertionError("failed unmount removed mount contents")
    if list((root / "mount").glob("roleplay.__migration_tmp__.*")):
        raise AssertionError("skipped folder was renamed")
    if (root / "state" / "datasets" / "tank" / "cache" / "roleplay").exists() or (
        root / "state" / "datasets" / "tank/cache/roleplay"
    ).exists():
        raise AssertionError("a parent dataset was created for the skipped folder")
    created = (root / "state" / "datasets").rglob("*")
    names = [str(path.relative_to(root / "state" / "datasets")) for path in created if path.is_file()]
    if not any(name.endswith("beta") for name in names):
        raise AssertionError(f"beta dataset was not created: {names}")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag stayed set after the skipped folder")
    status = (root / "plugin" / "status.env").read_text(encoding="utf-8")
    if 'STATE="complete_with_failures"' not in status:
        raise AssertionError(f"finished status did not record the skip:\n{status}")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    if "docker-update no " not in ops or "docker-update unless-stopped " not in ops or "docker-start cid-role" not in ops:
        raise AssertionError(f"containers were not restored after the failed unmount:\n{ops}")
    kick = run_worker(root, ["--kick-if-idle"])
    kick_text = combined(root, kick)
    assert_ok(kick, kick_text, "kicker after skip")
    spawn = (root / "spawn.log").read_text(encoding="utf-8") if (root / "spawn.log").exists() else ""
    if "--dataset" in spawn or "--recover-pending" in spawn:
        raise AssertionError(f"kicker restarted a finished migration:\n{spawn}")


def test_nested_zfs_is_skipped(tmp: Path) -> None:
    root = tmp / "zfs-skip"
    prepare_tree(root, fuse=False, zfs_child=True, rclone_command=False, container_running=False)
    result = run_worker(root, ["--dataset", "tank/cache"])
    text = combined(root, result)
    assert_ok(result, text, "zfs skip")
    folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
    if "Nested ZFS dataset" not in folders or "\tskipped\t" not in folders:
        raise AssertionError(f"nested ZFS folder was not skipped:\n{folders}")
    if "zfs create tank/cache/roleplay" in text:
        raise AssertionError(f"parent dataset was created over a nested ZFS child:\n{text}")
    if "UMOUNT " in text:
        raise AssertionError(f"nested ZFS mount was unmounted:\n{text}")
    if (root / "mount" / "roleplay" / "keep.txt").read_text(encoding="utf-8") != "role local\n":
        raise AssertionError("ZFS skip changed the source folder")
    if (root / "mount" / "beta" / "keep.txt").read_text(encoding="utf-8") != "beta local\n":
        raise AssertionError("queue did not continue after the ZFS skip")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag remained after skipping the ZFS child")


def test_restart_policy_restored_after_crash(tmp: Path) -> None:
    root = tmp / "policy"
    prepare_tree(root, fuse=False, zfs_child=True, rclone_command=False, container_running=False)
    (root / "plugin" / "containers.tsv").write_text(
        "cid-role\troleplay\tunless-stopped\t0\t1\t1\tstopped\t\n",
        encoding="utf-8",
    )
    (root / "plugin" / "migration.inprogress").write_text(
        'DATASET="tank/cache"\nSTARTED_EPOCH="10"\nPID="10"\n',
        encoding="utf-8",
    )
    result = run_worker(root, ["--dataset", "tank/cache"])
    text = combined(root, result)
    assert_ok(result, text, "policy restore")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    update_at = ops.find("docker-update unless-stopped cid-role")
    start_at = ops.find("docker-start cid-role")
    if update_at < 0 or start_at < 0:
        raise AssertionError(f"saved restart policy was not restored and the container was not started:\n{ops}")
    if "docker-update no " in ops:
        raise AssertionError(f"restored container was stopped again for a skipped folder:\n{ops}")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("a previously looping migration left the in-progress flag set")
    if "unless-stopped" not in text:
        raise AssertionError(f"restore was not logged:\n{text}")


def main() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="zfsas-nested-mount-") as tmp:
        root = Path(tmp)
        test_fuse_unmount_migrate_remount(root)
        test_fuse_skip_when_unmount_fails(root)
        test_nested_zfs_is_skipped(root)
        test_restart_policy_restored_after_crash(root)
    print("PASS: dataset migrator nested mounts")


if __name__ == "__main__":
    main()
