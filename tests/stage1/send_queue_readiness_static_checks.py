#!/usr/bin/env python3
"""Static contracts for ZFS send queue readiness/defer behavior."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_send_worker"
KICKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_queue_kicker"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def assert_in_order(text: str, first: str, second: str, message: str) -> None:
    first_idx = text.find(first)
    second_idx = text.find(second)
    if first_idx < 0 or second_idx < 0 or first_idx > second_idx:
        raise AssertionError(message)


def main() -> int:
    lib = LIB.read_text()
    worker = WORKER.read_text()
    kicker = KICKER.read_text()

    assert_contains(
        lib,
        "function zfs_dataset_tree_actionable",
        "send readiness must verify source dataset tree listability, not just Unraid array state",
    )
    assert_contains(
        lib,
        "function zfs_pool_actionable",
        "send readiness must verify destination pool actionability before prep/send work",
    )
    assert_contains(
        lib,
        "function scheduled_send_job_zfs_actionable",
        "scheduled queue decisions need a combined source/destination ZFS readiness guard",
    )
    assert_contains(
        lib,
        "scheduled_send_job_zfs_actionable \"$job_id\" readiness_message || {",
        "queue kicker must defer due scheduled sends before enqueue when source/destination ZFS is not ready",
    )
    assert_in_order(
        lib,
        "scheduled_send_job_zfs_actionable \"$job_id\" readiness_message || {",
        "due_jobs+=(\"$job_id\")",
        "readiness guard must run before scheduled jobs are added to due_jobs/enqueued",
    )
    assert_contains(
        kicker,
        "scheduled_send_job_zfs_actionable \"$job_id\" readiness_message || {",
        "manual send-all kicker must also defer schedules that are not ZFS-actionable",
    )

    assert_contains(
        worker,
        "if ! snapshot_error=\"$(\"${create_cmd[@]}\" 2>&1)\"; then",
        "scheduled send snapshot creation failures must be handled explicitly",
    )
    assert_contains(
        worker,
        "defer_current_job \"Source dataset is not ready for scheduled send; waiting for ZFS import/mount.\"",
        "failed scheduled snapshot creation should defer without persisting a phantom SOURCE_SNAPSHOT",
    )
    assert_contains(
        worker,
        "send_destination_actionable \"$destination\" readiness_message || {",
        "send members must defer when destination pool/parent is not actionable instead of final-failing",
    )
    assert_contains(
        worker,
        "zfs_pool_actionable \"$dest_pool\" readiness_message || {",
        "pool prep must defer until the destination pool is ZFS-actionable",
    )

    assert_contains(
        lib,
        "approve_send_job_space_for_launch()",
        "queue manager must approve estimated send space before dispatching transfer workers",
    )
    assert_contains(
        lib,
        "required_bytes=\"$(job_get launch_job SPACE_REQUIRED_BYTES 0)\"",
        "queue manager approval must use worker-reported SPACE_REQUIRED_BYTES, not just estimate presence",
    )
    assert_contains(
        lib,
        "acquire_send_space_reservation \"$job_id\" \"$reservation_pid\"",
        "queue manager approval must reserve destination space before launching a transfer worker",
    )
    assert_contains(
        lib,
        "prep_job_id=\"$(job_get launch_job PREP_JOB_ID)\"",
        "queue manager must not reserve/launch sends before their destination pool prep job completes",
    )
    assert_contains(
        lib,
        "launch_job[LAST_MESSAGE]=\"Waiting for pool prep.\"",
        "queue manager should leave prepped sends queued while destination cleanup prep is still running",
    )
    assert_contains(
        lib,
        "pool_has_active_delete_jobs \"$dest_pool\"",
        "queue manager must not churn cleanup while destination deletes are already queued/running",
    )
    assert_contains(
        lib,
        "freeing_bytes=\"$(get_pool_freeing \"$dest_pool\")\"",
        "queue manager must account for ZFS freeing before rerunning cleanup",
    )
    assert_contains(
        lib,
        "acquire_pool_prep_lock \"$dest_pool\"",
        "queue manager cleanup approval must avoid overlapping cleanup planners",
    )
    assert_contains(
        worker,
        "adopt_send_space_reservation_for_job \"$CURRENT_JOB_ID\" \"$$\"",
        "worker must adopt queue-manager-created reservations instead of reserving/churning again",
    )
    assert_contains(
        worker,
        "if send_space_reservation_exists_for_job \"$CURRENT_JOB_ID\"; then",
        "worker must honor pre-approved space reservations before attempting a fresh reservation",
    )
    assert_contains(
        Path(ROOT / "source/usr/local/sbin/zfs_autosnapshot_queue_handler").read_text(),
        "approve_send_job_space_for_launch \"$job_path\" \"$$\" || {",
        "queue handler must skip launching transfer workers until space is approved",
    )
    print("PASS: send queue readiness static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
