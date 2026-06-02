#!/usr/bin/env python3
"""Static contracts for the Dataset Migrator WebGUI page."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/migrate-datasets.php"
text = PAGE.read_text(encoding="utf-8")


def require(pattern: str, message: str, flags: int = 0) -> None:
    if not re.search(pattern, text, flags):
        raise AssertionError(message)


# The migrator must have a dedicated preview/scan action separate from the
# destructive start action so users can build and review the folder list first.
require(
    r'<button\b[^>]*id="migrate_preview"[^>]*>\s*Preview Migration\s*</button>',
    "Dataset Migrator page must expose an explicit Preview Migration button before Start Migration.",
    re.S,
)
require(
    r'var\s+previewButton\s*=\s*byId\(\'migrate_preview\'\);',
    "Preview button must be wired in JavaScript.",
)
require(
    r'previewButton\.addEventListener\(\'click\'\s*,\s*function\s*\(\)\s*{.*?refreshStatus\(\);.*?}\s*\);',
    "Preview button must trigger a non-destructive status/preview refresh.",
    re.S,
)
require(
    r'renderPageStatus\(\'Previewing top-level folders\.\.\.\'\s*,\s*false\)',
    "Preview action must tell the user it is scanning/building the review list.",
)
require(
    r'Preview Migration scans the selected parent dataset, finds top-level folders, and builds this review list without stopping containers or moving data\.',
    "Dataset Migrator instructions must explain the non-destructive Preview step at the point of use.",
)
require(
    r'Start Migration only begins work after you review the preview\.',
    "Dataset Migrator instructions must explain Start is separate from Preview.",
)
require(
    r'If space is too low before the next folder, containers stay running and the original folder stays in place until enough free space is available\.',
    "Dataset Migrator instructions must state the pre-stop free-space wait semantics.",
)
# Start remains a distinct POST-only action and must not be the only way to
# populate the preview table.
require(
    r'<button\b[^>]*id="migrate_start"[^>]*>\s*Start Migration\s*</button>',
    "Start Migration button must remain present.",
    re.S,
)
require(
    r'\{action:\s*\'start\'\s*,\s*dataset:\s*dataset\}',
    "Start button must remain the only action that posts the start request.",
)

# The issue #19 safety requirement is that a folder must not trigger container
# stops or source renames while the destination pool is already too full. The
# worker must therefore perform a space wait/check before stop_container_batch()
# in the main batch loop, not only inside migrate_one_directory() after Docker
# has already been touched.
WORKER = ROOT / "source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"
worker_text = WORKER.read_text(encoding="utf-8")
require_worker = lambda pattern, message: (_ for _ in ()).throw(AssertionError(message)) if not re.search(pattern, worker_text, re.S) else None
require_worker(
    r'preflight_space_for_folder\s*\(\)\s*{.*?wait_for_free_space\s+"\$required_bytes"\s+"\$name"\s+"\$folder_index"',
    "Worker must expose a pre-stop space gate that waits for enough free space for the next folder.",
)
require_worker(
    r'while\s+CURRENT_FOLDER_INDEX=.*?select_batch_for_folder\s+"\$CURRENT_FOLDER_INDEX".*?preflight_space_for_folder\s+"\$CURRENT_FOLDER_INDEX".*?stop_container_batch\s+"\$CURRENT_BATCH_CONTAINERS"',
    "Worker main loop must run the pre-stop space gate before stopping any containers for the batch.",
)

# Crash/reboot recovery must be durable before the destructive rename/create/copy
# boundary. A reboot can wipe /var/run, so the migrator needs a boot-persisted
# recovery record under /boot/config and an event hook that starts delayed
# recovery after disks mount. The recovery must wait for containers to settle,
# then stop only the batch related to the interrupted folder, exact-sync with
# rsync --delete, and restore container policies/starts.
require_worker(
    r'RECOVERY_STATE_FILE="\$\{PLUGIN_ROOT\}/recovery.env"',
    "Worker must define a boot-persisted recovery state file under the migrator plugin root.",
)
require_worker(
    r'write_recovery_state\s*\(\)\s*{.*?RECOVERY_PHASE=.*?RECOVERY_FOLDER_INDEX=.*?RECOVERY_SOURCE_PATH=.*?RECOVERY_TEMP_PATH=.*?RECOVERY_TARGET_DATASET=.*?RECOVERY_BATCH_CONTAINERS=',
    "Worker must persist the active folder/temp path/target dataset/container batch for crash recovery.",
)
require_worker(
    r'clear_recovery_state\s*\(\)\s*{.*?rm\s+-f\s+--\s+"\$RECOVERY_STATE_FILE"',
    "Worker must clear the durable recovery record only after a folder is fully verified and cleaned up.",
)
require_worker(
    r'mv\s+--\s+"\$entry_path"\s+"\$temp_path".*?RECOVERY_PHASE="renamed_source".*?write_recovery_state',
    "Worker must persist recovery state immediately after the source folder is renamed.",
)
require_worker(
    r'zfs\s+create\s+"\$child_ds".*?RECOVERY_PHASE="dataset_created".*?write_recovery_state',
    "Worker must update recovery state immediately after the child dataset is created.",
)
require_worker(
    r'rsync_recover_exact\s*\(\)\s*{.*?rsync\s+-aHAXx\s+--delete\s+--numeric-ids',
    "Recovery must use an exact rsync --delete pass from the preserved source temp folder to the child dataset.",
)
require_worker(
    r'run_delayed_recovery\s*\(\)\s*{.*?sleep\s+"\$RECOVERY_BOOT_DELAY_SECONDS".*?stop_container_batch\s+"\$RECOVERY_BATCH_CONTAINERS".*?rsync_recover_exact.*?start_selected_containers\s+"\$RECOVERY_BATCH_CONTAINERS"',
    "Boot recovery must wait for containers to settle, stop only the affected batch, exact-sync, and restore services.",
)
require_worker(
    r'--recover-pending\).*?RUN_RECOVERY=1',
    "Worker must expose a --recover-pending mode for the boot hook.",
)

EVENT = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/event/disks_mounted"
event_text = EVENT.read_text(encoding="utf-8")
if not re.search(r'(?:zfs_autosnapshot_migrate_datasets|\$MIGRATOR_WORKER)"?\s+--recover-pending', event_text, re.S):
    raise AssertionError("disks_mounted must launch delayed Dataset Migrator recovery after boot when recovery.env exists.")

print("PASS: Dataset Migrator static UI, worker, and recovery contracts")
