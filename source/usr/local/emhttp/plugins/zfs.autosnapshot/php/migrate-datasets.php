<?php
$pluginName = 'zfs.autosnapshot';
$statusUrl = "/plugins/{$pluginName}/php/migrate-datasets-status.php";
$actionUrl = "/plugins/{$pluginName}/php/migrate-datasets-action.php";
$mainSettingsUrl = '/Settings/ZFSAutoSnapshot?section=special-features';
require_once __DIR__ . '/response-helpers.php';
$csrfToken = zfsas_get_csrf_token();
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <?php if ($csrfToken !== '') : ?>
  <meta name="csrf_token" content="<?php echo htmlspecialchars($csrfToken, ENT_QUOTES, 'UTF-8'); ?>">
  <?php endif; ?>
  <title>Dataset Migrator</title>
  <style>
    body {
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      margin: 0;
      background: var(--body-background, #f5f7fb);
      color: var(--text-color, #1f2933);
    }
    .zfsas-dm-page {
      max-width: 1380px;
      margin: 20px auto;
      padding: 0 18px 24px;
    }
    .zfsas-dm-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      flex-wrap: wrap;
      margin-bottom: 14px;
    }
    .zfsas-dm-subtitle {
      margin-top: 6px;
      color: var(--text-color, #4f5a66);
      opacity: 0.86;
    }
    .zfsas-dm-card {
      background: var(--background-color, #fff);
      border: 1px solid var(--border-color, #d9e1ea);
      border-radius: 10px;
      padding: 16px;
      margin-bottom: 14px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
    }
    .zfsas-dm-help {
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
      font-size: 12px;
      line-height: 1.5;
    }
    .zfsas-dm-grid {
      display: grid;
      grid-template-columns: 1.1fr 0.9fr;
      gap: 14px;
    }
    .zfsas-dm-toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 14px;
    }
    .zfsas-dm-select {
      min-width: 320px;
      padding: 8px 10px;
      border-radius: 8px;
      border: 1px solid var(--input-border-color, var(--border-color, #b8c5d1));
      background: var(--input-background-color, var(--background-color, #fff));
      color: var(--text-color, #1f2933);
    }
    .zfsas-dm-status {
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.85;
    }
    .zfsas-dm-status.error {
      color: #8f2d2a;
      opacity: 1;
    }
    .zfsas-alert {
      border-radius: 8px;
      padding: 10px 12px;
      font-size: 12px;
      line-height: 1.45;
      margin-top: 12px;
    }
    .zfsas-alert-error {
      background: rgba(176, 0, 32, 0.08);
      border: 1px solid rgba(176, 0, 32, 0.24);
    }
    .zfsas-alert-warn {
      background: rgba(221, 140, 15, 0.10);
      border: 1px solid rgba(221, 140, 15, 0.24);
    }
    .zfsas-alert-info {
      background: rgba(82, 126, 235, 0.08);
      border: 1px solid rgba(82, 126, 235, 0.22);
    }
    .zfsas-dm-summary-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 10px;
      margin-top: 14px;
    }
    .zfsas-dm-stat {
      border: 1px solid var(--border-color, #e1e8ef);
      border-radius: 8px;
      padding: 10px 12px;
      background: rgba(82, 126, 235, 0.03);
    }
    .zfsas-dm-stat-label {
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-color, #4f5a66);
      opacity: 0.78;
    }
    .zfsas-dm-stat-value {
      margin-top: 6px;
      font-size: 18px;
      font-weight: 600;
    }
    .zfsas-table-wrap {
      margin-top: 12px;
      border: 1px solid var(--border-color, #e1e8ef);
      border-radius: 8px;
      overflow-x: auto;
    }
    .zfsas-table {
      width: 100%;
      min-width: 980px;
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
    .zfsas-chip {
      display: inline-flex;
      align-items: center;
      padding: 4px 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.12);
      font-size: 12px;
      white-space: nowrap;
    }
    .zfsas-chip.warn {
      background: rgba(221, 140, 15, 0.12);
    }
    .zfsas-chip.error {
      background: rgba(176, 0, 32, 0.12);
    }
    .zfsas-progress {
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 220px;
    }
    .zfsas-progress-track {
      flex: 1 1 auto;
      height: 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.12);
      overflow: hidden;
    }
    .zfsas-progress-fill {
      height: 100%;
      border-radius: 999px;
      background: linear-gradient(90deg, #4e8ef7, #2db6a3);
    }
    .zfsas-progress-text {
      min-width: 44px;
      text-align: right;
      font-size: 12px;
      color: var(--text-color, #4f5a66);
    }
    .zfsas-dm-log {
      margin-top: 12px;
      min-height: 220px;
      max-height: 380px;
      overflow: auto;
      padding: 10px 12px;
      border-radius: 8px;
      border: 1px solid var(--border-color, #1f2f40);
      background: #0d1724;
      color: #d9edf7;
      font: 12px/1.35 Consolas, Menlo, Monaco, monospace;
      white-space: pre-wrap;
    }
    @media (max-width: 1080px) {
      .zfsas-dm-grid {
        grid-template-columns: 1fr;
      }
      .zfsas-dm-summary-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
      .zfsas-dm-select {
        min-width: 0;
        width: 100%;
      }
    }
  </style>
</head>
<body>
<div class="zfsas-dm-page">
  <div class="zfsas-dm-header">
    <div>
      <h2 style="margin:0;">Dataset Migrator</h2>
      <div class="zfsas-dm-subtitle">Convert plain top-level folders under one selected dataset into individual child datasets with paranoid copy verification and container safety handling.</div>
    </div>
    <div>
      <a class="btn" href="<?php echo htmlspecialchars($mainSettingsUrl, ENT_QUOTES, 'UTF-8'); ?>">Back to Main Settings</a>
    </div>
  </div>

  <div class="zfsas-dm-grid">
    <div class="zfsas-dm-card">
      <h3 style="margin-top:0;">Before You Start</h3>
      <div class="zfsas-dm-help">
        This tool only works on top-level folders directly under the selected dataset mountpoint. It stops running Docker containers for the duration, temporarily disables their Docker restart policy while the migration is active, then restores those restart policies and starts the containers back up when the migration ends. Because this uses multiple verification passes, including checksum verification and file manifest comparison, it is intentionally slow.
      </div>
      <div class="zfsas-alert zfsas-alert-warn">
        <div>Stop all watchdog scripts or plugins before starting. Anything that relaunches containers during the migration can corrupt the copy and cause the tool to abort.</div>
        <div style="margin-top:6px;">Any containers that are set to restart automatically may still be restarted by outside tooling. The migrator will temporarily disable Docker restart policies for containers it stops, but you still need to disable outside watchdog behavior first.</div>
      </div>
      <div class="zfsas-alert zfsas-alert-info">
        <div>Do not start containers again until the tool finishes. If free space runs low, the migration will pause itself, show a warning here, and continue automatically after you free up enough space.</div>
        <div style="margin-top:6px;">Folder names must already be valid ZFS child dataset names. Anything with an unsafe name, nested mount, or existing child dataset will be skipped and called out below.</div>
      </div>
      <div id="migrate_feedback"></div>
      <div class="zfsas-dm-toolbar">
        <select id="migrate_dataset" class="zfsas-dm-select"></select>
        <button type="button" class="btn btn-primary" id="migrate_start">Start Migration</button>
        <button type="button" class="btn" id="migrate_refresh">Refresh</button>
        <div id="migrate_page_status" class="zfsas-dm-status">Loading dataset migrator status...</div>
      </div>
    </div>

    <div class="zfsas-dm-card">
      <h3 style="margin-top:0;">Live Run Summary</h3>
      <div class="zfsas-dm-help">This reflects the active worker state. The current folder and overall progress bars update while the background job is running.</div>
      <div id="migrate_waiting_notice"></div>
      <div class="zfsas-dm-summary-grid">
        <div class="zfsas-dm-stat">
          <div class="zfsas-dm-stat-label">State</div>
          <div class="zfsas-dm-stat-value" id="summary_state">Idle</div>
        </div>
        <div class="zfsas-dm-stat">
          <div class="zfsas-dm-stat-label">Dataset</div>
          <div class="zfsas-dm-stat-value" id="summary_dataset">-</div>
        </div>
        <div class="zfsas-dm-stat">
          <div class="zfsas-dm-stat-label">Folders</div>
          <div class="zfsas-dm-stat-value" id="summary_folders">0 / 0</div>
        </div>
        <div class="zfsas-dm-stat">
          <div class="zfsas-dm-stat-label">Current Step</div>
          <div class="zfsas-dm-stat-value" id="summary_step">-</div>
        </div>
      </div>
      <div style="margin-top:14px;">
        <div class="zfsas-dm-help">Overall progress</div>
        <div id="summary_overall_progress"></div>
      </div>
      <div style="margin-top:12px;">
        <div class="zfsas-dm-help">Current folder progress</div>
        <div id="summary_folder_progress"></div>
      </div>
      <div id="summary_message" class="zfsas-alert zfsas-alert-info" style="display:none;"></div>
    </div>
  </div>

  <div class="zfsas-dm-card">
    <h3 style="margin-top:0;">Top-Level Folder Plan</h3>
    <div class="zfsas-dm-help">Eligible rows will be migrated into child datasets. During an active run this table switches to the worker's live folder state.</div>
    <div class="zfsas-table-wrap">
      <table class="zfsas-table">
        <thead>
          <tr>
            <th>Folder</th>
            <th>Target dataset</th>
            <th>Size</th>
            <th>Status</th>
            <th>Progress</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody id="migrate_folder_rows">
          <tr>
            <td colspan="6" class="zfsas-dm-help">Choose a dataset to see its top-level folder plan.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="zfsas-dm-card">
    <h3 style="margin-top:0;">Container Handling</h3>
    <div class="zfsas-dm-help">Before the copy starts, the tool records which containers were running, temporarily disables their Docker restart policy while the migration is active, then brings them back up afterward. If any container fails to start, the tool starts the rest, waits 5 minutes, and retries the failed ones once.</div>
    <div class="zfsas-table-wrap">
      <table class="zfsas-table">
        <thead>
          <tr>
            <th>Container</th>
            <th>Restart policy</th>
            <th>Worker status</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody id="migrate_container_rows">
          <tr>
            <td colspan="4" class="zfsas-dm-help">Container preflight data will load in a moment.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="zfsas-dm-card">
    <h3 style="margin-top:0;">Live Log</h3>
    <div class="zfsas-dm-help">This shows the most recent log lines from the background worker, including copy, verification, rollback, free-space waits, and container restart attempts.</div>
    <pre id="migrate_log" class="zfsas-dm-log">Loading log...</pre>
  </div>
</div>

<script>
(function () {
  var statusUrl = <?php echo json_encode($statusUrl); ?>;
  var actionUrl = <?php echo json_encode($actionUrl); ?>;
  var pollTimer = null;
  var currentDataset = '';
  var startBusy = false;

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

  function requestJson(url, onSuccess, onError) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.timeout = 20000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }
      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (error) {
        onError(error);
        return;
      }
      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error((payload && payload.error) ? payload.error : ('HTTP ' + xhr.status)));
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
    xhr.send();
  }

  function requestJsonPost(url, bodyParams, onSuccess, onError) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.timeout = 45000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }
      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (error) {
        onError(error);
        return;
      }
      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error((payload && payload.error) ? payload.error : ('HTTP ' + xhr.status)), payload);
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
      params.append(key, bodyParams[key]);
    });

    var csrfToken = discoverCsrfToken();
    if (csrfToken !== '') {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken);
      params.append('csrf_token', csrfToken);
    }

    xhr.send(params.toString());
  }

  function formatBytes(value) {
    var bytes = parseInt(value, 10);
    if (isNaN(bytes) || bytes < 0) {
      return '-';
    }
    if (bytes < 1024) {
      return bytes + ' B';
    }
    var units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var size = bytes / 1024;
    var unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    return size.toFixed(size >= 100 ? 0 : 1) + ' ' + units[unitIndex];
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
    return true;
  }

  function parsePossiblyWrappedJson(rawText) {
    var raw = String(rawText == null ? '' : rawText).trim();
    var parseError = null;

    if (raw === '') {
      throw new Error('Empty response.');
    }

    if (raw.charAt(0) === '<') {
      throw new Error('Response was wrapped by the web UI or theme. Reload the page and try again.');
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
        var candidatePayload = JSON.parse(raw.slice(start, end + 1));
        if (isExpectedJsonPayload(candidatePayload)) {
          return candidatePayload;
        }
      } catch (candidateError) {
        parseError = parseError || candidateError;
      }
    }

    throw parseError || new Error('Invalid JSON response.');
  }

  function progressHtml(percent) {
    var value = parseInt(percent, 10);
    if (isNaN(value) || value < 0) {
      value = 0;
    }
    if (value > 100) {
      value = 100;
    }
    return ''
      + '<div class="zfsas-progress">'
      + '<div class="zfsas-progress-track"><div class="zfsas-progress-fill" style="width:' + value + '%;"></div></div>'
      + '<div class="zfsas-progress-text">' + value + '%</div>'
      + '</div>';
  }

  function stateChip(label, kind) {
    var classes = 'zfsas-chip';
    if (kind === 'warn') {
      classes += ' warn';
    } else if (kind === 'error') {
      classes += ' error';
    }
    return '<span class="' + classes + '">' + escapeHtml(label) + '</span>';
  }

  function renderFeedback(message, kind) {
    var el = byId('migrate_feedback');
    if (!el) {
      return;
    }
    if (!message) {
      el.innerHTML = '';
      return;
    }
    var cls = 'zfsas-alert zfsas-alert-info';
    if (kind === 'error') {
      cls = 'zfsas-alert zfsas-alert-error';
    } else if (kind === 'warn') {
      cls = 'zfsas-alert zfsas-alert-warn';
    }
    el.innerHTML = '<div class="' + cls + '">' + escapeHtml(message) + '</div>';
  }

  function renderPageStatus(message, isError) {
    var el = byId('migrate_page_status');
    if (!el) {
      return;
    }
    el.textContent = message;
    el.classList.toggle('error', !!isError);
  }

  function normalizeStateLabel(value) {
    if (!value) {
      return 'Idle';
    }
    return String(value).replace(/_/g, ' ').replace(/\b\w/g, function (letter) {
      return letter.toUpperCase();
    });
  }

  function selectedDatasetValue() {
    var el = byId('migrate_dataset');
    return el ? String(el.value || '') : '';
  }

  function populateDatasetSelect(datasets, preferredValue) {
    var el = byId('migrate_dataset');
    if (!el) {
      return;
    }

    var currentValue = preferredValue || el.value || '';
    var html = '<option value="">Select a dataset</option>';
    (datasets || []).forEach(function (row) {
      html += '<option value="' + escapeHtml(row.dataset || '') + '">' + escapeHtml((row.dataset || '') + ' (' + (row.mountpoint || '') + ')') + '</option>';
    });
    el.innerHTML = html;

    if (currentValue !== '') {
      el.value = currentValue;
      if (el.value !== currentValue) {
        el.value = '';
      }
    }
  }

  function renderSummary(status) {
    var state = status && status.STATE ? status.STATE : '';
    var currentMessage = status && status.MESSAGE ? status.MESSAGE : '';
    var currentFolder = status && status.CURRENT_FOLDER ? status.CURRENT_FOLDER : '-';
    var totalFolders = parseInt(status && status.TOTAL_FOLDERS ? status.TOTAL_FOLDERS : '0', 10);
    var completedFolders = parseInt(status && status.COMPLETED_FOLDERS ? status.COMPLETED_FOLDERS : '0', 10);
    if (isNaN(totalFolders)) {
      totalFolders = 0;
    }
    if (isNaN(completedFolders)) {
      completedFolders = 0;
    }

    byId('summary_state').textContent = normalizeStateLabel(state || 'idle');
    byId('summary_dataset').textContent = status && status.DATASET ? status.DATASET : '-';
    byId('summary_folders').textContent = completedFolders + ' / ' + totalFolders;
    byId('summary_step').textContent = status && status.CURRENT_STEP ? normalizeStateLabel(status.CURRENT_STEP) : '-';
    byId('summary_overall_progress').innerHTML = progressHtml(status && status.OVERALL_PERCENT ? status.OVERALL_PERCENT : 0);
    byId('summary_folder_progress').innerHTML = progressHtml(status && status.CURRENT_FOLDER_PERCENT ? status.CURRENT_FOLDER_PERCENT : 0);

    var messageEl = byId('summary_message');
    if (currentMessage) {
      messageEl.style.display = '';
      messageEl.textContent = currentFolder !== '-' && currentMessage.indexOf(currentFolder) === -1 ? (currentFolder + ': ' + currentMessage) : currentMessage;
    } else {
      messageEl.style.display = 'none';
      messageEl.textContent = '';
    }

    var waitingEl = byId('migrate_waiting_notice');
    if (status && String(status.WAITING_FOR_SPACE || '0') === '1') {
      waitingEl.innerHTML = '<div class="zfsas-alert zfsas-alert-warn">Free space is too low for <strong>'
        + escapeHtml(status.WAITING_LABEL || 'the current folder')
        + '</strong>. Free up space on the destination pool and the migration will continue automatically. Required: '
        + escapeHtml(formatBytes(status.WAITING_REQUIRED_BYTES || 0))
        + ', available now: '
        + escapeHtml(formatBytes(status.WAITING_AVAILABLE_BYTES || 0))
        + '.</div>';
    } else {
      waitingEl.innerHTML = '';
    }
  }

  function renderFolderRows(preview, status) {
    var el = byId('migrate_folder_rows');
    if (!el) {
      return;
    }

    var useStatusRows = status && status.DATASET && status.DATASET === selectedDatasetValue() && Array.isArray(status.folders) && status.folders.length > 0;
    var rows = [];

    if (useStatusRows) {
      rows = status.folders.map(function (row) {
        return {
          name: row.name,
          targetDataset: row.targetDataset,
          sizeBytes: row.sizeBytes,
          state: row.state,
          message: row.message,
          progressPercent: row.progressPercent
        };
      });
    } else if (preview && Array.isArray(preview.folders)) {
      rows = preview.folders.map(function (row) {
        return {
          name: row.name,
          targetDataset: row.targetDataset,
          sizeBytes: row.sizeBytes,
          state: row.state,
          message: row.message,
          progressPercent: row.eligible ? 0 : 100
        };
      });
    }

    if (!rows.length) {
      el.innerHTML = '<tr><td colspan="6" class="zfsas-dm-help">No top-level folders to show for the selected dataset.</td></tr>';
      return;
    }

    var html = '';
    rows.forEach(function (row) {
      var state = String(row.state || 'unknown');
      var chipKind = state === 'failed' ? 'error' : ((state === 'eligible' || state === 'complete') ? '' : 'warn');
      html += '<tr>';
      html += '<td><code>' + escapeHtml(row.name || '') + '</code></td>';
      html += '<td><code>' + escapeHtml(row.targetDataset || '') + '</code></td>';
      html += '<td>' + escapeHtml(formatBytes(row.sizeBytes || 0)) + '</td>';
      html += '<td>' + stateChip(normalizeStateLabel(state), chipKind) + '</td>';
      html += '<td>' + progressHtml(row.progressPercent || 0) + '</td>';
      html += '<td>' + escapeHtml(row.message || '') + '</td>';
      html += '</tr>';
    });
    el.innerHTML = html;
  }

  function renderContainerRows(docker, status) {
    var el = byId('migrate_container_rows');
    if (!el) {
      return;
    }

    var html = '';
    var rows = [];

    if (status && Array.isArray(status.containers) && status.containers.length > 0) {
      rows = status.containers.map(function (row) {
        return {
          name: row.name,
          restartName: row.restartName,
          restartMax: row.restartMax,
          startState: row.startState,
          note: row.lastError || ((String(row.policyDisabled || '0') === '1') ? 'Restart policy temporarily forced to no during migration.' : '')
        };
      });
    } else if (docker && Array.isArray(docker.runningContainers) && docker.runningContainers.length > 0) {
      rows = docker.runningContainers.map(function (row) {
        return {
          name: row.name,
          restartName: row.restartName,
          restartMax: row.restartMax,
          startState: 'running_before_start',
          note: (row.restartName && row.restartName !== 'no') ? 'Tool will temporarily disable this restart policy while the migration is active.' : 'Will be stopped if it is still running when the migration starts.'
        };
      });
    }

    if (!rows.length) {
      el.innerHTML = '<tr><td colspan="4" class="zfsas-dm-help">No running containers are currently reported.</td></tr>';
      return;
    }

    rows.forEach(function (row) {
      var policy = row.restartName || 'no';
      if (policy === 'on-failure' && row.restartMax && row.restartMax !== '0') {
        policy += ':' + row.restartMax;
      }
      var state = String(row.startState || 'idle');
      var kind = (state === 'failed' || state === 'retry_failed') ? 'error' : ((state === 'running_before_start' || state === 'retry_pending') ? 'warn' : '');
      html += '<tr>';
      html += '<td><code>' + escapeHtml(row.name || '') + '</code></td>';
      html += '<td>' + stateChip(policy, policy === 'no' ? '' : 'warn') + '</td>';
      html += '<td>' + stateChip(normalizeStateLabel(state), kind) + '</td>';
      html += '<td>' + escapeHtml(row.note || '') + '</td>';
      html += '</tr>';
    });
    el.innerHTML = html;
  }

  function renderLog(lines) {
    var el = byId('migrate_log');
    if (!el) {
      return;
    }
    if (!Array.isArray(lines) || lines.length === 0) {
      el.textContent = 'No log output yet.';
      return;
    }
    el.textContent = lines.join('\n');
  }

  function refreshStatus() {
    var dataset = selectedDatasetValue();
    currentDataset = dataset;
    renderPageStatus('Refreshing dataset migrator status...', false);
    requestJson(
      statusUrl + '?dataset=' + encodeURIComponent(dataset) + '&_=' + Date.now(),
      function (payload) {
        var status = payload.status || {};
        populateDatasetSelect(payload.datasets || [], currentDataset || payload.selectedDataset || status.DATASET || '');
        renderSummary(status);
        renderFolderRows(payload.preview, status);
        renderContainerRows(payload.docker, status);
        renderLog(payload.logTail || []);

        if (payload.datasetError) {
          renderFeedback(payload.datasetError, 'error');
        } else if (payload.previewError && currentDataset !== '') {
          renderFeedback(payload.previewError, 'error');
        } else if (payload.docker && payload.docker.error) {
          renderFeedback(payload.docker.error, 'warn');
        } else {
          renderFeedback('', '');
        }

        if (status && status.isActive) {
          renderPageStatus('Dataset migration is running in the background.', false);
        } else {
          renderPageStatus('Dataset migrator is ready.', false);
        }
      },
      function (error) {
        renderPageStatus('Dataset migrator refresh failed: ' + error.message, true);
      }
    );
  }

  function startPolling() {
    if (pollTimer !== null) {
      window.clearInterval(pollTimer);
    }
    refreshStatus();
    pollTimer = window.setInterval(refreshStatus, 5000);
  }

  var datasetSelect = byId('migrate_dataset');
  if (datasetSelect) {
    datasetSelect.addEventListener('change', function () {
      currentDataset = datasetSelect.value || '';
      refreshStatus();
    });
  }

  var refreshButton = byId('migrate_refresh');
  if (refreshButton) {
    refreshButton.addEventListener('click', function () {
      refreshStatus();
    });
  }

  var startButton = byId('migrate_start');
  if (startButton) {
    startButton.addEventListener('click', function () {
      var dataset = selectedDatasetValue();
      if (!dataset || startBusy) {
        if (!dataset) {
          renderFeedback('Choose a dataset first.', 'warn');
        }
        return;
      }

      startBusy = true;
      startButton.disabled = true;
      renderPageStatus('Starting dataset migration...', false);
      renderFeedback('', '');

      requestJsonPost(
        actionUrl,
        {action: 'start', dataset: dataset},
        function (payload) {
          startBusy = false;
          startButton.disabled = false;
          renderFeedback(payload && payload.message ? payload.message : 'Dataset migration started.', 'info');
          refreshStatus();
        },
        function (error, payload) {
          startBusy = false;
          startButton.disabled = false;
          renderFeedback((payload && payload.error) ? payload.error : error.message, 'error');
          renderPageStatus('Dataset migration did not start.', true);
        }
      );
    });
  }

  startPolling();
})();
</script>
</body>
</html>
