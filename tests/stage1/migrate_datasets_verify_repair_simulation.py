#!/usr/bin/env python3
"""Verify-failure repair and last-resort restore for the dataset migrator."""
from __future__ import annotations

import os
import stat
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def install_fakes(fakebin: Path, state: Path, mount: Path) -> None:
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
                  printf '99999999999\\n'
                  exit 0
                fi
                if [[ " $* " == *" -t filesystem "* ]]; then
                  printf '%s\\t%s\\n' "tank/parent" "$mount"
                  exit 0
                fi
                if [[ "$dataset" == "tank/parent" || -f "$state/datasets/$dataset" ]]; then
                  printf '%s\\n' "$dataset"
                  exit 0
                fi
                exit 1
                ;;
              get)
                prop=""
                if [[ " $* " == *" mounted "* ]]; then
                  prop="mounted"
                else
                  prop="mountpoint"
                fi
                if [[ "$prop" == "mounted" ]]; then
                  printf 'yes\\n'
                  exit 0
                fi
                if [[ "$dataset" == "tank/parent" ]]; then
                  printf '%s\\n' "$mount"
                else
                  printf '%s\\n' "$mount/$(basename "$dataset")"
                fi
                exit 0
                ;;
              create)
                mkdir -p "$state/datasets/$(dirname "$dataset")"
                mkdir -p "$mount/$(basename "$dataset")"
                printf '%s\\n' "$dataset" > "$state/datasets/$dataset"
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
            src = args[-2].rstrip("/")
            dst = args[-1].rstrip("/")
            log = os.environ["ZFSAS_TEST_OPERATION_LOG"]
            with open(log, "a", encoding="utf-8") as handle:
                handle.write(f"RSYNC {src} -> {dst}\\n")
            verify = "--itemize-changes" in args
            if verify:
                budget = int(os.environ.get("ZFSAS_TEST_VERIFY_FAILS", "0"))
                count_path = os.environ["ZFSAS_TEST_VERIFY_COUNT"]
                count = 0
                if os.path.exists(count_path):
                    count = int(open(count_path, encoding="utf-8").read() or "0")
                if dst.rstrip("/").endswith("/alpha"):
                    count += 1
                    open(count_path, "w", encoding="utf-8").write(str(count))
                    if count <= budget:
                        print(">f.st...... only-in-dest.txt")
                raise SystemExit(0)
            os.makedirs(dst, exist_ok=True)
            if "--delete" in args:
                for name in os.listdir(dst):
                    path = os.path.join(dst, name)
                    if name not in os.listdir(src):
                        with open(log, "a", encoding="utf-8") as handle:
                            handle.write(f"DELETE {path}\\n")
                        shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.unlink(path)
            for name in os.listdir(src):
                source = os.path.join(src, name)
                target = os.path.join(dst, name)
                if os.path.isdir(source) and not os.path.islink(source):
                    if os.path.exists(target):
                        shutil.rmtree(target)
                    shutil.copytree(source, target, symlinks=True)
                else:
                    shutil.copy2(source, target)
            if "--delete" not in args and dst.rstrip("/").endswith("/alpha"):
                extra = os.path.join(dst, "only-in-dest.txt")
                open(extra, "w", encoding="utf-8").write("dataset only\\n")
            PY
            """
        ),
    )
    write_executable(fakebin / "sleep", common + "exit 0\n")
    write_executable(
        fakebin / "docker",
        common
        + textwrap.dedent(
            """\
            cmd="${1:-}"
            shift || true
            case "$cmd" in
              info)
                if [[ -f "$ZFSAS_TEST_DOCKER_STOPPED" ]]; then exit 1; fi
                exit 0
                ;;
              ps)
                if [[ " $* " == *"{{.Names}}"* ]]; then
                  printf '%s\\n' "manual-app"
                fi
                exit 0
                ;;
              start)
                printf '%s\\n' "$1" >> "$ZFSAS_TEST_DOCKER_STARTED"
                exit 0
                ;;
              inspect)
                printf 'false\\n'
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
            """
        ),
    )
    for name, body in {
        "rc.docker": textwrap.dedent(
            """\
            action="${1:-}"
            if [[ "$action" == "stop" ]]; then
              printf 'stopped\\n' > "$ZFSAS_TEST_DOCKER_STOPPED"
            elif [[ "$action" == "start" ]]; then
              rm -f "$ZFSAS_TEST_DOCKER_STOPPED"
            fi
            exit 0
            """
        ),
        "rc.libvirt": textwrap.dedent(
            """\
            action="${1:-}"
            if [[ "$action" == "status" && -f "$ZFSAS_TEST_LIBVIRT_STOPPED" ]]; then
              exit 1
            fi
            if [[ "$action" == "stop" ]]; then
              printf 'stopped\\n' > "$ZFSAS_TEST_LIBVIRT_STOPPED"
            elif [[ "$action" == "start" ]]; then
              rm -f "$ZFSAS_TEST_LIBVIRT_STOPPED"
            fi
            exit 0
            """
        ),
        "lxc-ls": textwrap.dedent(
            """\
            if [[ -f "$ZFSAS_TEST_LXC_STOPPED" ]]; then
              exit 0
            fi
            printf '%s\\n' "ct1"
            exit 0
            """
        ),
        "lxc-stop": textwrap.dedent(
            """\
            if [[ " $* " == *"--timeout"* ]]; then
              printf 'stopped\\n' > "$ZFSAS_TEST_LXC_STOPPED"
            fi
            exit 0
            """
        ),
        "lxc-start": "exit 0\n",
        "lxc-autostart": "exit 0\n",
        "lxc-info": textwrap.dedent(
            """\
            if [[ -f "$ZFSAS_TEST_LXC_RUNNING" ]]; then
              printf 'State: RUNNING\\n'
            else
              printf 'State: STOPPED\\n'
            fi
            exit 0
            """
        ),
        "virsh": textwrap.dedent(
            """\
            action="${1:-}"
            name="${2:-}"
            if [[ "$action" == "list" ]]; then
              printf '%s\\n' "manual-vm"
              exit 0
            fi
            if [[ "$action" == "domstate" ]]; then
              if [[ -f "$ZFSAS_TEST_VM_RUNNING" ]]; then
                printf 'running\\n'
              else
                printf 'shut off\\n'
              fi
              exit 0
            fi
            if [[ "$action" == "start" ]]; then
              printf 'running\\n' > "$ZFSAS_TEST_VM_RUNNING"
              exit 0
            fi
            exit 0
            """
        ),
    }.items():
        write_executable(fakebin / name, common + body)


def run_worker(root: Path, mount: Path, env_extra: dict[str, str]) -> subprocess.CompletedProcess[str]:
    plugin = root / "plugin"
    fakebin = root / "fakebin"
    state = root / "state"
    plugin.mkdir(parents=True)
    fakebin.mkdir(parents=True)
    state.mkdir(parents=True)
    (state / "datasets").mkdir()
    (mount / "alpha").mkdir(parents=True)
    (mount / "beta").mkdir(parents=True)
    (mount / "alpha" / "keep.txt").write_text("alpha original\n", encoding="utf-8")
    (mount / "beta" / "keep.txt").write_text("beta original\n", encoding="utf-8")
    lxc_root = root / "lxcdata" / "ct1"
    lxc_root.mkdir(parents=True)
    (lxc_root / "config").write_text("lxc.start.auto = 1\n", encoding="utf-8")
    (root / "lxc.conf").write_text(f'lxc.lxcpath={root / "lxcdata"}\n', encoding="utf-8")
    autostart = root / "autostart"
    autostart.write_text("kept-app\n", encoding="utf-8")
    vm_dir = root / "qemu-autostart"
    vm_dir.mkdir()
    (vm_dir / "vm1.xml").write_text("<domain/>\n", encoding="utf-8")
    install_fakes(fakebin, state, mount)
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fakebin}:{env.get('PATH', '')}",
            "ZFSAS_MIGRATOR_PLUGIN_ROOT": str(plugin),
            "ZFSAS_MIGRATOR_LOG_FILE": str(root / "worker.log"),
            "ZFSAS_MIGRATOR_LOG_ARCHIVE_FILE": str(root / "worker.archive.log"),
            "ZFSAS_MIGRATOR_LOCK_FILE": str(root / "migrator.lock"),
            "ZFSAS_MIGRATOR_RECOVERY_BOOT_DELAY_SECONDS": "0",
            "ZFSAS_MIGRATOR_SERVICE_SETTLE_SECONDS": "0",
            "ZFSAS_MIGRATOR_SERVICE_STOP_WAIT_SECONDS": "0",
            "ZFSAS_MIGRATOR_RESTART_RETRY_DELAY": "0",
            "ZFSAS_MIGRATOR_RC_DOCKER": str(fakebin / "rc.docker"),
            "ZFSAS_MIGRATOR_RC_LIBVIRT": str(fakebin / "rc.libvirt"),
            "ZFSAS_MIGRATOR_DOCKER_AUTOSTART_FILE": str(autostart),
            "ZFSAS_MIGRATOR_LIBVIRT_AUTOSTART_DIR": str(vm_dir),
            "ZFSAS_MIGRATOR_LXC_CONF": str(root / "lxc.conf"),
            "ZFSAS_MIGRATOR_LXC_STARTUP": str(root / "missing-lxc-startup"),
            "ZFSAS_TEST_OPERATION_LOG": str(root / "operations.log"),
            "ZFSAS_TEST_VERIFY_COUNT": str(root / "verify.count"),
            "ZFSAS_TEST_DOCKER_STOPPED": str(root / "docker.stopped"),
            "ZFSAS_TEST_DOCKER_STARTED": str(root / "docker.started"),
            "ZFSAS_TEST_LIBVIRT_STOPPED": str(root / "libvirt.stopped"),
            "ZFSAS_TEST_LXC_STOPPED": str(root / "lxc.stopped"),
            "ZFSAS_TEST_LXC_RUNNING": str(root / "lxc.running"),
            "ZFSAS_TEST_VM_RUNNING": str(root / "vm.running"),
        }
    )
    env.update(env_extra)
    try:
        return subprocess.run(
            [str(WORKER), "--dataset", "tank/parent"],
            cwd=str(ROOT),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"migrator timed out:\n{exc.output or ''}") from exc


def combined_output(root: Path, result: subprocess.CompletedProcess[str]) -> str:
    log_text = (root / "worker.log").read_text(encoding="utf-8") if (root / "worker.log").exists() else ""
    ops = (root / "operations.log").read_text(encoding="utf-8") if (root / "operations.log").exists() else ""
    return f"{result.stdout}\n{log_text}\n{ops}"


def assert_order(text: str, markers: list[str]) -> None:
    cursor = 0
    for marker in markers:
        found = text.find(marker, cursor)
        if found == -1:
            raise AssertionError(f"missing or out of order: {marker}\n--- output ---\n{text}")
        cursor = found + len(marker)


def test_repair_succeeds_without_destroy(tmp: Path) -> None:
    root = tmp / "repair-ok"
    mount = root / "mount"
    result = run_worker(
        root,
        mount,
        {
            "ZFSAS_MIGRATOR_VERIFY_REPAIR_ATTEMPTS": "2",
            "ZFSAS_TEST_VERIFY_FAILS": "2",
        },
    )
    text = combined_output(root, result)
    if result.returncode != 0:
        raise AssertionError(f"repair success run failed ({result.returncode}):\n{text}")
    if "zfs destroy" in text:
        raise AssertionError(f"a clean repair must not destroy the dataset:\n{text}")
    if "rc.docker stop" in text or "rc.libvirt stop" in text:
        raise AssertionError(f"a clean repair must not stop services:\n{text}")
    if "Repair attempt 1 of 2" not in text or "Repair attempt 2 of 2" not in text:
        raise AssertionError(f"repair did not make both attempts:\n{text}")
    if "kill -9" in text:
        raise AssertionError(text)
    for line in text.splitlines():
        if not line.startswith("RSYNC ") or " -> " not in line:
            continue
        src, dst = line.removeprefix("RSYNC ").split(" -> ", 1)
        if src.rstrip("/").endswith("/alpha") and ".__migration_tmp__." in dst:
            raise AssertionError(f"repair wrote into the preserved source:\n{line}")
    if any("DELETE " in line and ".__migration_tmp__." in line for line in text.splitlines()):
        raise AssertionError(f"repair deleted a file from the preserved source:\n{text}")
    if (mount / "alpha" / "only-in-dest.txt").exists():
        raise AssertionError("repair --delete left a destination-only file in the dataset")
    if not (mount / "alpha" / "keep.txt").exists() or (mount / "alpha" / "keep.txt").read_text(encoding="utf-8") != "alpha original\n":
        raise AssertionError("repair did not keep the original alpha contents in the dataset")
    if list(mount.glob("alpha.__migration_tmp__.*")):
        raise AssertionError("successful repair left the temporary source behind")
    status = (root / "plugin" / "status.env").read_text(encoding="utf-8")
    if 'STATE="complete"' not in status:
        raise AssertionError(f"successful repair did not finish the migration:\n{status}")


def test_last_resort_reverts_and_continues(tmp: Path) -> None:
    root = tmp / "last-resort"
    mount = root / "mount"
    result = run_worker(
        root,
        mount,
        {
            "ZFSAS_MIGRATOR_VERIFY_REPAIR_ATTEMPTS": "3",
            "ZFSAS_TEST_VERIFY_FAILS": "99",
        },
    )
    text = combined_output(root, result)
    if result.returncode != 0:
        raise AssertionError(f"last-resort run failed ({result.returncode}):\n{text}")
    if "kill -9" in text or "kill -KILL" in text:
        raise AssertionError(f"last resort used kill -9:\n{text}")
    assert_order(
        result.stdout,
        [
            "Repair attempt 1 of 3",
            "Repair attempt 2 of 3",
            "Repair attempt 3 of 3",
            "Repair attempts are exhausted",
            "rc.docker stop",
            "rc.libvirt stop",
            "lxc-stop --timeout=",
            "zfs destroy -r: tank/parent/alpha",
            "rc.libvirt start",
            "rc.docker start",
            "lxc-autostart",
            "lxc-stop --kill",
            "started on the follow-up attempt",
        ],
    )
    if "manual-app" not in text or "is not in the Unraid autostart list" not in text:
        raise AssertionError(f"non-autostart Docker container was not reported:\n{text}")
    started = (root / "docker.started").read_text(encoding="utf-8") if (root / "docker.started").exists() else ""
    if "kept-app" not in started:
        raise AssertionError(f"autostart Docker container was not started once:\n{started}\n{text}")
    if "manual-app" in started.split():
        raise AssertionError(f"non-autostart Docker container was started:\n{started}")
    if not (root / "vm.running").exists():
        raise AssertionError("autostart VM was not started on the follow-up")
    alpha = mount / "alpha" / "keep.txt"
    if not alpha.exists() or alpha.read_text(encoding="utf-8") != "alpha original\n":
        raise AssertionError("last resort did not restore the original alpha folder")
    if (mount / "alpha" / "only-in-dest.txt").exists():
        raise AssertionError("restored alpha contains a file that existed only on the broken dataset")
    if list(mount.glob("alpha.__migration_tmp__.*")):
        raise AssertionError("restored alpha left the temporary name behind")
    beta = mount / "beta" / "keep.txt"
    if not beta.exists() or beta.read_text(encoding="utf-8") != "beta original\n":
        raise AssertionError("the queue did not keep migrating beta after alpha was reverted")
    if list(mount.glob("beta.__migration_tmp__.*")):
        raise AssertionError("beta temp folder was left behind")
    folders = (root / "plugin" / "folders.tsv").read_text(encoding="utf-8")
    if "alpha\t" not in folders or "\treverted\t" not in folders:
        raise AssertionError(f"alpha was not marked reverted:\n{folders}")
    if "beta\t" not in folders or "\tcomplete\t" not in folders:
        raise AssertionError(f"beta was not marked complete:\n{folders}")
    status = (root / "plugin" / "status.env").read_text(encoding="utf-8")
    if 'STATE="complete_with_failures"' not in status:
        raise AssertionError(f"status did not record a finished run with a reverted folder:\n{status}")
    if (root / "plugin" / "migration.inprogress").exists():
        raise AssertionError("the in-progress flag should be cleared after the queue finishes")
    destroy_at = result.stdout.find("zfs destroy -r: tank/parent/alpha")
    if "beta" not in result.stdout[destroy_at:]:
        raise AssertionError(f"beta was not migrated after alpha was destroyed:\n{result.stdout[destroy_at:]}")


def main() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="zfsas-migrator-repair-") as tmp:
        root = Path(tmp)
        test_repair_succeeds_without_destroy(root)
        test_last_resort_reverts_and_continues(root)
    print("PASS: dataset migrator verify repair and last resort")


if __name__ == "__main__":
    main()
