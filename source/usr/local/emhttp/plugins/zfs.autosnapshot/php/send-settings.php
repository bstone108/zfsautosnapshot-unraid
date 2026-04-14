<?php
$pluginName = 'zfs.autosnapshot';
$configDir = "/boot/config/plugins/{$pluginName}";
$configFile = "{$configDir}/zfs_send.conf";
$syncScript = "/usr/local/emhttp/plugins/{$pluginName}/scripts/sync-cron.sh";
$saveApiUrl = "/plugins/{$pluginName}/php/save-send-settings.php";
$runApiUrl = "/plugins/{$pluginName}/php/run-send-now.php";
$mainSettingsUrl = '/Settings/ZFSAutoSnapshot?section=special-features';

require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-helpers.php';

$defaults = [
    'SEND_SNAPSHOT_PREFIX' => 'zfs-send-',
    'SEND_JOBS' => '',
];

function zfsas_send_is_ajax_request()
{
    if (($_POST['ajax'] ?? '') === 'save') {
        return true;
    }

    $requestedWith = $_SERVER['HTTP_X_REQUESTED_WITH'] ?? '';
    return is_string($requestedWith) && strcasecmp($requestedWith, 'XMLHttpRequest') === 0;
}

function zfsas_send_current_page_url($fallback)
{
    $requestUri = (string) ($_SERVER['REQUEST_URI'] ?? '');
    if ($requestUri === '') {
        return $fallback;
    }

    $parts = parse_url($requestUri);
    if (!is_array($parts)) {
        return $fallback;
    }

    $path = (string) ($parts['path'] ?? '');
    if ($path === '') {
        return $fallback;
    }

    $query = [];
    if (isset($parts['query'])) {
        parse_str((string) $parts['query'], $query);
    }
    unset($query['saved']);

    $queryString = http_build_query($query);
    return ($queryString === '') ? $path : ($path . '?' . $queryString);
}

function zfsas_send_render_jobs_string($jobs)
{
    $parts = [];
    foreach ($jobs as $job) {
        $parts[] = implode('|', [
            $job['id'],
            $job['source'],
            $job['destination'],
            $job['frequency'],
            $job['threshold'],
        ]);
    }

    return implode(';', $parts);
}

