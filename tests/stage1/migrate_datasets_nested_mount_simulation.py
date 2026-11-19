#!/usr/bin/env python3
"""Nested mounts must not abort a dataset migration or leave containers stopped."""
from __future__ import annotations

import os
import signal
import stat
import subprocess
import textwrap
import time
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
            """\
            python3 - "$@" <<'PY'
            import os, shutil, sys
            args = sys.argv[1:]
            log_path = os.environ["ZFSAS_TEST_OPERATION_LOG"]
            mountinfo = os.environ["ZFSAS_MIGRATOR_MOUNTINFO"]
            mounted = set()
            if os.path.exists(mountinfo):
                for line in open(mountinfo, encoding="utf-8"):
                    parts = line.split()
                    if len(parts) > 4:
                        mounted.add(os.path.realpath(parts[4]))

            def excluded(rel):
                rel = rel.strip("/")
                index = 0
                while index < len(args):
                    if args[index] == "--exclude" and index + 1 < len(args):
                        pattern = args[index + 1].strip("/")
                        base = pattern[:-3] if pattern.endswith("/**") else pattern
                        if rel == base or rel.startswith(base + "/"):
                            return True
                    index += 1
                return False

            def note_fuse(full, rel):
                if not excluded(rel):
                    with open(log_path, "a", encoding="utf-8") as handle:
                        handle.write(f"FUSE-READ {full}\\n")

            def snapshot(root):
                found = {}
                if not os.path.isdir(root):
                    return found
                for dirpath, dirnames, filenames in os.walk(root):
                    rel_dir = os.path.relpath(dirpath, root)
                    if rel_dir == ".":
                        rel_dir = ""
                    kept = []
                    for name in dirnames:
                        rel = name if not rel_dir else os.path.join(rel_dir, name)
                        full = os.path.join(dirpath, name)
                        if os.path.realpath(full) in mounted or excluded(rel):
                            if os.path.realpath(full) in mounted:
                                note_fuse(full, rel)
                            continue
                        kept.append(name)
                    dirnames[:] = kept
                    for name in filenames:
                        rel = name if not rel_dir else os.path.join(rel_dir, name)
                        if excluded(rel):
                            continue
                        full = os.path.join(dirpath, name)
                        with open(full, "rb") as handle:
                            found[rel] = handle.read()
                return found

            if "--itemize-changes" in args:
                src = args[-2].rstrip("/")
                dst = args[-1].rstrip("/")
                left = snapshot(src)
                right = snapshot(dst)
                if left != right:
                    print("checksum mismatch")
                    raise SystemExit(1)
                raise SystemExit(0)
            src = args[-2].rstrip("/")
            dst = args[-1].rstrip("/")
            os.makedirs(dst, exist_ok=True)
            for name in os.listdir(src):
                source = os.path.join(src, name)
                if os.path.realpath(source) in mounted or excluded(name):
                    if os.path.realpath(source) in mounted:
                        note_fuse(source, name)
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
                if [[ -n "${ZFSAS_TEST_FAIL_START_ONCE:-}" && "$1" == "$ZFSAS_TEST_FAIL_START_ONCE" && -n "${ZFSAS_TEST_FAIL_START_DONE:-}" && ! -f "$ZFSAS_TEST_FAIL_START_DONE" ]]; then
                  printf '%s\\n' "docker-start-fail $1" >> "$ZFSAS_TEST_OPERATION_LOG"
                  touch "$ZFSAS_TEST_FAIL_START_DONE"
                  exit 1
                fi
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
                if [[ -n "${ZFSAS_TEST_DOCKER_SPEC:-}" && -f "$ZFSAS_TEST_DOCKER_SPEC" ]]; then
                  spec_line="$(awk -F '|' -v id="$cid" '$1 == id { print; exit }' "$ZFSAS_TEST_DOCKER_SPEC")"
                  if [[ -n "$spec_line" ]]; then
                    printf '%s\\n' "$spec_line"
                    exit 0
                  fi
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
            mode="${{ZFSAS_TEST_RCLONE_MODE:-exit}}"
            if [[ "$mode" != "hang" && -n "$target" ]]; then
              printf '20 1 0:40 / %s rw,relatime - fuse.rclone remote:library rw,allow_other\\n' "$target" >> "{mountinfo}"
            fi
            if [[ "$mode" == "hang" || "$mode" == "sleep" ]]; then
              if [[ -n "${{ZFSAS_TEST_RCLONE_PID:-}}" ]]; then
                printf '%s\\n' "$$" > "$ZFSAS_TEST_RCLONE_PID"
              fi
              exec /bin/sleep 300
            fi
            exit 0
            """
        ),
    )
    write_executable(
        fakebin / "find",
        common
        + textwrap.dedent(
            f"""\
            python3 - "$@" <<'PY'
            import os, sys
            args = sys.argv[1:]
            if "-prune" in args or "-xdev" in args or "-maxdepth" in args:
                raise SystemExit(0)
            mountinfo = os.environ.get("ZFSAS_MIGRATOR_MOUNTINFO", "")
            mounted = []
            if mountinfo and os.path.exists(mountinfo):
                for line in open(mountinfo, encoding="utf-8"):
                    parts = line.split()
                    if len(parts) > 4 and (" fuse." in line or " fuse " in line):
                        mounted.append(os.path.realpath(parts[4]))
            starts = [arg for arg in args if not arg.startswith("-")]
            start = os.path.realpath(starts[0] if starts else ".")
            cwd = os.path.realpath(os.getcwd())
            root = start if os.path.isabs(starts[0] if starts else "") else cwd
            log_path = os.environ.get("ZFSAS_TEST_OPERATION_LOG", "")
            for mountpoint in mounted:
                if mountpoint == root or mountpoint.startswith(root + os.sep):
                    if log_path:
                        with open(log_path, "a", encoding="utf-8") as handle:
                            handle.write(f"FUSE-READ {{mountpoint}}\\n")
                    break
            PY
            exec /usr/bin/find "$@"
            """
        ),
    )
    write_executable(
        fakebin / "sha256sum",
        common
        + textwrap.dedent(
            f"""\
            if [[ "${{ZFSAS_TEST_DROP_MOUNT_ON_HASH:-0}}" == "1" && ! -f "${{ZFSAS_TEST_MOUNT_DROPPED:-/tmp/missing-drop}}" ]]; then
              touch "$ZFSAS_TEST_MOUNT_DROPPED"
              python3 - "{mountinfo}" <<'PY'
            import sys
            mountinfo = sys.argv[1]
            lines = open(mountinfo, encoding="utf-8").read().splitlines()
            kept = [line for line in lines if "fuse.rclone" not in line]
            open(mountinfo, "w", encoding="utf-8").write("\\n".join(kept) + ("\\n" if kept else ""))
            PY
            fi
            python3 - "$@" <<'PY'
            import os, sys
            mountinfo = os.environ.get("ZFSAS_MIGRATOR_MOUNTINFO", "")
            mounted = []
            if mountinfo and os.path.exists(mountinfo):
                for line in open(mountinfo, encoding="utf-8"):
                    parts = line.split()
                    if len(parts) > 4 and (" fuse." in line or " fuse " in line):
                        mounted.append(os.path.realpath(parts[4]))
            log_path = os.environ.get("ZFSAS_TEST_OPERATION_LOG", "")
            cwd = os.path.realpath(os.getcwd())
            for arg in sys.argv[1:]:
                if arg.startswith("-"):
                    continue
                path = arg if os.path.isabs(arg) else os.path.realpath(os.path.join(cwd, arg))
                for mountpoint in mounted:
                    if path == mountpoint or path.startswith(mountpoint + os.sep):
                        if log_path:
                            with open(log_path, "a", encoding="utf-8") as handle:
                                handle.write(f"FUSE-READ {{path}}\\n")
            PY
            exec /usr/bin/sha256sum "$@"
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
            "ZFSAS_MIGRATOR_RELEASE_HELPER": str(
                ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/migrator-release-stuck.py"
            ),
            "ZFSAS_TEST_RCLONE_PID": str(root / "rclone.pid"),
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
    verify_at = ops.find("--itemize-changes", copy_at)
    start_at = ops.find("docker-start cid-role")
    if verify_at < 0 or not (copy_at < verify_at < remount_at < start_at):
        raise AssertionError(f"verify, remount, and container start were not in order:\n{ops}")
    if "FUSE-READ " in ops:
        raise AssertionError(f"verification read through a nested mount:\n{ops}")
    if "Verification finished for 'roleplay' before nested mounts are restored." not in text:
        raise AssertionError(f"verification was not logged before the remount:\n{text}")
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


def kill_process_tree(pid: int) -> None:
    children: list[int] = []
    proc_root = Path("/proc")
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            status = (entry / "status").read_text(encoding="utf-8")
        except OSError:
            continue
        for line in status.splitlines():
            if line.startswith("PPid:") and line.split()[-1] == str(pid):
                children.append(int(entry.name))
                break
    for child in children:
        kill_process_tree(child)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return


def stop_recorded_helper(root: Path) -> None:
    pid_file = root / "rclone.pid"
    if not pid_file.exists():
        return
    pid_text = pid_file.read_text(encoding="utf-8").strip()
    if pid_text.isdigit():
        kill_process_tree(int(pid_text))


def session_id(pid: int) -> int:
    stat_text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    fields = stat_text.rsplit(")", 1)[1].split()
    return int(fields[3])


def assert_helper_detached(pid: int) -> None:
    status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
    ppid = ""
    for line in status.splitlines():
        if line.startswith("PPid:"):
            ppid = line.split()[-1]
    if ppid != "1":
        raise AssertionError(f"remount helper {pid} is still a child of {ppid}")
    if session_id(pid) != pid:
        raise AssertionError(f"remount helper {pid} did not get its own session")


def test_remount_returns_while_helper_runs(tmp: Path) -> None:
    root = tmp / "detach"
    prepare_tree(root, fuse=True, zfs_child=False, rclone_command=True, container_running=True)
    started = time.monotonic()
    try:
        result = run_worker(
            root,
            ["--dataset", "tank/cache"],
            {"ZFSAS_TEST_RCLONE_MODE": "sleep", "ZFSAS_MIGRATOR_REMOUNT_POLL_SECONDS": "0.2"},
        )
        elapsed = time.monotonic() - started
        text = combined(root, result)
        assert_ok(result, text, "detached remount")
        if elapsed > 15:
            raise AssertionError(f"detached remount took {elapsed:.1f}s")
        pid_text = (root / "rclone.pid").read_text(encoding="utf-8").strip()
        if not pid_text.isdigit() or not Path(f"/proc/{pid_text}").exists():
            raise AssertionError(f"background remount helper is not running: {pid_text}")
        assert_helper_detached(int(pid_text))
        if "in the background" not in text or "Remounted nested" not in text:
            raise AssertionError(f"remount was not acknowledged:\n{text}")
        if list(root.glob("mount/roleplay.__migration_tmp__.*")):
            raise AssertionError("temporary source remained after a detached remount")
        if "FUSE-READ " in text:
            raise AssertionError(f"verification read through a nested mount:\n{text}")
    finally:
        stop_recorded_helper(root)


def test_remount_timeout_needs_attention(tmp: Path) -> None:
    root = tmp / "timeout"
    prepare_tree(root, fuse=True, zfs_child=False, rclone_command=True, container_running=True)
    started = time.monotonic()
    try:
        result = run_worker(
            root,
            ["--dataset", "tank/cache"],
            {
                "ZFSAS_TEST_RCLONE_MODE": "hang",
                "ZFSAS_MIGRATOR_REMOUNT_TIMEOUT": "2",
                "ZFSAS_MIGRATOR_REMOUNT_POLL_SECONDS": "0.2",
            },
        )
        elapsed = time.monotonic() - started
        text = combined(root, result)
        assert_ok(result, text, "remount timeout")
        if elapsed > 20:
            raise AssertionError(f"remount timeout path took {elapsed:.1f}s")
        folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
        if "roleplay\t" not in folders or "migrated, remount needs attention" not in folders:
            raise AssertionError(f"folder was not marked for remount attention:\n{folders}")
        if "\tattention\t" not in folders:
            raise AssertionError(f"attention state was not recorded:\n{folders}")
        if not list(root.glob("mount/roleplay.__migration_tmp__.*")):
            raise AssertionError("temporary source was removed after a remount timeout")
        if "beta\t" not in folders or "\tcomplete\t" not in folders:
            raise AssertionError(f"queue did not continue after the remount timeout:\n{folders}")
        if "zfs destroy" in text or "Destroyed dataset" in text:
            raise AssertionError(f"a verified dataset was destroyed after remount timeout:\n{text}")
        if "was not signaled" not in text or "timed out" not in text:
            raise AssertionError(f"timeout was not logged:\n{text}")
        if (root / "plugin" / "migration.inprogress").exists():
            raise AssertionError("in-progress flag remained after the timeout path")
        ops = (root / "operations.log").read_text(encoding="utf-8")
        if "docker-update unless-stopped " not in ops or "docker-start cid-role" not in ops:
            raise AssertionError(f"containers were not restored after the remount timeout:\n{ops}")
        pid_text = (root / "rclone.pid").read_text(encoding="utf-8").strip()
        if not pid_text.isdigit() or not Path(f"/proc/{pid_text}").exists():
            raise AssertionError("timed-out remount helper was not left running")
        assert_helper_detached(int(pid_text))
    finally:
        stop_recorded_helper(root)


def test_external_unmount_skips_remount(tmp: Path) -> None:
    root = tmp / "external"
    prepare_tree(root, fuse=True, zfs_child=False, rclone_command=True, container_running=False)
    result = run_worker(
        root,
        ["--dataset", "tank/cache"],
        {
            "ZFSAS_TEST_DROP_MOUNT_ON_HASH": "1",
            "ZFSAS_TEST_MOUNT_DROPPED": str(root / "dropped"),
        },
    )
    # The marker must not exist before the run, or the drop never happens.
    text = combined(root, result)
    assert_ok(result, text, "external unmount")
    folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
    if "roleplay\t" not in folders or "\tcomplete\t" not in folders:
        raise AssertionError(f"externally unmounted folder did not complete:\n{folders}")
    if "migrated, remount needs attention" in folders or "\tfailed\t" in folders or "\tskipped\t" in folders:
        raise AssertionError(f"externally unmounted folder was failed:\n{folders}")
    if "was unmounted externally" not in text or "Skipping the remount" not in text:
        raise AssertionError(f"external unmount was not reported:\n{text}")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    if "REMOUNT " in ops:
        raise AssertionError(f"an externally removed mount was remounted:\n{ops}")
    if list(root.glob("mount/roleplay.__migration_tmp__.*")):
        raise AssertionError("temporary source remained after the external-unmount migration")
    if (root / "mount" / "roleplay" / "keep.txt").read_text(encoding="utf-8") != "role local\n":
        raise AssertionError("local file was not preserved")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag remained")


def write_resume_tree(root: Path, *, mismatch: bool) -> None:
    mount = root / "mount"
    media = mount / "media"
    library = media / "library"
    temp = mount / "media.__migration_tmp__.10.20.30"
    beta = mount / "beta"
    library.mkdir(parents=True)
    (temp / "library").mkdir(parents=True)
    beta.mkdir()
    (media / "keep.txt").write_text("media local\n", encoding="utf-8")
    (temp / "keep.txt").write_text("other local\n" if mismatch else "media local\n", encoding="utf-8")
    (library / "remote-only.txt").write_text("remote bytes\n", encoding="utf-8")
    (temp / "library" / "local.txt").write_text("under the mountpoint\n", encoding="utf-8")
    (beta / "keep.txt").write_text("beta local\n", encoding="utf-8")
    (root / "mountinfo").write_text(
        "\n".join(
            [
                f"10 1 0:39 / {mount} rw,relatime - zfs tank/cache rw",
                mountinfo_line(library, "fuse.rclone", "remote:library"),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (root / "running").write_text("", encoding="utf-8")
    plugin = root / "plugin"
    plugin.mkdir()
    datasets = root / "state" / "datasets" / "tank" / "cache"
    datasets.mkdir(parents=True)
    (datasets / "media").write_text("tank/cache/media\n", encoding="utf-8")
    (plugin / "migration.inprogress").write_text(
        'DATASET="tank/cache"\nSTARTED_EPOCH="10"\nPID="10"\n',
        encoding="utf-8",
    )
    (plugin / "containers.tsv").write_text(
        "cid-base\tbase\tunless-stopped\t0\t1\t1\tstopped\t\n"
        "cid-app\tapp\tunless-stopped\t0\t1\t1\tstopped\t\n",
        encoding="utf-8",
    )
    (root / "docker.spec").write_text(
        "cid-base|base|unless-stopped|0|default||\n"
        "cid-app|app|unless-stopped|0|container:base||\n",
        encoding="utf-8",
    )
    install_fakes(root / "fakebin", root / "state", mount, root / "mountinfo")


def test_resume_when_mount_is_already_back(tmp: Path) -> None:
    root = tmp / "resume"
    write_resume_tree(root, mismatch=False)
    result = run_worker(
        root,
        ["--dataset", "tank/cache"],
        {
            "ZFSAS_TEST_CONTAINER_MOUNT": str(root / "mount" / "media"),
            "ZFSAS_TEST_DOCKER_SPEC": str(root / "docker.spec"),
            "ZFSAS_TEST_FAIL_START_ONCE": "cid-app",
            "ZFSAS_TEST_FAIL_START_DONE": str(root / "fail-start.done"),
        },
    )
    text = combined(root, result)
    assert_ok(result, text, "resume mounted cutover")
    if "Verifying without copying again" not in text:
        raise AssertionError(f"resume did not verify the preserved source:\n{text}")
    if "Repair rsync" in text or "Repair attempt" in text:
        raise AssertionError(f"resume copied again instead of verifying:\n{text}")
    if "excluded from verification" not in text:
        raise AssertionError(f"live nested mount was not excluded from verification:\n{text}")
    if "FUSE-READ " in text:
        raise AssertionError(f"resume verification read through the nested mount:\n{text}")
    if list(root.glob("mount/media.__migration_tmp__.*")):
        raise AssertionError("matching temporary source was kept")
    if (root / "mount" / "media" / "keep.txt").read_text(encoding="utf-8") != "media local\n":
        raise AssertionError("dataset content changed during resume")
    if (root / "mount" / "library" / "remote-only.txt").exists():
        raise AssertionError("remote bytes were written outside the mount")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    verify_at = ops.find("--itemize-changes")
    base_at = ops.find("docker-start cid-base")
    app_at = ops.find("docker-start cid-app")
    if verify_at < 0 or base_at < 0 or app_at < 0 or not (verify_at < base_at < app_at):
        raise AssertionError(f"verify and dependency-ordered restart were not in order:\n{ops}")
    if "docker-start-fail cid-app" not in ops:
        raise AssertionError(f"container restart did not exercise the existing retry:\n{ops}")
    if "docker-update unless-stopped cid-base" not in ops or "docker-update unless-stopped cid-app" not in ops:
        raise AssertionError(f"restart policies were not restored:\n{ops}")
    if (root / "mount" / "beta" / "keep.txt").read_text(encoding="utf-8") != "beta local\n":
        raise AssertionError("the remaining queue did not migrate")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag remained after resume")
    if "zfs destroy" in text:
        raise AssertionError(f"resume destroyed a dataset:\n{text}")


def test_resume_mismatch_keeps_temp(tmp: Path) -> None:
    root = tmp / "resume-mismatch"
    write_resume_tree(root, mismatch=True)
    result = run_worker(
        root,
        ["--dataset", "tank/cache"],
        {
            "ZFSAS_TEST_CONTAINER_MOUNT": str(root / "mount" / "media"),
            "ZFSAS_TEST_DOCKER_SPEC": str(root / "docker.spec"),
        },
    )
    text = combined(root, result)
    assert_ok(result, text, "resume mismatch")
    temps = list(root.glob("mount/media.__migration_tmp__.*"))
    if len(temps) != 1:
        raise AssertionError(f"mismatched temporary source was not kept: {temps}")
    if temps[0].joinpath("keep.txt").read_text(encoding="utf-8") != "other local\n":
        raise AssertionError("mismatched temporary source was modified")
    if "does not match" not in text or "was kept" not in text:
        raise AssertionError(f"mismatch was not reported:\n{text}")
    if "zfs destroy" in text or "Repair rsync" in text:
        raise AssertionError(f"mismatch changed the preserved source or dataset:\n{text}")
    ops = (root / "operations.log").read_text(encoding="utf-8")
    if "docker-start cid-base" not in ops or "docker-start cid-app" not in ops:
        raise AssertionError(f"containers were not restarted after the mismatch:\n{ops}")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("in-progress flag remained after the mismatch")


def test_release_stuck_holder(tmp: Path) -> None:
    root = tmp / "release"
    root.mkdir()
    library = root / "library"
    library.mkdir()
    mountinfo = root / "mountinfo"
    lock = root / "migrator.lock"
    parent_out = root / "parent.out"
    marker = root / "marker"
    parent = root / "parent.sh"
    helper = root / "rclone"
    parent.write_text(
        "#!/bin/bash\n"
        "exec 9>\"$1\"\n"
        "flock 9\n"
        "echo \"parent $$\" > \"$2\"\n"
        "\"$3\" mount remote:library \"$4\" --allow-other\n",
        encoding="utf-8",
    )
    helper.write_text(
        "#!/bin/bash\n"
        "target=\"\"\n"
        "for arg in \"$@\"; do\n"
        "  if [[ \"$arg\" == /* && -d \"$arg\" ]]; then target=\"$arg\"; fi\n"
        "done\n"
        "if [[ -n \"$target\" ]]; then\n"
        "  printf '20 1 0:40 / %s rw,relatime - fuse.rclone remote:library rw\\n' \"$target\" >> \"$MOUNTINFO\"\n"
        "fi\n"
        "echo \"rclone $$\" > \"$MARKER\"\n"
        "sleep 300\n",
        encoding="utf-8",
    )
    parent.chmod(0o755)
    helper.chmod(0o755)
    env = os.environ.copy()
    env.update({"MOUNTINFO": str(mountinfo), "MARKER": str(marker)})
    proc = subprocess.Popen([str(parent), str(lock), str(parent_out), str(helper), str(library)], env=env)
    try:
        for _ in range(50):
            if marker.exists() and mountinfo.exists():
                break
            time.sleep(0.05)
        holder = int(parent_out.read_text(encoding="utf-8").split()[1])
        child = int(marker.read_text(encoding="utf-8").split()[1])
        result = run_worker(
            root,
            ["--release-stuck-holder"],
            {"ZFSAS_MIGRATOR_RELEASE_MOUNTINFO": str(mountinfo), "ZFSAS_MIGRATOR_LOCK_FILE": str(lock)},
        )
        text = combined(root, result)
        if result.returncode != 0:
            raise AssertionError(f"release exited {result.returncode}:\n{text}")
        if "Released stuck migrator" not in text or "without signaling" not in text:
            raise AssertionError(f"release did not report a clean detach:\n{text}")
        if proc.poll() is None:
            raise AssertionError("stuck migrator was left running")
        if not Path(f"/proc/{child}").exists():
            raise AssertionError("mount helper was signaled")
        assert_helper_detached(child)
        probe = os.open(lock, os.O_RDWR)
        try:
            import fcntl
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AssertionError("migrator lock stayed held after release") from exc
        finally:
            os.close(probe)
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            child_text = marker.read_text(encoding="utf-8").split()[1]
            kill_process_tree(int(child_text))
        except (OSError, IndexError, ValueError):
            pass
        proc.wait(timeout=5)


def main() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="zfsas-nested-mount-") as tmp:
        root = Path(tmp)
        test_fuse_unmount_migrate_remount(root)
        test_fuse_skip_when_unmount_fails(root)
        test_nested_zfs_is_skipped(root)
        test_restart_policy_restored_after_crash(root)
        test_remount_returns_while_helper_runs(root)
        test_remount_timeout_needs_attention(root)
        test_external_unmount_skips_remount(root)
        test_resume_when_mount_is_already_back(root)
        test_resume_mismatch_keeps_temp(root)
        test_release_stuck_holder(root)
    print("PASS: dataset migrator nested mounts")


if __name__ == "__main__":
    main()
