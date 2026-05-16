#!/usr/bin/env python3
"""Static contracts for ZFS send queue preflight status messages."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_send_worker"
text = WORKER.read_text()

preflight_branch = """if preflight_only_worker; then
    defer_current_job "Waiting in send queue for queue manager dispatch." 0
    return 2
  fi"""
assert preflight_branch in text, (
    "Preflight-only send workers should leave jobs waiting for queue-manager "
    "dispatch, not report that they are waiting for a transfer/send slot."
)

assert 'defer_current_job "Waiting for send slot." 3' in text, (
    "Transfer workers should still report real transfer slot contention."
)
