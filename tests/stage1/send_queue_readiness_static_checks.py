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

    prepare_snapshot_body = worker.split("prepare_scheduled_job_snapshot() {", 1)[1].split("\n}\n", 1)[0]
    assert_contains(
        worker,
        "if ! snapshot_error=\"$(\"${create_cmd[@]}\" 2>&1)\"; then",
        "scheduled send snapshot creation failures must be handled explicitly",
    )
    assert_in_order(
        prepare_snapshot_body,
        "zfs_dataset_tree_actionable \"$source_root\" \"$include_children\" readiness_message || {",
        "if [[ -n \"$(job_get job SOURCE_SNAPSHOT)\" ]]; then",
        "scheduled prepare/resume jobs must verify source tree actionability before treating a missing queued checkpoint as permanently gone",
    )
    assert_contains(
        worker,
        "defer_current_job \"Source dataset is not ready for scheduled send; waiting for ZFS import/mount.\"",
        "failed scheduled snapshot creation should defer without persisting a phantom SOURCE_SNAPSHOT",
    )
    assert_contains(
        prepare_snapshot_body,
        "send_destination_actionable \"$destination_root\" readiness_message || {",
        "scheduled prepare must recheck destination readiness before creating source checkpoints",
    )
    destination_actionable_body = lib.split("send_destination_actionable() {", 1)[1].split("\n}\n", 1)[0]
    assert_contains(
        destination_actionable_body,
        "destination parent dataset '${parent}' is not visible yet",
        "destination readiness must defer when a required parent dataset is missing instead of allowing receive to fail",
    )
    assert_contains(
        destination_actionable_body,
        "return 1",
        "destination readiness must fail closed for missing destination parents",
    )
    assert_in_order(
        prepare_snapshot_body,
        "send_destination_actionable \"$destination_root\" readiness_message || {",
        "log \"Creating scheduled send checkpoint ${source_root}@${basename}\"",
        "scheduled prepare must defer on destination readiness before snapshot creation to avoid phantom/churny checkpoints",
    )
    assert_contains(
        worker,
        "send_destination_actionable \"$destination\" readiness_message || {",
        "send members must defer when destination pool/parent is not actionable instead of final-failing",
    )
    assert_contains(
        worker,
        "zfs_dataset_tree_actionable \"$source_dataset\" \"0\" readiness_message || {",
        "send members must recheck source dataset actionability before base selection/reseed decisions",
    )
    assert_contains(
        worker,
        "source snapshot is not ready for scheduled send; waiting for ZFS import/mount",
        "send members must defer when their queued source snapshot is temporarily unavailable",
    )
    assert_in_order(
        worker,
        "zfs_dataset_tree_actionable \"$source_dataset\" \"0\" readiness_message || {",
        "find_latest_common_basename_for_member",
        "source readiness must be verified before latest-common scans or destructive reseed decisions",
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
    if "rerun_space_cleanup_for_waiting_send()" in worker:
        raise AssertionError(
            "transfer worker cleanup helper must be removed; queue manager owns destination cleanup planning"
        )
    reserve_body = worker.split("reserve_destination_space_for_current_send() {", 1)[1].split("\n}\n", 1)[0]
    if "queue_pool_retention_cleanup" in reserve_body or "queue_pool_free_space_cleanup_for_target" in reserve_body:
        raise AssertionError(
            "transfer workers must not churn destination cleanup; queue manager owns cleanup/space approval"
        )
    if "acquire_send_space_reservation \"$CURRENT_JOB_ID\" \"$$\"" in reserve_body:
        raise AssertionError(
            "transfer workers must not create fresh reservations; they should wait for queue-manager approval"
        )
    assert_contains(
        reserve_body,
        "defer_current_job \"Waiting for destination space approval.\"",
        "worker without pre-approved reservation should publish estimate and wait for queue-manager approval",
    )
    queue_handler = Path(ROOT / "source/usr/local/sbin/zfs_autosnapshot_queue_handler").read_text()
    assert_contains(
        queue_handler,
        "approve_send_job_space_for_launch \"$job_path\" \"$$\" || {",
        "queue handler must skip launching transfer workers until space is approved",
    )
    assert_contains(
        queue_handler,
        "release_job_claim \"$job_id\"",
        "queue handler must release a pre-claimed job if worker launch fails instead of leaving it blocked until stale cleanup",
    )
    assert_contains(
        worker,
        'defer_current_job "Waiting for children." 1',
        "scheduled finalizers should recheck child completion quickly instead of sleeping through ready work",
    )
    if 'defer_current_job "Waiting for children." 15' in worker:
        raise AssertionError("scheduled finalizers must not wait 15 seconds after children are ready")
    if 'defer_current_job "Waiting for child send." 15' in worker:
        raise AssertionError("post-send cleanup waiters must not wait 15 seconds after child sends are ready")

    zero_change_body = lib.split('if [[ "$mode" == "zero_change" ]]; then', 1)[1].split('    fi\n\n    snap_age=', 1)[0]
    if "Queued by post-send zero-change cleanup.\" \"$snapshot_schedule_job_id\" \"checkpoint\"" in zero_change_body:
        raise AssertionError(
            "post-send zero-change cleanup must not queue deletes for send checkpoint snapshots"
        )
    assert_contains(
        zero_change_body,
        "Skipping post-send zero-change cleanup for send checkpoint",
        "zero-change cleanup should explicitly skip send checkpoints and leave them to retention cleanup",
    )

    print("PASS: send queue readiness static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