function zfsas_send_collect_submitted_jobs($post, &$errors)
{
    $jobs = [];
    $seenJobIds = [];

    $jobIds = (isset($post['job_id']) && is_array($post['job_id'])) ? $post['job_id'] : [];
    $sources = (isset($post['job_source']) && is_array($post['job_source'])) ? $post['job_source'] : [];
    $destinations = (isset($post['job_destination']) && is_array($post['job_destination'])) ? $post['job_destination'] : [];
    $frequencies = (isset($post['job_frequency']) && is_array($post['job_frequency'])) ? $post['job_frequency'] : [];
    $thresholds = (isset($post['job_threshold']) && is_array($post['job_threshold'])) ? $post['job_threshold'] : [];
    $removes = (isset($post['job_remove']) && is_array($post['job_remove'])) ? $post['job_remove'] : [];

    foreach ($sources as $index => $sourceRaw) {
        if (isset($removes[$index]) && (string) $removes[$index] === '1') {
            continue;
        }

        $source = zfsas_send_trim($sourceRaw);
        $destination = zfsas_send_trim($destinations[$index] ?? '');
        $frequency = zfsas_send_normalize_frequency($frequencies[$index] ?? '');
        $threshold = zfsas_send_normalize_threshold($thresholds[$index] ?? '');
        $jobId = zfsas_send_trim($jobIds[$index] ?? '');

        if ($source === '' && $destination === '') {
            continue;
        }

        if (!zfsas_send_is_valid_dataset_name($source)) {
            $errors[] = "Invalid source dataset '{$source}'.";
            continue;
        }

        if (!zfsas_send_is_valid_dataset_name($destination)) {
            $errors[] = "Invalid destination dataset '{$destination}'.";
            continue;
        }

        if ($source === $destination) {
            $errors[] = "Source and destination must be different for '{$source}'.";
            continue;
        }

        if (strpos($destination, '/') === false) {
            $errors[] = "Destination '{$destination}' must include a dataset below a pool root.";
            continue;
        }

        if ($frequency === null) {
            $errors[] = "Invalid frequency for '{$source}' -> '{$destination}'.";
            continue;
        }

        if ($threshold === null) {
            $errors[] = "Destination free-space target for '{$source}' -> '{$destination}' is invalid.";
            continue;
        }

        if ($jobId === '') {
            $jobId = zfsas_send_job_id($source, $destination);
        }

        if (isset($seenJobIds[$jobId])) {
            $errors[] = "Duplicate ZFS send job '{$source}' -> '{$destination}' detected.";
            continue;
        }

        $jobs[] = [
            'id' => $jobId,
            'source' => $source,
            'destination' => $destination,
            'destination_pool' => zfsas_send_dataset_pool_name($destination),
            'frequency' => $frequency,
            'frequency_label' => zfsas_send_frequency_label($frequency),
            'threshold' => $threshold,
        ];
        $seenJobIds[$jobId] = true;
    }

    $newSource = zfsas_send_trim($post['new_job_source'] ?? '');
    $newDestination = zfsas_send_trim($post['new_job_destination'] ?? '');
    $newFrequencyRaw = zfsas_send_trim($post['new_job_frequency'] ?? '');
    $newThresholdRaw = zfsas_send_trim($post['new_job_threshold'] ?? '');

    if ($newSource !== '' || $newDestination !== '' || $newFrequencyRaw !== '' || $newThresholdRaw !== '') {
        $newFrequency = zfsas_send_normalize_frequency($newFrequencyRaw);
        $newThreshold = zfsas_send_normalize_threshold($newThresholdRaw);

        if (!zfsas_send_is_valid_dataset_name($newSource)) {
            $errors[] = 'New ZFS send source dataset is invalid.';
        } elseif (!zfsas_send_is_valid_dataset_name($newDestination)) {
            $errors[] = 'New ZFS send destination dataset is invalid.';
        } elseif ($newSource === $newDestination) {
            $errors[] = 'New ZFS send source and destination must be different.';
        } elseif (strpos($newDestination, '/') === false) {
            $errors[] = 'New ZFS send destination must include a dataset below a pool root.';
        } elseif ($newFrequency === null) {
            $errors[] = 'New ZFS send frequency is invalid.';
        } elseif ($newThreshold === null) {
            $errors[] = 'New ZFS send destination free-space target is invalid.';
        } else {
            $newJobId = zfsas_send_job_id($newSource, $newDestination);
            if (isset($seenJobIds[$newJobId])) {
                $errors[] = 'This ZFS send source/destination pair already exists.';
            } else {
                $jobs[] = [
                    'id' => $newJobId,
                    'source' => $newSource,
                    'destination' => $newDestination,
                    'destination_pool' => zfsas_send_dataset_pool_name($newDestination),
                    'frequency' => $newFrequency,
                    'frequency_label' => zfsas_send_frequency_label($newFrequency),
                    'threshold' => $newThreshold,
                ];
            }
        }
    }

    usort($jobs, function ($a, $b) {
        $sourceCompare = strnatcasecmp((string) ($a['source'] ?? ''), (string) ($b['source'] ?? ''));
        if ($sourceCompare !== 0) {
            return $sourceCompare;
        }

        return strnatcasecmp((string) ($a['destination'] ?? ''), (string) ($b['destination'] ?? ''));
    });

    return $jobs;
}

