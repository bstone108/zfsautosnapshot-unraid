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
    assert_contains(
        ops_lib,
        "send_destination_actionable_for_schedule_transport()",
        "scheduled send enqueue readiness must use a transport-aware destination check before SSH jobs can be queued",
    )
    assert_contains(
        ops_lib,
        "SEND_SPIPED_KEY_PATH",
        "queue library must load spiped key-path configuration before spiped transport can run",
    )
    assert_contains(
        ops_lib,
        "build_spiped_receive_command()",
        "spiped transport must have one audited receiver command builder before pipeline plumbing is enabled",
    )
    assert_contains(
        ops_lib,
        "build_spipe_send_command()",
        "spiped sender pipelines must use the stdin/stdout spipe client, not try to pipe a zfs stream into the spiped daemon",
    )
    assert_contains(
        ops_lib,
        "spipe -t",
        "spiped sender helper must target the remote receiver using spipe -t host:port",
    )
    assert_contains(
        ops_lib,
        "SEND_SPIPED_REMOTE_HOST",
        "queue library must load sender-side remote spiped host configuration before spiped transport can run",
    )
    assert_contains(
        ops_lib,
        "spiped -d -s '",
        "spiped receiver command must run in decrypt/server mode on the configured receiver side",
    )
    scheduled_ready_body = ops_lib.split("function scheduled_send_job_zfs_actionable() {", 1)[1].split("\n}\n", 1)[0]
    assert_contains(
        scheduled_ready_body,
        "SCHEDULE_TRANSPORT",
        "scheduled send readiness must inspect the configured transport, not assume a local destination",
    )
    assert_contains(
        scheduled_ready_body,
        "send_destination_actionable_for_schedule_transport",
        "scheduled send readiness must probe SSH destinations over SSH instead of local zfs",
    )
    if "send_destination_actionable \"$dest_root\"" in scheduled_ready_body:
        raise AssertionError("scheduled send readiness must not call the local-only destination readiness helper directly")

    worker_destination_ready_body = worker.split("send_destination_actionable_for_transport() {", 1)[1].split("\n}\n", 1)[0]
    assert_contains(
        worker_destination_ready_body,
        "spiped)",
        "worker destination readiness must handle spiped explicitly instead of falling through to local ZFS checks",
    )
    assert_contains(
        worker_destination_ready_body,
        "build_spipe_send_command spipe_command",
        "spiped readiness must validate sender endpoint/key settings before creating source checkpoints",
    )
    if "spiped)" not in worker_destination_ready_body and "send_destination_actionable \"$destination\"" in worker_destination_ready_body:
        raise AssertionError("spiped worker readiness must not use local-only destination readiness")

    assert_contains(
        worker,
        "spiped_transport_requires_receiver_inventory()",
        "spiped sends must fail closed until receiver-side inventory/verification exists; opaque spipe streams cannot safely use local destination state",
    )
    send_member_body = worker.split("send_member_snapshot() {", 1)[1].split("\n}\n\ncleanup_source_checkpoints_for_verified_member()", 1)[0]
    assert_contains(
        send_member_body,
        "spiped_transport_requires_receiver_inventory",
        "send member processing must stop spiped jobs before local-only base selection or verification can run",
    )
    spiped_guard_index = send_member_body.find("spiped_transport_requires_receiver_inventory")
    local_base_index = send_member_body.find("find_latest_common_basename_for_member_transport")
    if spiped_guard_index == -1 or local_base_index == -1 or spiped_guard_index > local_base_index:
        raise AssertionError("spiped fail-closed guard must run before latest-common base selection")

    prepare_body = worker.split("prepare_scheduled_job_snapshot() {", 1)[1].split("\n}\n\nprepare_manual_snapshot_job()", 1)[0]
    assert_contains(
        prepare_body,
        "spiped_transport_requires_receiver_inventory",
        "scheduled spiped jobs must fail closed before creating new source checkpoints while receiver inventory is unavailable",
    )
    spiped_prepare_guard_index = prepare_body.find("spiped_transport_requires_receiver_inventory")
    checkpoint_create_index = prepare_body.find("Creating scheduled send checkpoint")
    if (
        spiped_prepare_guard_index == -1
        or checkpoint_create_index == -1
        or spiped_prepare_guard_index > checkpoint_create_index
    ):
        raise AssertionError("scheduled spiped fail-closed guard must run before source checkpoint creation")

    print("PASS: send worker helper static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
