#!/usr/bin/env python3
"""Static contracts for send worker/helper function availability."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_send_worker"
OPS_LIB = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    worker = WORKER.read_text()
    ops_lib = OPS_LIB.read_text()

    assert_contains(
        worker,
        "release_current_send_transfer_slot()",
        "send worker cleanup trap must define the release_current_send_transfer_slot helper it calls",
    )
    assert_contains(
        worker,
        "release_send_transfer_slot \"$CURRENT_SEND_TRANSFER_SLOT\"",
        "send worker transfer-slot cleanup helper must release the tracked slot",
    )
    assert_contains(
        ops_lib,
        "send_space_buffer_bytes()",
        "queue manager library must define send_space_buffer_bytes before using it for reservation approval",
    )

    assert_contains(
        worker,
        "SEND_TRANSPORT",
        "send worker must carry the selected transport through queued jobs before network pipelines are enabled",
    )
    assert_contains(
        ops_lib,
        "send_transport_for_current_job()",
        "queue library must expose an explicit transport helper for local/ssh/spiped send pipelines",
    )
    assert_contains(
        ops_lib,
        "Unsupported ZFS send transport",
        "send pipeline must fail closed for unknown or not-yet-implemented network transports",
    )
    assert_contains(
        ops_lib,
        "SEND_SSH_HOST",
        "queue library must load SSH receiver host configuration before SSH transport can run",
    )
    assert_contains(
        ops_lib,
        "build_ssh_receive_command()",
        "queue library must build SSH receive commands in one audited helper",
    )
    assert_contains(
        ops_lib,
        "ssh -o BatchMode=yes",
        "SSH transport must default to non-interactive key/preconfigured authentication, not raw password prompts",
    )
    assert_contains(
        ops_lib,
        "zfs receive -uF --",
        "SSH receive helper must pass remote destination to zfs receive after -- for safer dataset handling",
    )
    assert_contains(
        ops_lib,
        "build_ssh_zfs_command()",
        "SSH transport must share one audited non-interactive remote zfs command builder",
    )
    assert_contains(
        ops_lib,
        "ssh_snapshot_inventory()",
        "SSH transport must expose non-destructive remote snapshot inventory before base selection is enabled",
    )
    assert_contains(
        ops_lib,
        "ssh_dataset_exists()",
        "SSH transport must check remote destination dataset state over SSH rather than local zfs for base selection",
    )
    assert_contains(
        worker,
        "destination_snapshot_exists_for_transport",
        "send worker must verify received snapshots using transport-aware destination checks",
    )
    assert_contains(
        worker,
        "find_latest_common_basename_for_member_transport",
        "send worker must use transport-aware latest-common base selection before network pipelines run",
    )

    print("PASS: send worker helper static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
