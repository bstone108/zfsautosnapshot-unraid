#!/usr/bin/env python3
"""Static UI contracts for Snapshot Manager queue-aware controls."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/snapshot-manager-page.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def extract_block(page: str, marker: str, end_marker: str, missing: str, unclosed: str) -> str:
    start = page.find(marker)
    if start == -1:
        raise AssertionError(missing)
    end = page.find(end_marker, start + len(marker))
    if end == -1:
        raise AssertionError(unclosed)
    return page[start : end + len(end_marker)]


def extract_select_all_handler(page: str) -> str:
    return extract_block(
        page,
        "byId('snapshot_manager_select_all').addEventListener('change', function () {",
        "  });",
        "Snapshot Manager must define a select-all change handler",
        "Snapshot Manager select-all handler must be closed",
    )


def extract_refresh_state_function(page: str) -> str:
    return extract_block(
        page,
        "function refreshSnapshotManagerState() {",
        "  }\n\n  byId('snapshot_manager_refresh')",
        "Snapshot Manager must define one periodic refresh function for datasets and the open drawer",
        "Snapshot Manager periodic refresh function must be closed before event wiring",
    )


def extract_actionable_selected_function(page: str) -> str:
    return extract_block(
        page,
        "function actionableSelectedSnapshots(action) {",
        "  }\n\n  function refreshBulkCount()",
        "Snapshot Manager must filter selected snapshots by the requested bulk action",
        "Snapshot Manager actionable selected snapshot filter must be closed before refreshBulkCount",
    )


def extract_request_action_function(page: str) -> str:
    return extract_block(
        page,
        "function requestAction(body, onSuccess) {",
        "  }\n\n  function buildDefaultSnapshotName()",
        "Snapshot Manager must centralize action request handling",
        "Snapshot Manager action request handler must be closed before buildDefaultSnapshotName",
    )


def extract_reload_current_dataset_function(page: str) -> str:
    return extract_block(
        page,
        "function reloadCurrentDatasetDetails(errorPrefix) {",
        "  }\n\n  function refreshSnapshotManagerState()",
        "Snapshot Manager must define a drawer detail refresh helper",
        "Snapshot Manager drawer detail refresh helper must be closed before periodic refresh",
    )


def main() -> int:
    page = PAGE.read_text()
    settings_page = (ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/settings.php").read_text()
    snapshot_panel = extract_block(
        settings_page,
        '<div class="zfsas-section-panel" id="zfsas_panel_snapshot_manager"',
        '    </div>\n\n    <div class="zfsas-section-panel" id="zfsas_panel_help"',
        "Settings page must define the Snapshot Manager tab panel",
        "Snapshot Manager tab panel must be closed before the Help tab panel",
    )
    handler = extract_select_all_handler(page)
    refresh_function = extract_refresh_state_function(page)
    actionable_function = extract_actionable_selected_function(page)
    request_action_function = extract_request_action_function(page)
    reload_current_dataset_function = extract_reload_current_dataset_function(page)

    assert_contains(
        page,
        'disabled title="Snapshot deletion is already queued."',
        "pending-delete rows must render disabled selection checkboxes",
    )
    assert_contains(
        page,
        'id="snapshot_manager_pool_filter"',
        "Snapshot Manager must expose a pool-level filter to reduce long dataset lists",
    )
    assert_contains(
        page,
        "function populatePoolFilter(datasets) {",
        "Snapshot Manager must rebuild pool filter options from loaded dataset summary rows",
    )
    assert_contains(
        page,
        "function applySnapshotManagerPoolFilter() {",
        "Snapshot Manager must hide/show dataset rows by selected pool",
    )
    assert_contains(
        page,
        "data-pool=\"' + escapeHtml(row.pool || datasetPool(row.dataset)) + '\"",
        "Snapshot Manager dataset rows must carry a pool data attribute for filtering",
    )
    assert_contains(
        page,
        "snapshot_manager_dataset_count",
        "Snapshot Manager must show visible/total dataset counts while filtering",
    )
    assert_contains(
        page,
        "align-items: center;",
        "Snapshot Manager drawer overlay must vertically center the manage-dataset panel instead of pinning it to the top",
    )
    assert_contains(
        page,
        "justify-content: center;",
        "Snapshot Manager drawer overlay must horizontally center the manage-dataset panel instead of aligning it to the right edge",
    )
    assert_contains(
        page,
        "max-height: min(92vh, 1120px);",
        "Snapshot Manager drawer panel must fit inside the viewport and let its body scroll",
    )
    if 'zfsas-placeholder-title">Snapshot Manager<' in snapshot_panel:
        raise AssertionError("Embedded Snapshot Manager tab must not duplicate the iframe page header")
    if '<code>Snapshot Manager</code> is still unfinished' in snapshot_panel:
        raise AssertionError("Embedded Snapshot Manager tab must not duplicate the iframe warning label")
    assert_contains(
        handler,
        "if (checkbox.disabled) {",
        "select-all must skip disabled pending-delete checkboxes instead of selecting queued deletes",
    )
    assert_contains(
        handler,
        "delete currentSelection[checkbox.value];",
        "select-all must clear any stale selection state for disabled pending-delete rows",
    )
    assert_contains(
        page,
        "refreshTimer = window.setInterval(refreshSnapshotManagerState, 5000);",
        "periodic refresh must use the combined Snapshot Manager state refresher",
    )
    assert_contains(
        refresh_function,
        "loadDatasetList();",
        "periodic refresh must keep the dataset summary current",
    )
    assert_contains(
        refresh_function,
        "if (!currentDataset) {",
        "periodic refresh must be safe when no drawer dataset is selected",
    )
    assert_contains(
        refresh_function,
        "reloadCurrentDatasetDetails();",
        "periodic refresh must reload the open drawer dataset instead of leaving Snapshot Manager details stale",
    )
    assert_contains(
        reload_current_dataset_function,
        "datasetUrl + '?dataset=' + encodeURIComponent(currentDataset)",
        "drawer detail refresh must call the dataset endpoint for the current drawer dataset",
    )
    assert_contains(
        reload_current_dataset_function,
        "renderSnapshotRows(currentDataset, payload.snapshots || [], payload.status || null);",
        "periodic drawer refresh must repaint snapshot rows with fresh status/pending action data",
    )
    assert_contains(
        reload_current_dataset_function,
        "refreshBulkCount();",
        "periodic drawer refresh must keep selection counts synchronized after repainting rows",
    )
    assert_contains(
        actionable_function,
        "if (action === 'hold' && row.held) {",
        "bulk Hold Selected must skip snapshots that are already held instead of queueing duplicate zfs hold work",
    )
    assert_contains(
        actionable_function,
        "if (action === 'release' && !row.held) {",
        "bulk Release Selected must skip snapshots that are not held instead of queueing no-op releases",
    )
    assert_contains(
        page,
        "var snapshots = actionableSelectedSnapshots(action);",
        "bulk actions must use the action-aware filtered selection list",
    )
    assert_contains(
        page,
        "function reloadCurrentDatasetDetails(errorPrefix) {",
        "Snapshot Manager must have a drawer refresh path that preserves action feedback after an accepted operation",
    )
    assert_contains(
        request_action_function,
        "reloadCurrentDatasetDetails();",
        "action success refresh must preserve the accepted-operation feedback instead of clearing it via loadDataset",
    )
    if "loadDataset(currentDataset);" in request_action_function:
        raise AssertionError(
            "action success refresh must not call loadDataset(currentDataset), which clears drawer feedback immediately after showing success"
        )

    print("PASS: Snapshot Manager UI static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
