<?php
$pluginName = 'zfs.autosnapshot';
$statusUrl = "/plugins/{$pluginName}/php/recovery-status.php";
$actionUrl = "/plugins/{$pluginName}/php/recovery-action.php";
$mainSettingsUrl = '/Settings/ZFSAutoSnapshot?section=repair-tools';
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
  <title>Recovery Tools</title>
  <style>
    body {
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      margin: 0;
      background: var(--body-background, #f5f7fb);
      color: var(--text-color, #1f2933);
    }
    .zfsas-rt-page {
      max-width: 1320px;
      margin: 20px auto;
      padding: 0 18px 24px;
    }
    .zfsas-rt-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      flex-wrap: wrap;
      margin-bottom: 14px;
    }
    .zfsas-rt-subtitle {
      margin-top: 6px;
      color: var(--text-color, #4f5a66);
      opacity: 0.86;
    }
    .zfsas-rt-card {
      background: var(--background-color, #fff);
      border: 1px solid var(--border-color, #d9e1ea);
      border-radius: 10px;
      padding: 16px;
      margin-bottom: 14px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
    }
    .zfsas-rt-help {
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
      font-size: 12px;
      line-height: 1.45;
    }
    .zfsas-rt-toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 14px;
    }
    .zfsas-rt-status {
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
    }
    .zfsas-rt-status.error {
      color: #8f2d2a;
      opacity: 1;
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
    .zfsas-rt-select {
      min-width: 280px;
      padding: 8px 10px;
      border-radius: 8px;
      border: 1px solid var(--input-border-color, var(--border-color, #b8c5d1));
      background: var(--input-background-color, var(--background-color, #fff));
      color: var(--text-color, #1f2933);
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
    .zfsas-chip {
      display: inline-flex;
      align-items: center;
      padding: 4px 8px;
      border-radius: 999px;
      background: rgba(82, 126, 235, 0.12);
      font-size: 12px;
      white-space: nowrap;
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
  </style>
</head>
<body>
<div class="zfsas-rt-page">
  <div class="zfsas-rt-header">
    <div>
      <h2 style="margin:0;">Recovery Tools</h2>
      <div class="zfsas-rt-subtitle">Scrub visibility, corruption clues, and a manual readability scan when scrub data does not tell us exactly which file is bad.</div>
    </div>
    <div>
      <a class="btn" href="<?php echo htmlspecialchars($mainSettingsUrl, ENT_QUOTES, 'UTF-8'); ?>">Back to Main Settings</a>
    </div>
  </div>

  <div class="zfsas-alert zfsas-alert-warn">
    <code>Recovery Tools</code> is still unfinished and may not work correctly yet. Treat the current workflows as preview diagnostics and verify any results manually before relying on them.
  </div>

  <div class="zfsas-rt-card">
    <h3 style="margin-top:0;">Corruption Overview</h3>
    <div class="zfsas-rt-help">
      This page surfaces current scrub state and any corruption clues reported by ZFS. If scrub output identifies file paths, they will appear here. If corruption is detected but cannot be mapped back to a file, it will be shown as an unmapped issue so we know the pool is unhealthy even when the exact file is not known yet.
    </div>
    <div class="zfsas-rt-toolbar">
      <button type="button" class="btn" id="recovery_refresh">Refresh Recovery Status</button>
      <div id="recovery_status" class="zfsas-rt-status">Loading recovery status...</div>
    </div>
    <div id="recovery_feedback"></div>
    <div class="zfsas-table-wrap">
      <table class="zfsas-table">
        <thead>
          <tr>
            <th>Pool</th>
            <th>Scrub / Scan</th>
            <th>Errors</th>
            <th>Identified Files</th>
            <th>Unmapped Issues</th>
          </tr>
        </thead>
        <tbody id="recovery_pool_rows">
          <tr>
            <td colspan="5" class="zfsas-rt-help">Recovery status will load in a moment.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="zfsas-rt-card">
    <h3 style="margin-top:0;">Manual Diagnostic Scan</h3>
    <div class="zfsas-rt-help">
      Use this when scrub says something is wrong but does not identify the file. The diagnostic scan walks the selected mounted dataset and attempts to read each file. It is a manual diagnostic tool, not a guaranteed repair. Metadata damage or wider dataset corruption can still leave us with a pool that must be recreated even if this scan finds nothing useful.
    </div>
    <div class="zfsas-rt-toolbar">
      <select id="recovery_dataset" class="zfsas-rt-select"></select>
      <button type="button" class="btn btn-primary" id="recovery_start_scan">Start Readability Scan</button>
      <div id="recovery_scan_status" class="zfsas-rt-status">Choose a dataset to start a manual diagnostic scan.</div>
    </div>
    <div class="zfsas-table-wrap">
      <table class="zfsas-table">
        <thead>
          <tr>
            <th>Dataset</th>
            <th>Mountpoint</th>
            <th>Status</th>
            <th>Progress</th>
            <th>Unreadable Files</th>
            <th>Last Path</th>
          </tr>
        </thead>
        <tbody id="recovery_scan_rows">
          <tr>
            <td colspan="6" class="zfsas-rt-help">No scan data yet.</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<script>
(function () {
  var statusUrl = <?php echo json_encode($statusUrl); ?>;
  var actionUrl = <?php echo json_encode($actionUrl); ?>;
  var pollTimer = null;

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

  function parsePossiblyWrappedJson(rawText) {
    var raw = String(rawText == null ? '' : rawText).trim();
    if (raw === '') {
      throw new Error('Empty response.');
    }
    var marked = extractMarkedJson(raw);
    if (marked !== null) {
      return JSON.parse(marked);
    }
    return JSON.parse(raw);
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
        onError(new Error('Invalid JSON response.'));
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
      } catch (ignored) {
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
      params.append(key, bodyParams[key]);
    });
    if (csrfToken !== '') {
      params.append('csrf_token', csrfToken);
    }
    xhr.send(params.toString());
  }

  function setStatus(message, isError) {
    var node = byId('recovery_status');
    if (!node) {
      return;
    }
    node.textContent = message;
    node.classList.toggle('error', !!isError);
  }

  function setScanStatus(message, isError) {
    var node = byId('recovery_scan_status');
    if (!node) {
      return;
    }
    node.textContent = message;
    node.classList.toggle('error', !!isError);
  }

  function renderFeedback(messages, isError) {
    var node = byId('recovery_feedback');
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

  function progressHtml(scan) {
    var total = parseInt(scan.totalFiles || 0, 10);
    var scanned = parseInt(scan.scannedFiles || 0, 10);
    var percent = 0;
    if (total > 0) {
      percent = Math.min(100, Math.max(0, Math.round((scanned / total) * 100)));
    } else if (String(scan.state || '') === 'complete') {
      percent = 100;
    }
    return ''
      + '<div class="zfsas-progress">'
      + '<div class="zfsas-progress-track"><div class="zfsas-progress-fill" style="width: ' + percent + '%;"></div></div>'
      + '<div class="zfsas-progress-text">' + percent + '%</div>'
      + '</div>';
  }

  function renderPools(pools, poolError) {
    var tbody = byId('recovery_pool_rows');
    if (!tbody) {
      return;
    }
    if (poolError) {
      tbody.innerHTML = '<tr><td colspan="5" class="zfsas-rt-help">' + escapeHtml(poolError) + '</td></tr>';
      return;
    }
    if (!Array.isArray(pools) || pools.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" class="zfsas-rt-help">No pools were reported by zpool status.</td></tr>';
      return;
    }

    var html = '';
    pools.forEach(function (pool) {
      html += '<tr>';
      html += '<td><strong>' + escapeHtml(pool.name || '') + '</strong><div class="zfsas-rt-help" style="margin-top:4px;">' + escapeHtml(pool.state || 'unknown') + '</div></td>';
      html += '<td>' + escapeHtml(pool.scan || 'No active scrub reported.') + '</td>';
      html += '<td>' + escapeHtml(pool.errors || 'No known data errors') + '</td>';
      html += '<td>';
      if (Array.isArray(pool.identifiedFiles) && pool.identifiedFiles.length > 0) {
        pool.identifiedFiles.forEach(function (entry) {
          html += '<div><code>' + escapeHtml(entry) + '</code></div>';
        });
      } else {
        html += '<span class="zfsas-rt-help">No positively identified file paths.</span>';
      }
      html += '</td>';
      html += '<td>';
      if (Array.isArray(pool.unmappedIssues) && pool.unmappedIssues.length > 0) {
        pool.unmappedIssues.forEach(function (entry) {
          html += '<div>' + escapeHtml(entry) + '</div>';
        });
      } else {
        html += '<span class="zfsas-rt-help">None reported.</span>';
      }
      html += '</td>';
      html += '</tr>';
    });
    tbody.innerHTML = html;
  }

  function renderDatasetOptions(datasets) {
    var select = byId('recovery_dataset');
    if (!select) {
      return;
    }
    var currentValue = select.value || '';
    var html = '<option value="">Choose a mounted dataset</option>';
    (datasets || []).forEach(function (row) {
      var mountpoint = row.mountpoint || '';
      var disabled = (mountpoint === '' || mountpoint === 'legacy' || mountpoint === 'none');
      html += '<option value="' + escapeHtml(row.dataset || '') + '"' + (disabled ? ' disabled' : '') + '>' + escapeHtml(row.dataset || '') + (disabled ? ' (not directly mounted)' : '') + '</option>';
    });
    select.innerHTML = html;

    if (currentValue !== '') {
      Array.prototype.slice.call(select.options || []).some(function (option) {
        if (option.value === currentValue && !option.disabled) {
          select.value = currentValue;
          return true;
        }
        return false;
      });
    }
  }

  function renderScans(scans) {
    var tbody = byId('recovery_scan_rows');
    if (!tbody) {
      return;
    }
    if (!Array.isArray(scans) || scans.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" class="zfsas-rt-help">No recovery scan data yet.</td></tr>';
      return;
    }

    var html = '';
    scans.forEach(function (scan) {
      var state = String(scan.state || 'unknown');
      var badgeClass = (state === 'failed') ? ' error' : '';
      html += '<tr>';
      html += '<td><code>' + escapeHtml(scan.dataset || '') + '</code></td>';
      html += '<td>' + escapeHtml(scan.mountpoint || '') + '</td>';
      html += '<td><span class="zfsas-chip' + badgeClass + '">' + escapeHtml(state) + '</span></td>';
      html += '<td>' + progressHtml(scan) + '</td>';
      html += '<td>' + escapeHtml(String(scan.unreadableCount || 0)) + '</td>';
      html += '<td>' + escapeHtml(scan.lastPath || '') + '</td>';
      html += '</tr>';
    });
    tbody.innerHTML = html;
  }

  function loadStatus() {
    setStatus('Refreshing recovery status...', false);
    requestJson(
      statusUrl + '?_=' + Date.now(),
      function (payload) {
        renderPools(payload.pools || [], payload.poolError || null);
        renderDatasetOptions(payload.datasets || []);
        renderScans(payload.scans || []);
        if (payload.datasetError) {
          renderFeedback([payload.datasetError], true);
        } else {
          renderFeedback([], false);
        }
        setStatus('Recovery status refreshed.', false);
      },
      function (error) {
        setStatus('Recovery status failed: ' + error.message, true);
      }
    );
  }

  byId('recovery_refresh').addEventListener('click', loadStatus);
  byId('recovery_start_scan').addEventListener('click', function () {
    var dataset = (byId('recovery_dataset').value || '').trim();
    if (dataset === '') {
      setScanStatus('Choose a mounted dataset first.', true);
      return;
    }
    setScanStatus('Starting manual readability scan...', false);
    requestJsonPost(
      actionUrl,
      {action: 'start_scan', dataset: dataset},
      function (payload) {
        setScanStatus(payload.message || 'Manual readability scan started.', false);
        loadStatus();
      },
      function (error, payload) {
        setScanStatus((payload && payload.error) ? payload.error : error.message, true);
      }
    );
  });

  loadStatus();
  pollTimer = window.setInterval(loadStatus, 5000);
})();
</script>
</body>
</html>