$isPostRequest = (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST');
$isAjaxSaveRequest = ((defined('ZFSAS_FORCE_SEND_AJAX_SAVE') && ZFSAS_FORCE_SEND_AJAX_SAVE) || ($isPostRequest && zfsas_send_is_ajax_request()));
$defaultReturnUrl = zfsas_send_current_page_url('/plugins/zfs.autosnapshot/php/send-settings.php');

$config = zfsas_send_parse_config_file($configFile, $defaults);
$errors = [];
$notices = [];
$parseErrors = [];
$parseWarnings = [];
$jobs = zfsas_send_parse_jobs($config['SEND_JOBS'] ?? '', $parseErrors, $parseWarnings);
$formJobs = $jobs;
$datasetDiscoveryError = null;
$availableDatasets = zfsas_send_list_zfs_datasets($datasetDiscoveryError);

if (($_GET['saved'] ?? '') === '1' && !$isPostRequest) {
    $notices[] = 'ZFS send settings saved and schedule applied.';
}

foreach ($parseWarnings as $warning) {
    $notices[] = $warning;
}

if ($isPostRequest) {
    $submitted = $config;
    $submitted['SEND_SNAPSHOT_PREFIX'] = zfsas_send_trim($_POST['send_snapshot_prefix'] ?? $submitted['SEND_SNAPSHOT_PREFIX']);
    $submittedJobs = zfsas_send_collect_submitted_jobs($_POST, $errors);
    $formJobs = $submittedJobs;

    if ($submitted['SEND_SNAPSHOT_PREFIX'] === '') {
        $errors[] = 'Send snapshot prefix cannot be empty.';
    } elseif (strpos($submitted['SEND_SNAPSHOT_PREFIX'], '@') !== false) {
        $errors[] = 'Send snapshot prefix cannot contain @.';
    } elseif (preg_match('/^[A-Za-z0-9._:-]+$/', $submitted['SEND_SNAPSHOT_PREFIX']) !== 1) {
        $errors[] = 'Send snapshot prefix can only contain letters, numbers, dot, underscore, colon, and dash.';
    }

    if (empty($errors)) {
        $submitted['SEND_JOBS'] = zfsas_send_render_jobs_string($submittedJobs);
        $config = $submitted;

        if (!is_dir($configDir)) {
            @mkdir($configDir, 0775, true);
        }

        $written = @file_put_contents($configFile, zfsas_send_render_config($config));
        if ($written === false) {
            $errors[] = "Unable to write config file: {$configFile}";
        } else {
            @chmod($configFile, 0644);
            $syncOutput = [];
            $syncExit = 0;
            @exec(escapeshellcmd($syncScript) . ' 2>&1', $syncOutput, $syncExit);

            if ($syncExit !== 0) {
                $errors[] = 'Settings saved, but failed to apply scheduler: ' . implode(' | ', $syncOutput);
            } else {
                $notices[] = 'ZFS send settings saved and schedule applied.';

                if (!$isAjaxSaveRequest) {
                    $returnTarget = zfsas_normalize_return_url($_POST['return_to'] ?? '', $defaultReturnUrl);
                    $separator = (strpos($returnTarget, '?') === false) ? '?' : '&';
                    zfsas_send_redirect_page($returnTarget . $separator . 'saved=1', 'ZFS send settings saved. Returning to the send settings page...');
                }
            }
        }
    }

    if ($isAjaxSaveRequest) {
        zfsas_emit_marked_json([
            'ok' => empty($errors),
            'errors' => array_values($errors),
            'notices' => array_values($notices),
            'jobCount' => count($formJobs),
        ], empty($errors) ? 200 : 400);
    }
}
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZFS Send Settings</title>
  <style>
    body {
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      margin: 0;
      background: var(--body-background, #f5f7fb);
      color: var(--text-color, #1f2933);
    }

    .zfsas-send-wrap {
      max-width: 1180px;
      margin: 20px auto;
      padding: 0 18px 24px;
    }

    .zfsas-send-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 14px;
    }

    .zfsas-send-title h2 {
      margin: 0;
    }

    .zfsas-send-subtitle {
      margin-top: 6px;
      color: var(--text-color, #4f5a66);
      opacity: 0.85;
    }

    .zfsas-send-card {
      background: var(--background-color, #fff);
      border: 1px solid var(--border-color, #d9e1ea);
      border-radius: 10px;
      padding: 16px;
      margin-bottom: 14px;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
    }

    .zfsas-send-help {
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
      font-size: 12px;
      line-height: 1.45;
    }

    .zfsas-send-table-wrap {
      margin-top: 12px;
      border: 1px solid var(--border-color, #e1e8ef);
      border-radius: 8px;
      overflow-x: auto;
    }

    .zfsas-send-table {
      width: 100%;
      border-collapse: collapse;
      min-width: 860px;
    }

    .zfsas-send-table th,
    .zfsas-send-table td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--border-color, #edf2f7);
      vertical-align: top;
    }

    .zfsas-send-table tr:last-child td {
      border-bottom: none;
    }

    .zfsas-send-table th {
      background: rgba(82, 126, 235, 0.06);
      text-align: left;
      font-size: 13px;
    }

    .zfsas-send-input,
    .zfsas-send-select {
      width: 100%;
      box-sizing: border-box;
      padding: 8px 10px;
      border: 1px solid var(--input-border-color, var(--border-color, #b8c5d1));
      border-radius: 8px;
      background: var(--input-background-color, var(--background-color, #fff));
      color: var(--text-color, #1f2933);
    }

    .zfsas-send-add-row {
      display: grid;
      grid-template-columns: 1.3fr 1.4fr 0.9fr 0.7fr auto;
      gap: 10px;
      align-items: end;
      margin-top: 14px;
    }

    .zfsas-send-field {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .zfsas-send-field label {
      font-weight: 600;
      font-size: 13px;
    }

    .zfsas-send-actions {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 16px;
    }

    .zfsas-send-run-status {
      margin-right: auto;
      font-size: 12px;
      color: var(--text-color, #4f5a66);
      opacity: 0.82;
    }

    .zfsas-send-run-status.error {
      color: var(--text-color, #8f2d2a);
      opacity: 1;
    }

    .zfsas-send-feedback {
      flex: 0 0 360px;
      width: 360px;
      min-height: 28px;
      display: flex;
      align-items: center;
      justify-content: flex-end;
    }

    .zfsas-send-alert {
      border-radius: 8px;
      padding: 8px 10px;
      width: 100%;
      font-size: 12px;
      margin: 0;
    }

    .zfsas-send-alert-error {
      background: rgba(176, 0, 32, 0.08);
      border: 1px solid rgba(176, 0, 32, 0.28);
    }

    .zfsas-send-empty {
      margin-top: 12px;
      padding: 12px;
      border: 1px dashed var(--border-color, #c8d5e3);
      border-radius: 8px;
      background: rgba(82, 126, 235, 0.04);
    }

    @media (max-width: 980px) {
      .zfsas-send-add-row {
        grid-template-columns: 1fr;
      }

      .zfsas-send-feedback {
        flex: 1 1 100%;
        width: 100%;
        justify-content: flex-start;
      }

      .zfsas-send-run-status {
        margin-right: 0;
        width: 100%;
      }
    }
  </style>
</head>
<body>
<div class="zfsas-send-wrap">
  <div class="zfsas-send-header">
    <div class="zfsas-send-title">
      <h2>ZFS Send</h2>
      <div class="zfsas-send-subtitle">Replicate selected source datasets into manually chosen destination datasets using a dedicated send snapshot chain.</div>
    </div>
    <div>
      <a class="btn" href="<?php echo zfsas_send_h($mainSettingsUrl); ?>">Back to Main Settings</a>
    </div>
  </div>

  <?php if ($datasetDiscoveryError !== null) : ?>
    <div class="zfsas-send-card">
      <div class="zfsas-send-help"><?php echo zfsas_send_h($datasetDiscoveryError); ?></div>
    </div>
  <?php endif; ?>

  <?php if (!empty($notices)) : ?>
    <div class="zfsas-send-card">
      <?php foreach ($notices as $notice) : ?>
        <div class="zfsas-send-help" style="margin-bottom: 6px;"><?php echo zfsas_send_h($notice); ?></div>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>

  <form method="post" action="<?php echo zfsas_send_h($saveApiUrl); ?>" data-ajax-action="<?php echo zfsas_send_h($saveApiUrl); ?>" id="zfsas_send_form">
    <input type="hidden" name="return_to" value="<?php echo zfsas_send_h($defaultReturnUrl); ?>">

    <div class="zfsas-send-card">
      <h3 style="margin-top:0;">Replication Jobs</h3>
      <div class="zfsas-send-help">
        Each job keeps its own send-only snapshot chain so the regular autosnapshot cleanup never touches replication checkpoints. After a successful send, the script keeps only the newest send snapshot for that job on both source and destination.
        Saving an empty job list disables scheduled ZFS send runs without affecting your regular autosnapshot jobs.
      </div>

      <div class="zfsas-send-field" style="margin-top:14px; max-width:320px;">
        <label for="send_snapshot_prefix">Send snapshot prefix base</label>
        <input id="send_snapshot_prefix" name="send_snapshot_prefix" class="zfsas-send-input" value="<?php echo zfsas_send_h($config['SEND_SNAPSHOT_PREFIX']); ?>">
        <div class="zfsas-send-help">The script appends a per-job id automatically so each replication path gets its own isolated send snapshot namespace.</div>
      </div>

      <?php if (count($formJobs) === 0) : ?>
        <div class="zfsas-send-empty">No ZFS send jobs are configured yet. Add one below, then save.</div>
      <?php endif; ?>

      <div class="zfsas-send-table-wrap">
        <table class="zfsas-send-table" id="zfsas_send_jobs_table">
          <thead>
            <tr>
              <th>Source dataset</th>
              <th>Destination dataset</th>
              <th>Frequency</th>
              <th>Destination free-space target</th>
              <th style="width:90px;">Remove</th>
            </tr>
          </thead>
          <tbody id="zfsas_send_jobs_body">
            <?php foreach ($formJobs as $index => $job) : ?>
              <tr>
                <td>
                  <input type="hidden" name="job_id[<?php echo (int) $index; ?>]" value="<?php echo zfsas_send_h($job['id']); ?>">
                  <select name="job_source[<?php echo (int) $index; ?>]" class="zfsas-send-select">
                    <?php foreach ($availableDatasets as $dataset) : ?>
                      <option value="<?php echo zfsas_send_h($dataset); ?>" <?php echo ($dataset === $job['source']) ? 'selected' : ''; ?>><?php echo zfsas_send_h($dataset); ?></option>
                    <?php endforeach; ?>
                  </select>
                </td>
                <td><input class="zfsas-send-input" name="job_destination[<?php echo (int) $index; ?>]" value="<?php echo zfsas_send_h($job['destination']); ?>"></td>
                <td>
                  <select name="job_frequency[<?php echo (int) $index; ?>]" class="zfsas-send-select">
                    <?php foreach (zfsas_send_frequency_options() as $value => $label) : ?>
                      <option value="<?php echo zfsas_send_h($value); ?>" <?php echo ($value === $job['frequency']) ? 'selected' : ''; ?>><?php echo zfsas_send_h($label); ?></option>
                    <?php endforeach; ?>
                  </select>
                </td>
                <td><input class="zfsas-send-input" name="job_threshold[<?php echo (int) $index; ?>]" value="<?php echo zfsas_send_h($job['threshold']); ?>"></td>
                <td>
                  <input type="hidden" name="job_remove[<?php echo (int) $index; ?>]" value="0" class="zfsas-send-remove-flag">
                  <button type="button" class="btn zfsas-send-remove-row">Remove</button>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>

      <div class="zfsas-send-add-row">
        <div class="zfsas-send-field">
          <label for="new_job_source">Source dataset</label>
          <select id="new_job_source" name="new_job_source" class="zfsas-send-select">
            <option value="">Select source dataset</option>
            <?php foreach ($availableDatasets as $dataset) : ?>
              <option value="<?php echo zfsas_send_h($dataset); ?>"><?php echo zfsas_send_h($dataset); ?></option>
            <?php endforeach; ?>
          </select>
        </div>
        <div class="zfsas-send-field">
          <label for="new_job_destination">Destination dataset</label>
          <input id="new_job_destination" name="new_job_destination" class="zfsas-send-input" placeholder="backup/replicas/example">
        </div>
        <div class="zfsas-send-field">
          <label for="new_job_frequency">Frequency</label>
          <select id="new_job_frequency" name="new_job_frequency" class="zfsas-send-select">
            <?php foreach (zfsas_send_frequency_options() as $value => $label) : ?>
              <option value="<?php echo zfsas_send_h($value); ?>"><?php echo zfsas_send_h($label); ?></option>
            <?php endforeach; ?>
          </select>
        </div>
        <div class="zfsas-send-field">
          <label for="new_job_threshold">Destination free-space target</label>
          <input id="new_job_threshold" name="new_job_threshold" class="zfsas-send-input" placeholder="100G" value="100G">
        </div>
        <div class="zfsas-send-field">
          <label>&nbsp;</label>
          <button type="button" class="btn" id="zfsas_add_send_job">Add Job</button>
        </div>
      </div>
    </div>

    <div class="zfsas-send-actions">
      <div id="send_run_status" class="zfsas-send-run-status">Manual ZFS send is ready.</div>
      <div id="send_feedback" class="zfsas-send-feedback">
        <?php if (!empty($errors)) : ?>
          <div class="zfsas-send-alert zfsas-send-alert-error">
            <?php foreach ($errors as $error) : ?>
              <div><?php echo zfsas_send_h($error); ?></div>
            <?php endforeach; ?>
          </div>
        <?php endif; ?>
      </div>
      <button type="button" class="btn" id="run_send_now">Run ZFS Send Now</button>
      <button type="button" class="btn btn-primary" id="save_send_btn" <?php if (($_GET['saved'] ?? '') === '1' && !$isPostRequest) : ?>data-show-saved="1"<?php endif; ?>>Save ZFS Send Settings</button>
      <noscript><button type="submit" class="btn btn-primary">Save ZFS Send Settings</button></noscript>
    </div>
  </form>
</div>

<script>
(function () {
  function byId(id) {
    return document.getElementById(id);
  }

  var saveForm = byId('zfsas_send_form');
  var saveButton = byId('save_send_btn');
  var saveButtonDefaultText = saveButton ? saveButton.textContent : 'Save ZFS Send Settings';
  var saveBusy = false;
  var saveSuccessTimer = null;
  var runButton = byId('run_send_now');
  var runBusy = false;
  var saveApiUrl = <?php echo json_encode($saveApiUrl); ?>;
  var runApiUrl = <?php echo json_encode($runApiUrl); ?>;
  var jobsBody = byId('zfsas_send_jobs_body');

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
      var value = globalCandidates[i];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
    }

    var inputSelectors = [
      'input[name="csrf_token"]',
      'input[name="csrf-token"]',
      'input[name="_csrf"]'
    ];
    for (var j = 0; j < inputSelectors.length; j += 1) {
      var csrfInput = document.querySelector(inputSelectors[j]);
      if (csrfInput && typeof csrfInput.value === 'string' && csrfInput.value.length > 0) {
        return csrfInput.value;
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

    throw parseError || new Error('Invalid JSON response.');
  }

  function renderFeedback(errors) {
    var feedbackEl = byId('send_feedback');
    if (!feedbackEl) {
      return;
    }

    var html = '';
    if (Array.isArray(errors) && errors.length > 0) {
      html += '<div class="zfsas-send-alert zfsas-send-alert-error">';
      errors.forEach(function (message) {
        html += '<div>' + escapeHtml(message) + '</div>';
      });
      html += '</div>';
    }

    feedbackEl.innerHTML = html;
  }

  function clearSaveButtonSuccessState() {
    if (!saveButton) {
      return;
    }
    if (saveSuccessTimer !== null) {
      window.clearTimeout(saveSuccessTimer);
      saveSuccessTimer = null;
    }
    saveButton.textContent = saveButtonDefaultText;
  }

  function showSaveButtonSavedState() {
    if (!saveButton) {
      return;
    }
    clearSaveButtonSuccessState();
    saveButton.textContent = 'Saved';
    saveSuccessTimer = window.setTimeout(function () {
      clearSaveButtonSuccessState();
    }, 5000);
  }

  function setSaveButtonState(isBusy) {
    saveBusy = !!isBusy;
    if (!saveButton) {
      return;
    }

    if (saveBusy) {
      clearSaveButtonSuccessState();
      saveButton.disabled = true;
      saveButton.textContent = 'Saving...';
      return;
    }

    saveButton.disabled = false;
    if (saveSuccessTimer === null) {
      saveButton.textContent = saveButtonDefaultText;
    }
  }

  function setRunStatus(message, isError) {
    var el = byId('send_run_status');
    if (!el) {
      return;
    }
    el.textContent = message;
    el.classList.toggle('error', !!isError);
  }

  function requestJsonFormPost(form, targetUrl, onSuccess, onError, onComplete) {
    var xhr = new XMLHttpRequest();
    var finished = false;

    function finalize() {
      if (finished) {
        return;
      }
      finished = true;
      if (typeof onComplete === 'function') {
        onComplete();
      }
    }

    xhr.open('POST', targetUrl, true);
    xhr.timeout = 45000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

    var formData = new FormData(form);
    var params = new URLSearchParams();
    formData.forEach(function (value, key) {
      params.append(key, value);
    });
    params.append('ajax', 'save');

    var csrfToken = discoverCsrfToken();
    if (csrfToken !== '') {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken);
      if (!params.has('csrf_token')) {
        params.append('csrf_token', csrfToken);
      }
    }

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }

      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (parseError) {
        try {
          var raw = String(xhr.responseText || '').trim();
          if (raw.charAt(0) === '<') {
            onError(new Error('Save response was wrapped by the web UI or theme. Reload the page and try again.'));
          } else {
            onError(new Error('Invalid save response.'));
          }
        } finally {
          finalize();
        }
        return;
      }

      if (xhr.status < 200 || xhr.status >= 300) {
        try {
          onError(new Error((payload && payload.errors && payload.errors[0]) ? payload.errors[0] : ('HTTP ' + xhr.status)), payload);
        } finally {
          finalize();
        }
        return;
      }

      try {
        onSuccess(payload);
      } finally {
        finalize();
      }
    };

    xhr.onerror = function () {
      try {
        onError(new Error('Network error while saving settings.'));
      } finally {
        finalize();
      }
    };

    xhr.ontimeout = function () {
      try {
        onError(new Error('Save request timed out. Reload the page and verify whether the settings were applied.'));
      } finally {
        finalize();
      }
    };

    xhr.send(params.toString());
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

      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error('HTTP ' + xhr.status));
        return;
      }

      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (parseError) {
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

  function bindRemoveButtons() {
    document.querySelectorAll('.zfsas-send-remove-row').forEach(function (button) {
      button.onclick = function () {
        var row = button.closest('tr');
        if (!row) {
          return;
        }
        var removeInput = row.querySelector('.zfsas-send-remove-flag');
        if (removeInput) {
          removeInput.value = '1';
        }
        row.remove();
      };
    });
  }

  function nextRowIndex() {
    var rows = jobsBody ? jobsBody.querySelectorAll('tr') : [];
    var highest = -1;
    rows.forEach(function (row) {
      var hidden = row.querySelector('input[name^="job_id["]');
      if (!hidden) {
        return;
      }
      var match = hidden.name.match(/job_id\[(\d+)\]/);
      if (match) {
        highest = Math.max(highest, parseInt(match[1], 10));
      }
    });
    return highest + 1;
  }

  var addButton = byId('zfsas_add_send_job');
  if (addButton) {
    addButton.addEventListener('click', function () {
      var sourceEl = byId('new_job_source');
      var destinationEl = byId('new_job_destination');
      var frequencyEl = byId('new_job_frequency');
      var thresholdEl = byId('new_job_threshold');
      var source = sourceEl ? sourceEl.value.trim() : '';
      var destination = destinationEl ? destinationEl.value.trim() : '';
      var frequency = frequencyEl ? frequencyEl.value : '1h';
      var threshold = thresholdEl ? thresholdEl.value.trim() : '100G';

      if (source === '' || destination === '') {
        renderFeedback(['Choose both a source dataset and a destination dataset before adding a job.']);
        return;
      }

      var index = nextRowIndex();
      var sourceOptions = sourceEl ? sourceEl.innerHTML : '';
      var frequencyOptions = frequencyEl ? frequencyEl.innerHTML : '';
      var row = document.createElement('tr');
      row.innerHTML = '' +
        '<td>' +
          '<input type="hidden" name="job_id[' + index + ']" value="">' +
          '<select name="job_source[' + index + ']" class="zfsas-send-select">' + sourceOptions + '</select>' +
        '</td>' +
        '<td><input class="zfsas-send-input" name="job_destination[' + index + ']" value="' + escapeHtml(destination) + '"></td>' +
        '<td><select name="job_frequency[' + index + ']" class="zfsas-send-select">' + frequencyOptions + '</select></td>' +
        '<td><input class="zfsas-send-input" name="job_threshold[' + index + ']" value="' + escapeHtml(threshold) + '"></td>' +
        '<td><input type="hidden" name="job_remove[' + index + ']" value="0" class="zfsas-send-remove-flag"><button type="button" class="btn zfsas-send-remove-row">Remove</button></td>';
      if (jobsBody) {
        jobsBody.appendChild(row);
      }

      var sourceSelect = row.querySelector('select[name^="job_source["]');
      if (sourceSelect) {
        sourceSelect.value = source;
      }
      var frequencySelect = row.querySelector('select[name^="job_frequency["]');
      if (frequencySelect) {
        frequencySelect.value = frequency;
      }

      if (sourceEl) {
        sourceEl.value = '';
      }
      if (destinationEl) {
        destinationEl.value = '';
      }
      if (thresholdEl) {
        thresholdEl.value = '100G';
      }
      renderFeedback([]);
      bindRemoveButtons();
    });
  }

  bindRemoveButtons();

  function startSave(event) {
    if (event) {
      event.preventDefault();
      if (typeof event.stopImmediatePropagation === 'function') {
        event.stopImmediatePropagation();
      }
      if (typeof event.stopPropagation === 'function') {
        event.stopPropagation();
      }
    }

    if (!saveForm || saveBusy) {
      return;
    }

    setSaveButtonState(true);
    renderFeedback([]);

    requestJsonFormPost(
      saveForm,
      saveApiUrl,
      function (data) {
        renderFeedback(data.errors || []);
        if (!Array.isArray(data.errors) || data.errors.length === 0) {
          showSaveButtonSavedState();
        } else {
          clearSaveButtonSuccessState();
        }
      },
      function (error, payload) {
        if (payload && Array.isArray(payload.errors)) {
          renderFeedback(payload.errors);
        } else {
          renderFeedback([error.message]);
        }
        clearSaveButtonSuccessState();
      },
      function () {
        setSaveButtonState(false);
      }
    );
  }

  if (saveButton) {
    saveButton.addEventListener('click', startSave, true);
  }

  if (saveForm) {
    saveForm.addEventListener('submit', startSave, true);
  }

  if (saveButton && saveButton.getAttribute('data-show-saved') === '1') {
    showSaveButtonSavedState();
    saveButton.removeAttribute('data-show-saved');
  }

  if (runButton) {
    runButton.addEventListener('click', function () {
      if (runBusy) {
        return;
      }
      runBusy = true;
      runButton.disabled = true;
      setRunStatus('Starting manual ZFS send run...', false);

      requestJsonPost(
        runApiUrl,
        {},
        function (data) {
          runBusy = false;
          runButton.disabled = false;
          if (!data || data.ok !== true) {
            setRunStatus('Manual ZFS send start failed: Unexpected response.', true);
            return;
          }
          setRunStatus((typeof data.message === 'string' && data.message.length > 0) ? data.message : 'Manual ZFS send started.', false);
        },
        function (error) {
          runBusy = false;
          runButton.disabled = false;
          setRunStatus('Manual ZFS send start failed: ' + error.message, true);
        }
      );
    });
  }
})();
</script>
</body>
</html>
