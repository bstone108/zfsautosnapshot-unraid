<?php
$pluginName = 'zfs.autosnapshot';
$snapshotManagerListUrl = "/plugins/{$pluginName}/php/snapshot-manager-list.php";
$snapshotManagerDatasetUrl = "/plugins/{$pluginName}/php/snapshot-manager-dataset.php";
$snapshotManagerActionUrl = "/plugins/{$pluginName}/php/snapshot-manager-action.php";
$mainSettingsUrl = '/Settings/ZFSAutoSnapshot?section=snapshot-manager';
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Snapshot Manager</title>
  <style>
    body {
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      margin: 0;
      background: var(--body-background, #f5f7fb);
      color: var(--text-color, #1f2933);
    }

    .zfsas-sm-page {
      max-width: 1320px;
      margin: 20px auto;
      padding: 0 18px 24px;
    }

    .zfsas-sm-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      flex-wrap: wrap;
      margin-bottom: 14px;
    }

    .zfsas-sm-subtitle {
      margin-top: 6px;
      color: var(--text-color, #4f5a66);
      opacity: 0.86;
    }

    .zfsas-sm-card {
      background: var(--background-color, #fff);
      border: 1px solid var(--border-color, #d9e1ea);
      border-radius: 10px;
      padding: 16px;
      margin-bottom: 14px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
    }

    .zfsas-sm-help {
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
      font-size: 12px;
      line-height: 1.45;
    }

    .zfsas-sm-toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 14px;
    }

    .zfsas-sm-toolbar-status {
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
    }

    .zfsas-sm-toolbar-status.error {
      color: #8f2d2a;
      opacity: 1;
    }

    .zfsas-sm-feedback {
      min-height: 28px;
      margin-top: 12px;
    }

    .zfsas-alert {
      border-radius: 8px;
      padding: 10px 12px;
      font-size: 12px;
      line-height: 1.45;
    }

    .zfsas-alert-error {
      background: rgba(176, 0, 32, 0.08);
      border: 1px solid rgba(176, 0, 32, 0.24);
    }

    .zfsas-alert-warn {
      background: rgba(221, 140, 15, 0.10);
      border: 1px solid rgba(221, 140, 15, 0.24);
    }

    .zfsas-table-wrap {
      margin-top: 12px;
      border: 1px solid var(--border-color, #e1e8ef);
      border-radius: 8px;
      overflow-x: auto;
    }

    .zfsas-table {
      width: 100%;
      min-width: 1080px;
      border-collapse: collapse;
    }

    .zfsas-table th,
    .zfsas-table td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--border-color, #edf2f7);
      vertical-align: top;
    }

    .zfsas-table tr:last-child td {
      border-bottom: none;
    }

    .zfsas-table th {
      text-align: left;
      background: rgba(82, 126, 235, 0.06);
      font-size: 13px;
    }

    .zfsas-center {
      text-align: center;
    }

    .zfsas-actions-cell {
      white-space: nowrap;
      width: 260px;
    }

    .zfsas-select-cell {
      width: 42px;
      text-align: center;
    }

    .zfsas-sm-progress {
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 220px;
    }

    .zfsas-sm-progress-track {
      flex: 1 1 auto;
      height: 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.12);
      overflow: hidden;
    }

    .zfsas-sm-progress-fill {
      height: 100%;
      border-radius: 999px;
      background: linear-gradient(90deg, #4e8ef7, #2db6a3);
    }

    .zfsas-sm-progress-text {
      min-width: 44px;
      text-align: right;
      font-size: 12px;
      color: var(--text-color, #4f5a66);
    }

    .zfsas-sm-chip {
      display: inline-flex;
      align-items: center;
      padding: 4px 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.12);
      font-size: 12px;
      white-space: nowrap;
    }

    .zfsas-sm-chip.error {
      background: rgba(176, 0, 32, 0.12);
    }

    .zfsas-sm-drawer-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(14, 22, 32, 0.35);
      z-index: 1050;
    }

    .zfsas-sm-drawer {
      position: fixed;
      inset: 0;
      display: flex;
      justify-content: flex-end;
      z-index: 1060;
      pointer-events: none;
    }

    .zfsas-sm-drawer-panel {
      width: min(1120px, 96vw);
      height: 100%;
      background: var(--background-color, #fff);
      box-shadow: -10px 0 32px rgba(0, 0, 0, 0.16);
      display: flex;
      flex-direction: column;
      pointer-events: auto;
    }

    .zfsas-sm-drawer-header,
    .zfsas-sm-bulk-bar {
      padding: 14px 18px;
      border-bottom: 1px solid var(--border-color, #e1e8ef);
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }

    .zfsas-sm-drawer-title {
      margin: 0;
    }

    .zfsas-sm-drawer-subtitle {
      margin-top: 4px;
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
    }

    .zfsas-sm-bulk-count {
      margin-left: auto;
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
    }

    .zfsas-sm-drawer-body {
      flex: 1 1 auto;
      overflow: auto;
      padding: 18px;
    }

    .zfsas-sm-snapshot-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 6px;
    }

    .zfsas-sm-meta-chip {
      display: inline-flex;
      align-items: center;
      padding: 3px 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.08);
      font-size: 11px;
    }

    .zfsas-sm-meta-chip.is-protected {
      background: rgba(221, 140, 15, 0.12);
    }

    @media (max-width: 920px) {
      .zfsas-sm-progress {
        min-width: 160px;
      }

      .zfsas-actions-cell {
        width: auto;
      }
    }
  </style>
</head>
<body>
<div class="zfsas-sm-page">
  <div class="zfsas-sm-header">
    <div>
      <h2 style="margin:0;">Snapshot Manager</h2>
      <div class="zfsas-sm-subtitle">Dataset-level snapshot summary, queue-aware manual actions, and one-off sends without loading every snapshot until you actually open a dataset.</div>
    </div>
    <div>
      <a class="btn" href="<?php echo htmlspecialchars($mainSettingsUrl, ENT_QUOTES, 'UTF-8'); ?>">Back to Main Settings</a>
    </div>
  </div>

  <div class="zfsas-sm-card">
    <div class="zfsas-sm-help">
      The main table stays lightweight: it only shows dataset-level summary information, pending queue activity, and active send progress. Snapshot lists load only when you click <strong>Manage Snapshots</strong>.
    </div>
    <div class="zfsas-sm-toolbar">
      <button type="button" class="btn" id="snapshot_manager_refresh">Refresh Dataset Summary</button>
      <div id="snapshot_manager_toolbar_status" class="zfsas-sm-toolbar-status">Snapshot Manager is ready.</div>
    </div>
    <div id="snapshot_manager_feedback" class="zfsas-sm-feedback"></div>

    <div class="zfsas-table-wrap">
      <table class="zfsas-table">
        <thead>
          <tr>
            <th>Dataset</th>
            <th>Last Snapshot</th>
            <th class="zfsas-center">Snapshots</th>
            <th>Pending Actions</th>
            <th>Send Progress</th>
            <th class="zfsas-actions-cell">Actions</th>
          </tr>
        </thead>
        <tbody id="snapshot_manager_dataset_rows">
          <tr>
            <td colspan="6" class="zfsas-sm-help">Snapshot summary will load in a moment.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<div id="snapshot_manager_backdrop" class="zfsas-sm-drawer-backdrop" hidden></div>
<div id="snapshot_manager_drawer" class="zfsas-sm-drawer" hidden>
  <div class="zfsas-sm-drawer-panel">
    <div class="zfsas-sm-drawer-header">
      <div>
        <h3 class="zfsas-sm-drawer-title" id="snapshot_manager_dataset_title">Snapshot Manager</h3>
        <div class="zfsas-sm-drawer-subtitle" id="snapshot_manager_dataset_subtitle">Choose a dataset from the list to review its snapshots.</div>
      </div>
      <button type="button" class="btn" id="snapshot_manager_close">Close</button>
    </div>

    <div class="zfsas-sm-bulk-bar">
      <button type="button" class="btn" id="snapshot_manager_take_snapshot">Take Snapshot</button>
      <button type="button" class="btn" id="snapshot_manager_delete_selected">Delete Selected</button>
      <button type="button" class="btn" id="snapshot_manager_hold_selected">Hold Selected</button>
      <button type="button" class="btn" id="snapshot_manager_release_selected">Release Selected</button>
      <button type="button" class="btn" id="snapshot_manager_refresh_dataset">Refresh Dataset</button>
      <div id="snapshot_manager_bulk_count" class="zfsas-sm-bulk-count">No dataset selected.</div>
    </div>

    <div class="zfsas-sm-drawer-body">
      <div id="snapshot_manager_drawer_feedback" class="zfsas-sm-feedback"></div>
      <div class="zfsas-table-wrap">
        <table class="zfsas-table">
          <thead>
            <tr>
              <th class="zfsas-select-cell"><input type="checkbox" id="snapshot_manager_select_all"></th>
              <th>Snapshot</th>
              <th>Created</th>
              <th class="zfsas-center">Used</th>
              <th class="zfsas-center">Written</th>
              <th class="zfsas-center">Holds</th>
              <th class="zfsas-actions-cell">Actions</th>
            </tr>
          </thead>
          <tbody id="snapshot_manager_snapshot_rows">
            <tr>
              <td colspan="7" class="zfsas-sm-help">Choose a dataset to inspect its snapshots.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</div>

<script>
(function () {
  var listUrl = <?php echo json_encode($snapshotManagerListUrl); ?>;
  var datasetUrl = <?php echo json_encode($snapshotManagerDatasetUrl); ?>;
  var actionUrl = <?php echo json_encode($snapshotManagerActionUrl); ?>;
  var refreshTimer = null;
  var currentDataset = '';
  var currentSnapshotMap = {};
  var currentSelection = {};

  function byId(id) {
    return document.getElementById(id);
  }

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function discoverCsrfToken() {
    var globalCandidates = [window.csrf_token, window.CSRF_TOKEN, window.csrfToken];
    for (var i = 0; i < globalCandidates.length; i += 1) {
      if (typeof globalCandidates[i] === 'string' && globalCandidates[i].length > 0) {
        return globalCandidates[i];
      }
    }

    var selectors = ['input[name="csrf_token"]', 'input[name="csrf-token"]', 'input[name="_csrf"]', 'meta[name="csrf_token"]', 'meta[name="csrf-token"]', 'meta[name="x-csrf-token"]'];
    for (var j = 0; j < selectors.length; j += 1) {
      var node = document.querySelector(selectors[j]);
      if (!node) {
        continue;
      }
      if (node.tagName === 'META') {
        var content = node.getAttribute('content');
        if (typeof content === 'string' && content.length > 0) {
          return content;
        }
      } else if (typeof node.value === 'string' && node.value.length > 0) {
        return node.value;
      }
    }

    return '';
  }

  function extractMarkedJson(raw) {
    var beginMarker = 'ZFSAS_JSON_BEGIN';
    var endMarker = 'ZFSAS_JSON_END';
    var start = raw.indexOf(beginMarker);
    if (start === -1) {
      return null;
    }
    var contentStart = start + beginMarker.length;
    var end = raw.indexOf(endMarker, contentStart);
    if (end === -1 || end <= contentStart) {
      return null;
    }
    return raw.slice(contentStart, end).trim();
  }

  function isExpectedJsonPayload(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return false;
    }
    if (!Object.prototype.hasOwnProperty.call(payload, 'ok') || typeof payload.ok !== 'boolean') {
      return false;
    }
    if (Object.prototype.hasOwnProperty.call(payload, 'errors') && !Array.isArray(payload.errors)) {
      return false;
    }
    if (Object.prototype.hasOwnProperty.call(payload, 'notices') && !Array.isArray(payload.notices)) {
      return false;
    }
    return true;
  }

  function parsePossiblyWrappedJson(rawText) {
    var raw = String(rawText == null ? '' : rawText).trim();
    var parseError = null;

    if (raw === '') {
      throw new Error('Empty response.');
    }

    var marked = extractMarkedJson(raw);
    if (marked !== null) {
      var markedPayload = JSON.parse(marked);
      if (isExpectedJsonPayload(markedPayload)) {
        return markedPayload;
      }
      parseError = new Error('Unexpected JSON response shape.');
    }

    try {
      var directPayload = JSON.parse(raw);
      if (isExpectedJsonPayload(directPayload)) {
        return directPayload;
      }
      parseError = new Error('Unexpected JSON response shape.');
    } catch (error) {
      parseError = error;
    }

    var start = raw.indexOf('{');
    var end = raw.lastIndexOf('}');
    if (start !== -1 && end > start) {
      try {
        var payload = JSON.parse(raw.slice(start, end + 1));
        if (isExpectedJsonPayload(payload)) {
          return payload;
        }
      } catch (candidateError) {
        parseError = parseError || candidateError;
      }
    }

    throw parseError || new Error('Invalid JSON response.');
  }

  function requestJson(url, onSuccess, onError) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.setRequestHeader('Accept', 'application/json');

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }
      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error('HTTP ' + xhr.status));
        return;
      }
      try {
        onSuccess(parsePossiblyWrappedJson(xhr.responseText));
      } catch (error) {
        var raw = String(xhr.responseText || '').trim();
        if (raw.charAt(0) === '<') {
          onError(new Error('Session expired or the security token was rejected. Reload the page and try again.'));
        } else {
          onError(new Error('Invalid JSON response.'));
        }
      }
    };

    xhr.onerror = function () {
      onError(new Error('Network error.'));
    };

    xhr.send();
  }

  function requestJsonPost(url, bodyParams, onSuccess, onError) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.timeout = 15000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

    var csrfToken = discoverCsrfToken();
    if (csrfToken !== '') {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken);
    }

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }
      var payload = null;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (error) {
        payload = null;
      }

      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error((payload && payload.error) ? payload.error : ('HTTP ' + xhr.status)), payload);
        return;
      }

      if (!payload) {
        onError(new Error('Invalid JSON response.'));
        return;
      }

      onSuccess(payload);
    };

    xhr.onerror = function () {
      onError(new Error('Network error.'));
    };

    xhr.ontimeout = function () {
      onError(new Error('Request timed out.'));
    };

    var params = new URLSearchParams();
    Object.keys(bodyParams || {}).forEach(function (key) {
      var value = bodyParams[key];
      if (Array.isArray(value)) {
        value.forEach(function (entry) {
          params.append(key, entry);
        });
      } else if (value !== undefined && value !== null) {
        params.append(key, value);
      }
    });

    if (csrfToken !== '') {
      params.append('csrf_token', csrfToken);
    }

    xhr.send(params.toString());
  }

  function renderFeedback(containerId, messages, isError) {
    var node = byId(containerId);
    if (!node) {
      return;
    }

    if (!Array.isArray(messages) || messages.length === 0) {
      node.innerHTML = '';
      return;
    }

    var html = '<div class="zfsas-alert ' + (isError ? 'zfsas-alert-error' : 'zfsas-alert-warn') + '">';
    messages.forEach(function (message) {
      html += '<div>' + escapeHtml(message) + '</div>';
    });
    html += '</div>';
    node.innerHTML = html;
  }

  function setToolbarStatus(message, isError) {
    var node = byId('snapshot_manager_toolbar_status');
    if (!node) {
      return;
    }
    node.textContent = message;
    node.classList.toggle('error', !!isError);
  }

  function sendProgressHtml(activity) {
    if (!activity) {
      return '<span class="zfsas-sm-help">No active send.</span>';
    }

    var progress = parseInt(activity.progress, 10);
    if (isNaN(progress) || progress < 0) {
      progress = 0;
    }
    if (progress > 100) {
      progress = 100;
    }

    return ''
      + '<div class="zfsas-sm-progress">'
      + '<div class="zfsas-sm-progress-track"><div class="zfsas-sm-progress-fill" style="width: ' + progress + '%;"></div></div>'
      + '<div class="zfsas-sm-progress-text">' + progress + '%</div>'
      + '</div>'
      + '<div class="zfsas-sm-help" style="margin-top:4px;">' + escapeHtml(activity.stateLabel || activity.message || 'Active') + '</div>';
  }

  function pendingLabel(row) {
    if (row.lastError) {
      return '<span class="zfsas-sm-chip error">' + escapeHtml(row.lastError) + '</span>';
    }
    if (row.pendingCount > 0) {
      return '<span class="zfsas-sm-chip">' + String(row.pendingCount) + ' queued</span>';
    }
    if (row.currentAction) {
      return '<span class="zfsas-sm-chip">' + escapeHtml(row.currentAction) + '</span>';
    }
    if (row.lastMessage) {
      return '<span class="zfsas-sm-help">' + escapeHtml(row.lastMessage) + '</span>';
    }
    return '<span class="zfsas-sm-help">Idle</span>';
  }

  function renderDatasetRows(datasets) {
    var tbody = byId('snapshot_manager_dataset_rows');
    if (!tbody) {
      return;
    }

    if (!Array.isArray(datasets) || datasets.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" class="zfsas-sm-help">No datasets were found for Snapshot Manager.</td></tr>';
      return;
    }

    var html = '';
    datasets.forEach(function (row) {
      html += '<tr data-dataset="' + escapeHtml(row.dataset) + '">';
      html += '<td><code>' + escapeHtml(row.dataset) + '</code></td>';
      html += '<td>' + (row.lastSnapshotText ? escapeHtml(row.lastSnapshotText) : '<span class="zfsas-sm-help">No snapshots yet.</span>') + '</td>';
      html += '<td class="zfsas-center">' + String(row.snapshotCount || 0) + '</td>';
      html += '<td>' + pendingLabel(row) + '</td>';
      html += '<td>' + sendProgressHtml(row.sendActivity || null) + '</td>';
      html += '<td class="zfsas-actions-cell">';
      html += '<button type="button" class="btn snapshot-manager-take" data-dataset="' + escapeHtml(row.dataset) + '">Take Snapshot</button> ';
      html += '<button type="button" class="btn btn-primary snapshot-manager-open" data-dataset="' + escapeHtml(row.dataset) + '">Manage Snapshots</button>';
      html += '</td>';
      html += '</tr>';
    });

    tbody.innerHTML = html;
  }

  function selectedSnapshots() {
    return Object.keys(currentSelection).filter(function (key) {
      return !!currentSelection[key];
    });
  }

  function refreshBulkCount() {
    var node = byId('snapshot_manager_bulk_count');
    if (!node) {
      return;
    }

    if (!currentDataset) {
      node.textContent = 'No dataset selected.';
      return;
    }

    var count = selectedSnapshots().length;
    node.textContent = count + ' snapshot' + (count === 1 ? '' : 's') + ' selected on ' + currentDataset + '.';
  }

  function openDrawer() {
    var drawer = byId('snapshot_manager_drawer');
    var backdrop = byId('snapshot_manager_backdrop');
    if (drawer) {
      drawer.hidden = false;
    }
    if (backdrop) {
      backdrop.hidden = false;
    }
  }

  function closeDrawer() {
    var drawer = byId('snapshot_manager_drawer');
    var backdrop = byId('snapshot_manager_backdrop');
    if (drawer) {
      drawer.hidden = true;
    }
    if (backdrop) {
      backdrop.hidden = true;
    }
    currentSelection = {};
    refreshBulkCount();
    renderFeedback('snapshot_manager_drawer_feedback', [], false);
  }

  function renderSnapshotRows(dataset, snapshots, status) {
    var tbody = byId('snapshot_manager_snapshot_rows');
    if (!tbody) {
      return;
    }

    currentSnapshotMap = {};
    if (!Array.isArray(snapshots) || snapshots.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="zfsas-sm-help">No snapshots were found for this dataset.</td></tr>';
    } else {
      var html = '';
      snapshots.forEach(function (row) {
        currentSnapshotMap[row.snapshot] = row;
        var isSelected = !!currentSelection[row.snapshot];
        var holdLabel = row.held ? 'Release' : 'Hold';
        html += '<tr data-snapshot="' + escapeHtml(row.snapshot) + '">';
        html += '<td class="zfsas-select-cell"><input type="checkbox" class="snapshot-manager-select" value="' + escapeHtml(row.snapshot) + '"' + (isSelected ? ' checked' : '') + '></td>';
        html += '<td><code>' + escapeHtml(row.snapshotName) + '</code><div class="zfsas-sm-snapshot-meta">';
        if (row.sendProtected) {
          html += '<span class="zfsas-sm-meta-chip is-protected">Protected send checkpoint</span>';
        }
        if (row.held) {
          html += '<span class="zfsas-sm-meta-chip">Held: ' + escapeHtml((row.holdTags || []).join(', ') || 'yes') + '</span>';
        }
        html += '</div></td>';
        html += '<td>' + escapeHtml(row.createdText) + '</td>';
        html += '<td class="zfsas-center">' + escapeHtml(row.usedText) + '</td>';
        html += '<td class="zfsas-center">' + escapeHtml(row.writtenText) + '</td>';
        html += '<td class="zfsas-center">' + String(row.userrefs || 0) + '</td>';
        html += '<td class="zfsas-actions-cell">';
        html += '<button type="button" class="btn snapshot-manager-row-action" data-action="rollback" data-snapshot="' + escapeHtml(row.snapshot) + '"' + (row.sendProtected ? ' disabled' : '') + '>Rollback</button> ';
        html += '<button type="button" class="btn snapshot-manager-row-action" data-action="delete" data-snapshot="' + escapeHtml(row.snapshot) + '">Delete</button> ';
        html += '<button type="button" class="btn snapshot-manager-row-action" data-action="' + (row.held ? 'release' : 'hold') + '" data-snapshot="' + escapeHtml(row.snapshot) + '">' + holdLabel + '</button> ';
        html += '<button type="button" class="btn snapshot-manager-row-action" data-action="send" data-snapshot="' + escapeHtml(row.snapshot) + '">Send</button>';
        html += '</td>';
        html += '</tr>';
      });
      tbody.innerHTML = html;
    }

    byId('snapshot_manager_dataset_title').textContent = dataset;
    var subtitle = 'Snapshots listed oldest to newest.';
    if (status && status.pending_count > 0) {
      subtitle += ' ' + String(status.pending_count) + ' queued operation(s).';
    } else if (status && status.current_action_label) {
      subtitle += ' ' + status.current_action_label + ' is running.';
    }
    byId('snapshot_manager_dataset_subtitle').textContent = subtitle;

    var selectAll = byId('snapshot_manager_select_all');
    if (selectAll) {
      selectAll.checked = false;
    }
  }

  function loadDatasetList() {
    setToolbarStatus('Loading dataset summary...', false);
    requestJson(
      listUrl + '?_=' + Date.now(),
      function (payload) {
        renderDatasetRows(payload.datasets || []);
        setToolbarStatus('Snapshot Manager dataset summary refreshed.', false);
      },
      function (error) {
        renderDatasetRows([]);
        setToolbarStatus('Snapshot Manager load failed: ' + error.message, true);
      }
    );
  }

  function loadDataset(dataset) {
    currentDataset = dataset;
    currentSelection = {};
    refreshBulkCount();
    renderFeedback('snapshot_manager_drawer_feedback', [], false);
    openDrawer();
    requestJson(
      datasetUrl + '?dataset=' + encodeURIComponent(dataset) + '&_=' + Date.now(),
      function (payload) {
        renderSnapshotRows(dataset, payload.snapshots || [], payload.status || null);
        refreshBulkCount();
      },
      function (error) {
        renderFeedback('snapshot_manager_drawer_feedback', ['Unable to load snapshots for ' + dataset + ': ' + error.message], true);
      }
    );
  }

  function requestAction(body, onSuccess) {
    requestJsonPost(
      actionUrl,
      body,
      function (payload) {
        renderFeedback('snapshot_manager_drawer_feedback', [payload.message || 'Action accepted.'], false);
        loadDatasetList();
        if (currentDataset) {
          window.setTimeout(function () {
            loadDataset(currentDataset);
          }, 250);
        }
        if (typeof onSuccess === 'function') {
          onSuccess(payload);
        }
      },
      function (error, payload) {
        renderFeedback('snapshot_manager_drawer_feedback', [(payload && payload.error) ? payload.error : error.message], true);
      }
    );
  }

  function buildDefaultSnapshotName() {
    var now = new Date();
    function pad(value) {
      return String(value).padStart(2, '0');
    }
    return 'manual-' + now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate()) + '_' + pad(now.getHours()) + '-' + pad(now.getMinutes()) + '-' + pad(now.getSeconds());
  }

  function queueSelectedAction(action) {
    if (!currentDataset) {
      renderFeedback('snapshot_manager_drawer_feedback', ['Choose a dataset first.'], true);
      return;
    }

    var snapshots = selectedSnapshots();
    if (snapshots.length === 0) {
      renderFeedback('snapshot_manager_drawer_feedback', ['Select at least one snapshot first.'], true);
      return;
    }

    var body = {
      action: action,
      dataset: currentDataset,
      snapshots: snapshots
    };

    if (action === 'delete') {
      var requiresConfirm = snapshots.some(function (snapshot) {
        return !!(currentSnapshotMap[snapshot] && currentSnapshotMap[snapshot].sendProtected);
      });
      var message = requiresConfirm
        ? 'One or more selected snapshots are part of the scheduled send checkpoint chain. Deleting them can break future replication until a new send succeeds. Continue?'
        : 'Queue deletion for ' + snapshots.length + ' selected snapshot(s)?';
      if (!window.confirm(message)) {
        return;
      }
      if (requiresConfirm) {
        body.confirm_send_delete = '1';
      }
    }

    requestAction(body, function () {
      currentSelection = {};
      var selectAll = byId('snapshot_manager_select_all');
      if (selectAll) {
        selectAll.checked = false;
      }
      refreshBulkCount();
    });
  }

  byId('snapshot_manager_refresh').addEventListener('click', loadDatasetList);
  byId('snapshot_manager_close').addEventListener('click', closeDrawer);
  byId('snapshot_manager_backdrop').addEventListener('click', closeDrawer);
  byId('snapshot_manager_refresh_dataset').addEventListener('click', function () {
    if (!currentDataset) {
      renderFeedback('snapshot_manager_drawer_feedback', ['Choose a dataset first.'], true);
      return;
    }
    loadDataset(currentDataset);
  });

  byId('snapshot_manager_dataset_rows').addEventListener('click', function (event) {
    var takeButton = event.target.closest('.snapshot-manager-take');
    if (takeButton) {
      var dataset = takeButton.getAttribute('data-dataset') || '';
      if (!dataset) {
        return;
      }
      var snapshotName = window.prompt('New snapshot name for ' + dataset + ':', buildDefaultSnapshotName());
      if (snapshotName === null) {
        return;
      }
      snapshotName = snapshotName.trim();
      if (snapshotName === '') {
        renderFeedback('snapshot_manager_feedback', ['Snapshot name cannot be empty.'], true);
        return;
      }
      requestJsonPost(
        actionUrl,
        {action: 'take_snapshot', dataset: dataset, snapshot_name: snapshotName},
        function (payload) {
          renderFeedback('snapshot_manager_feedback', [payload.message || 'Snapshot creation started.'], false);
          loadDatasetList();
        },
        function (error, payload) {
          renderFeedback('snapshot_manager_feedback', [(payload && payload.error) ? payload.error : error.message], true);
        }
      );
      return;
    }

    var manageButton = event.target.closest('.snapshot-manager-open');
    if (!manageButton) {
      return;
    }
    var dataset = manageButton.getAttribute('data-dataset') || '';
    if (dataset) {
      loadDataset(dataset);
    }
  });

  byId('snapshot_manager_snapshot_rows').addEventListener('change', function (event) {
    var checkbox = event.target.closest('.snapshot-manager-select');
    if (!checkbox) {
      return;
    }
    currentSelection[checkbox.value] = checkbox.checked;
    refreshBulkCount();
  });

  byId('snapshot_manager_snapshot_rows').addEventListener('click', function (event) {
    var button = event.target.closest('.snapshot-manager-row-action');
    if (!button || !currentDataset) {
      return;
    }

    var action = button.getAttribute('data-action') || '';
    var snapshot = button.getAttribute('data-snapshot') || '';
    if (!action || !snapshot || !currentSnapshotMap[snapshot]) {
      return;
    }

    var body = {action: action, dataset: currentDataset, snapshots: [snapshot]};
    var row = currentSnapshotMap[snapshot];

    if (action === 'rollback') {
      if (!window.confirm('Rollback ' + currentDataset + ' to ' + snapshot + '? This removes newer snapshots and can discard recent changes.')) {
        return;
      }
    } else if (action === 'delete') {
      var deleteMessage = row.sendProtected
        ? 'This snapshot is part of the scheduled send checkpoint chain. Deleting it can break future replication until a new send succeeds. Continue?'
        : 'Queue deletion for snapshot ' + snapshot + '?';
      if (!window.confirm(deleteMessage)) {
        return;
      }
      if (row.sendProtected) {
        body.confirm_send_delete = '1';
      }
    } else if (action === 'send') {
      var destination = window.prompt('Destination dataset for one-off send from ' + snapshot + ':', '');
      if (destination === null) {
        return;
      }
      destination = destination.trim();
      if (destination === '') {
        renderFeedback('snapshot_manager_drawer_feedback', ['Destination dataset is required for one-off send.'], true);
        return;
      }
      body.destination = destination;
    }

    requestAction(body);
  });

  byId('snapshot_manager_select_all').addEventListener('change', function () {
    var checked = byId('snapshot_manager_select_all').checked;
    document.querySelectorAll('.snapshot-manager-select').forEach(function (checkbox) {
      checkbox.checked = checked;
      currentSelection[checkbox.value] = checked;
    });
    refreshBulkCount();
  });

  byId('snapshot_manager_take_snapshot').addEventListener('click', function () {
    if (!currentDataset) {
      renderFeedback('snapshot_manager_drawer_feedback', ['Choose a dataset first.'], true);
      return;
    }
    var snapshotName = window.prompt('New snapshot name for ' + currentDataset + ':', buildDefaultSnapshotName());
    if (snapshotName === null) {
      return;
    }
    snapshotName = snapshotName.trim();
    if (snapshotName === '') {
      renderFeedback('snapshot_manager_drawer_feedback', ['Snapshot name cannot be empty.'], true);
      return;
    }
    requestAction({action: 'take_snapshot', dataset: currentDataset, snapshot_name: snapshotName});
  });

  byId('snapshot_manager_delete_selected').addEventListener('click', function () {
    queueSelectedAction('delete');
  });
  byId('snapshot_manager_hold_selected').addEventListener('click', function () {
    queueSelectedAction('hold');
  });
  byId('snapshot_manager_release_selected').addEventListener('click', function () {
    queueSelectedAction('release');
  });

  loadDatasetList();
  refreshTimer = window.setInterval(loadDatasetList, 5000);
})();
</script>
</body>
</html>
