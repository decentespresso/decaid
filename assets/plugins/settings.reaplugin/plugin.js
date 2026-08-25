/* settings.reaplugin
 *
 * Contract:
 * - This file must define a function named 'createPlugin'
 * - Factory function receives 'host' object as parameter
 * - Returns a plugin object with onLoad, onUnload, onEvent methods
 */

// Standard factory function - receives host object from PluginManager
function createPlugin(host) {
  "use strict";

  let state = {
    refreshInterval: 5,
  };

  function log(msg) {
    host.log(`[settings] ${msg}`);
  }

  /**
   * Fetch Decent application settings
   */
  async function fetchReaSettings() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/settings");
      if (!res.ok) {
        log(`Failed to fetch Decent settings: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching Decent settings: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch available WebUI skins
   */
  async function fetchWebUISkins() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/webui/skins");
      if (!res.ok) {
        log(`Failed to fetch WebUI skins: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching WebUI skins: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch machine settings
   */
  async function fetchDe1Settings() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/machine/settings");
      if (!res.ok) {
        log(`Failed to fetch machine settings: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching machine settings: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch machine calibration settings
   */
  async function fetchCalibrationSettings() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/machine/calibration");
      if (!res.ok) {
        log(`Failed to fetch calibration settings: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching calibration settings: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch presence & wake schedule settings
   */
  async function fetchPresenceSettings() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/presence/settings");
      if (!res.ok) {
        log(`Failed to fetch presence settings: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching presence settings: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch machine advanced settings
   */
  async function fetchDe1AdvancedSettings() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/machine/settings/advanced");
      if (!res.ok) {
        log(`Failed to fetch machine advanced settings: ${res.status}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching machine advanced settings: ${e.message}`);
      return null;
    }
  }

  /**
   * Fetch app info (version, build, commit, branch)
   */
  async function fetchAppInfo() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/info");
      if (!res.ok) { log(`Failed to fetch app info: ${res.status}`); return null; }
      return await res.json();
    } catch (e) { log(`Error fetching app info: ${e.message}`); return null; }
  }

  /**
   * Fetch WebUI server status
   */
  async function fetchWebUIServerStatus() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/webui/server/status");
      if (!res.ok) { log(`Failed to fetch WebUI status: ${res.status}`); return null; }
      return await res.json();
    } catch (e) { log(`Error fetching WebUI status: ${e.message}`); return null; }
  }

  /**
   * Fetch installed plugins
   */
  async function fetchPlugins() {
    try {
      const res = await fetch("http://localhost:8080/api/v1/plugins");
      if (!res.ok) { log(`Failed to fetch plugins: ${res.status}`); return null; }
      return await res.json();
    } catch (e) { log(`Error fetching plugins: ${e.message}`); return null; }
  }

  /**
   * Escape a string for safe inclusion in HTML content.
   */
  function escapeHtml(str) {
    if (str == null) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  /**
   * Generate HTML page with all settings (with editable controls)
   */
  function generateSettingsHTML(reaSettings, de1Settings, de1AdvancedSettings, webUISkins, calibrationSettings, presenceSettings, appInfo, webUIStatus, plugins, backName) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Decent Settings Dashboard - Configure application and DE1 machine settings">
    <title>Decent Settings Dashboard</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #f5f5f5;
            padding: 20px;
            line-height: 1.6;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        h1 {
            color: #333;
            margin-bottom: 10px;
            font-size: 2em;
        }
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        .timestamp {
            color: #666;
            font-size: 0.9em;
        }
        .section {
            background: white;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .section h2 {
            color: #2c3e50;
            margin-bottom: 15px;
            font-size: 1.5em;
            border-bottom: 2px solid #3498db;
            padding-bottom: 10px;
        }
        .settings-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 15px;
        }
        .setting-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px;
            background: #f8f9fa;
            border-radius: 6px;
            border-left: 3px solid #3498db;
        }
        .setting-label {
            font-weight: 600;
            color: #2c3e50;
            flex: 1;
        }
        .setting-control {
            display: flex;
            gap: 8px;
            align-items: center;
        }
        input[type="number"], input[type="text"], select {
            padding: 6px 10px;
            border: 2px solid #999;
            border-radius: 4px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            width: 120px;
        }
        input[type="number"]:focus, input[type="text"]:focus, select:focus {
            outline: 3px solid #3498db;
            outline-offset: 2px;
            border-color: #3498db;
        }
        select {
            width: 140px;
            cursor: pointer;
        }
        .btn {
            padding: 6px 12px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: background 0.2s, transform 0.1s;
        }
        .btn:focus {
            outline: 3px solid #2c3e50;
            outline-offset: 2px;
        }
        .btn:active {
            transform: translateY(1px);
        }
        .btn-primary {
            background: #2980b9;
            color: white;
        }
        .btn-primary:hover, .btn-primary:focus {
            background: #1f5f8b;
        }
        .btn-refresh {
            background: #27ae60;
            color: white;
        }
        .btn-refresh:hover, .btn-refresh:focus {
            background: #1e8449;
        }
        .skip-link {
            position: absolute;
            top: -40px;
            left: 0;
            background: #2c3e50;
            color: white;
            padding: 8px 16px;
            text-decoration: none;
            border-radius: 0 0 4px 0;
            z-index: 100;
        }
        .skip-link:focus {
            top: 0;
        }
        .error {
            background: #fee;
            border-left-color: #e74c3c;
            color: #c0392b;
            padding: 12px;
            border-radius: 6px;
        }
        .success-toast {
            position: fixed;
            top: 60px;
            right: 20px;
            background: #2ecc71;
            color: white;
            padding: 15px 20px;
            border-radius: 6px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
            animation: slideIn 0.3s ease-out;
            z-index: 1000;
        }
        .error-toast {
            position: fixed;
            top: 60px;
            right: 20px;
            background: #e74c3c;
            color: white;
            padding: 15px 20px;
            border-radius: 6px;
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
            animation: slideIn 0.3s ease-out;
            z-index: 1000;
        }
        @keyframes slideIn {
            from { transform: translateX(400px); opacity: 0; }
            to { transform: translateX(0); opacity: 1; }
        }
        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-right: 8px;
        }
        .status-ok {
            background: #2ecc71;
        }
        .status-error {
            background: #e74c3c;
        }
        .readonly {
            color: #555;
            font-family: 'Courier New', monospace;
        }
        .visually-hidden {
            position: absolute;
            left: -10000px;
            width: 1px;
            height: 1px;
            overflow: hidden;
        }
    </style>
</head>
<body>
    <nav style="position: sticky; top: 0; z-index: 100; background: #f5f5f5; padding: 12px 20px; border-bottom: 1px solid #ddd; display: flex; justify-content: space-between; align-items: center;">
      <h1 style="margin: 0; font-size: 1.2em; color: #333;">Decent Settings</h1>
      <a id="back-link" href="#" onclick="window.location.href='http://'+window.location.hostname+':3000/?_='+Date.now(); return false;" style="color: #2980b9; text-decoration: none; padding: 8px 16px; border: 1px solid #2980b9; border-radius: 6px;">&#8592; Back to ${escapeHtml(backName || 'WebUI')}</a>
    </nav>
    <a href="#main-content" class="skip-link">Skip to main content</a>
    <div class="container">
        <header class="header">
            <h1 id="page-title">Decent Settings</h1>
            <button class="btn btn-refresh" onclick="location.reload()" aria-label="Refresh all settings from server">
                Refresh
            </button>
        </header>
        <div class="timestamp" role="status" aria-live="polite" aria-atomic="true">
            <span class="status-indicator ${reaSettings && de1Settings ? 'status-ok' : 'status-error'}" 
                  role="img" 
                  aria-label="${reaSettings && de1Settings ? 'Settings loaded successfully' : 'Error loading settings'}"></span>
            Last updated: <span id="timestamp">${new Date().toLocaleString()}</span>
        </div>

        <main id="main-content">
            <!-- Decent Application Settings -->
            <section class="section" aria-labelledby="decent-settings-heading">
                <h2 id="decent-settings-heading">Decent Application Settings</h2>
            ${reaSettings ? `
                <div class="settings-grid" role="group" aria-label="Decent application settings controls">
                    <div class="setting-item">
                        <label class="setting-label" for="gatewayMode">Gateway Mode</label>
                        <div class="setting-control">
                            <select id="gatewayMode" aria-describedby="gatewayMode-desc">
                                <option value="disabled" ${reaSettings.gatewayMode === 'disabled' ? 'selected' : ''}>Disabled</option>
                                <option value="tracking" ${reaSettings.gatewayMode === 'tracking' ? 'selected' : ''}>Tracking</option>
                                <option value="full" ${reaSettings.gatewayMode === 'full' ? 'selected' : ''}>Full</option>
                            </select>
                            <span id="gatewayMode-desc" class="visually-hidden">Controls how the gateway monitors and controls the espresso machine</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('gatewayMode', document.getElementById('gatewayMode').value)" aria-label="Save gateway mode setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="automaticUpdateCheck">Automatic Update Checks</label>
                        <div class="setting-control">
                            <select id="automaticUpdateCheck" aria-describedby="automaticUpdateCheck-desc">
                                <option value="true" ${reaSettings.automaticUpdateCheck !== false ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${reaSettings.automaticUpdateCheck === false ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="automaticUpdateCheck-desc" class="visually-hidden">Check for app updates every 12 hours automatically</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('automaticUpdateCheck', document.getElementById('automaticUpdateCheck').value === 'true')" aria-label="Save automatic update check setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="logLevel">Log Level</label>
                        <div class="setting-control">
                            <select id="logLevel" aria-describedby="logLevel-desc">
                                <option value="ALL" ${reaSettings.logLevel === 'ALL' ? 'selected' : ''}>ALL</option>
                                <option value="FINEST" ${reaSettings.logLevel === 'FINEST' ? 'selected' : ''}>FINEST</option>
                                <option value="FINER" ${reaSettings.logLevel === 'FINER' ? 'selected' : ''}>FINER</option>
                                <option value="FINE" ${reaSettings.logLevel === 'FINE' ? 'selected' : ''}>FINE</option>
                                <option value="CONFIG" ${reaSettings.logLevel === 'CONFIG' ? 'selected' : ''}>CONFIG</option>
                                <option value="INFO" ${reaSettings.logLevel === 'INFO' ? 'selected' : ''}>INFO</option>
                                <option value="WARNING" ${reaSettings.logLevel === 'WARNING' ? 'selected' : ''}>WARNING</option>
                                <option value="SEVERE" ${reaSettings.logLevel === 'SEVERE' ? 'selected' : ''}>SEVERE</option>
                                <option value="SHOUT" ${reaSettings.logLevel === 'SHOUT' ? 'selected' : ''}>SHOUT</option>
                                <option value="OFF" ${reaSettings.logLevel === 'OFF' ? 'selected' : ''}>OFF</option>
                            </select>
                            <span id="logLevel-desc" class="visually-hidden">Sets the verbosity of application logging output</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('logLevel', document.getElementById('logLevel').value)" aria-label="Save log level setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Web UI Path</span>
                        <span class="readonly" aria-label="Web UI path is read-only">${escapeHtml(reaSettings.webUiPath) || 'N/A'}</span>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="weightFlowMultiplier">Weight Flow Multiplier</label>
                        <div class="setting-control">
                            <input type="number" id="weightFlowMultiplier" value="${reaSettings.weightFlowMultiplier !== undefined ? reaSettings.weightFlowMultiplier : 1.0}" step="0.1" min="0" max="5" aria-describedby="weightFlowMultiplier-desc">
                            <span id="weightFlowMultiplier-desc" class="visually-hidden">Multiplier for projected weight calculation. Higher values stop shots earlier.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('weightFlowMultiplier', parseFloat(document.getElementById('weightFlowMultiplier').value))" aria-label="Save weight flow multiplier setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="volumeFlowMultiplier">Volume Flow Multiplier (s)</label>
                        <div class="setting-control">
                            <input type="number" id="volumeFlowMultiplier" value="${reaSettings.volumeFlowMultiplier !== undefined ? reaSettings.volumeFlowMultiplier : 0.3}" step="0.05" min="0" max="2" aria-describedby="volumeFlowMultiplier-desc">
                            <span id="volumeFlowMultiplier-desc" class="visually-hidden">Look-ahead time in seconds for projected volume calculation. Accounts for system lag.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('volumeFlowMultiplier', parseFloat(document.getElementById('volumeFlowMultiplier').value))" aria-label="Save volume flow multiplier setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="scalePowerMode">Scale Power Management</label>
                        <div class="setting-control">
                            <select id="scalePowerMode" aria-describedby="scalePowerMode-desc">
                                <option value="disabled" ${reaSettings.scalePowerMode === 'disabled' ? 'selected' : ''}>Disabled</option>
                                <option value="displayOff" ${reaSettings.scalePowerMode === 'displayOff' ? 'selected' : ''}>Display Off</option>
                                <option value="disconnect" ${reaSettings.scalePowerMode === 'disconnect' ? 'selected' : ''}>Disconnect</option>
                            </select>
                            <span id="scalePowerMode-desc" class="visually-hidden">Controls automatic scale power management when machine sleeps. Display Off: turn off scale display. Disconnect: disconnect scale completely.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('scalePowerMode', document.getElementById('scalePowerMode').value)" aria-label="Save scale power mode setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="blockOnNoScale">Block Shots Without Scale</label>
                        <div class="setting-control">
                            <select id="blockOnNoScale" aria-describedby="blockOnNoScale-desc">
                                <option value="true" ${reaSettings.blockOnNoScale ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.blockOnNoScale ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="blockOnNoScale-desc" class="visually-hidden">When enabled, espresso shots are blocked (and aborted if started via the machine) when no scale is connected.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('blockOnNoScale', document.getElementById('blockOnNoScale').value === 'true')" aria-label="Save block on no scale setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="blockTareDuringShot">Block Tare During Shot</label>
                        <div class="setting-control">
                            <select id="blockTareDuringShot" aria-describedby="blockTareDuringShot-desc">
                                <option value="true" ${reaSettings.blockTareDuringShot ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.blockTareDuringShot ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="blockTareDuringShot-desc" class="visually-hidden">When enabled, a tare request is rejected while an app-tracked espresso shot is actively brewing, preventing a stray programmatic tare from ruining stop-at-weight mid-pour. Does not affect a manual tare via the scale's physical button. Full gateway mode is an explicit exemption — the skin owns the shot there, so this never applies in that mode, regardless of any app-tracked shot state.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('blockTareDuringShot', document.getElementById('blockTareDuringShot').value === 'true')" aria-label="Save block tare during shot setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="stopHotWaterAtWeight">Stop Hot Water at Weight</label>
                        <div class="setting-control">
                            <select id="stopHotWaterAtWeight" aria-describedby="stopHotWaterAtWeight-desc">
                                <option value="true" ${reaSettings.stopHotWaterAtWeight ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.stopHotWaterAtWeight ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="stopHotWaterAtWeight-desc" class="visually-hidden">When enabled and a scale is connected, hot water dispensing tares the scale and stops at the configured hot-water volume target (treated as grams). Ignored in full gateway mode.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('stopHotWaterAtWeight', document.getElementById('stopHotWaterAtWeight').value === 'true')" aria-label="Save stop hot water at weight setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="hotWaterFlowMultiplier">Hot Water Flow Multiplier (s)</label>
                        <div class="setting-control">
                            <input type="number" id="hotWaterFlowMultiplier" value="${reaSettings.hotWaterFlowMultiplier !== undefined ? reaSettings.hotWaterFlowMultiplier : 0.3}" step="0.05" min="0" max="2" aria-describedby="hotWaterFlowMultiplier-desc">
                            <span id="hotWaterFlowMultiplier-desc" class="visually-hidden">Look-ahead time in seconds for projected weight calculation when stopping hot water at weight. Separate from the espresso weight flow multiplier because hot water dispenses with a different pump/flow profile.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('hotWaterFlowMultiplier', parseFloat(document.getElementById('hotWaterFlowMultiplier').value))" aria-label="Save hot water flow multiplier setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="preferredMachineId">Auto-Connect Device ID</label>
                        <div class="setting-control">
                            <input type="text" id="preferredMachineId" value="${escapeHtml(reaSettings.preferredMachineId)}" placeholder="None set" aria-describedby="preferredMachineId-desc" style="width: 200px;">
                            <span id="preferredMachineId-desc" class="visually-hidden">Device ID for automatic connection on startup. Leave empty to disable auto-connect.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('preferredMachineId', document.getElementById('preferredMachineId').value || null)" aria-label="Save preferred machine ID setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="preferredScaleId">Auto-Connect Scale ID</label>
                        <div class="setting-control">
                            <input type="text" id="preferredScaleId" value="${escapeHtml(reaSettings.preferredScaleId)}" placeholder="None set" aria-describedby="preferredScaleId-desc" style="width: 200px;">
                            <span id="preferredScaleId-desc" class="visually-hidden">Scale ID for automatic connection on startup. Leave empty to disable auto-connect for scales.</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('preferredScaleId', document.getElementById('preferredScaleId').value || null)" aria-label="Save preferred scale ID setting">Save</button>
                        </div>
                    </div>
                </div>
            ` : '<div class="error" role="alert" aria-live="assertive">Failed to load Decent settings</div>'}
            </section>

            <!-- Battery & Charging -->
            <section class="section" aria-labelledby="charging-settings-heading">
                <h2 id="charging-settings-heading">Battery & Charging</h2>
                ${reaSettings ? `
                <div class="settings-grid" role="group" aria-label="Battery and charging settings">
                    <div class="setting-item">
                        <label class="setting-label" for="chargingMode">Charging Mode</label>
                        <div class="setting-control">
                            <select id="chargingMode">
                                <option value="disabled" ${reaSettings.chargingMode === 'disabled' ? 'selected' : ''}>Disabled</option>
                                <option value="longevity" ${reaSettings.chargingMode === 'longevity' ? 'selected' : ''}>Longevity (45-55%)</option>
                                <option value="balanced" ${reaSettings.chargingMode === 'balanced' ? 'selected' : ''}>Balanced (40-80%)</option>
                                <option value="highAvailability" ${reaSettings.chargingMode === 'highAvailability' ? 'selected' : ''}>High Availability (80-95%)</option>
                            </select>
                            <button class="btn btn-primary" onclick="updateReaSetting('chargingMode', document.getElementById('chargingMode').value)" aria-label="Save charging mode">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="nightModeEnabled">Night Mode</label>
                        <div class="setting-control">
                            <select id="nightModeEnabled">
                                <option value="true" ${reaSettings.nightModeEnabled ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.nightModeEnabled ? 'selected' : ''}>Disabled</option>
                            </select>
                            <button class="btn btn-primary" onclick="updateReaSetting('nightModeEnabled', document.getElementById('nightModeEnabled').value === 'true')" aria-label="Save night mode setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="nightModeSleepTime">Sleep Time</label>
                        <div class="setting-control">
                            <input type="time" id="nightModeSleepTime" value="${String(Math.floor((reaSettings.nightModeSleepTime || 1320) / 60)).padStart(2, '0')}:${String((reaSettings.nightModeSleepTime || 1320) % 60).padStart(2, '0')}" aria-describedby="nightModeSleepTime-desc">
                            <span id="nightModeSleepTime-desc" class="visually-hidden">Time when the tablet goes to sleep (used for night mode charging schedule)</span>
                            <button class="btn btn-primary" onclick="(function(){ const t = document.getElementById('nightModeSleepTime').value.split(':'); updateReaSetting('nightModeSleepTime', parseInt(t[0]) * 60 + parseInt(t[1])); })()" aria-label="Save sleep time">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="nightModeMorningTime">Morning Time</label>
                        <div class="setting-control">
                            <input type="time" id="nightModeMorningTime" value="${String(Math.floor((reaSettings.nightModeMorningTime || 420) / 60)).padStart(2, '0')}:${String((reaSettings.nightModeMorningTime || 420) % 60).padStart(2, '0')}" aria-describedby="nightModeMorningTime-desc">
                            <span id="nightModeMorningTime-desc" class="visually-hidden">Time when the tablet wakes up (used for night mode charging schedule)</span>
                            <button class="btn btn-primary" onclick="(function(){ const t = document.getElementById('nightModeMorningTime').value.split(':'); updateReaSetting('nightModeMorningTime', parseInt(t[0]) * 60 + parseInt(t[1])); })()" aria-label="Save morning time">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="lowBatteryBrightnessLimit">Low Battery Brightness Limit</label>
                        <div class="setting-control">
                            <select id="lowBatteryBrightnessLimit">
                                <option value="true" ${reaSettings.lowBatteryBrightnessLimit ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.lowBatteryBrightnessLimit ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="lowBatteryBrightnessLimit-desc" class="visually-hidden">When enabled, limits screen brightness to 20% when battery is below 30%</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('lowBatteryBrightnessLimit', document.getElementById('lowBatteryBrightnessLimit').value === 'true')" aria-label="Save low battery brightness limit setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="keepAwake">Keep Screen Awake</label>
                        <div class="setting-control">
                            <select id="keepAwake">
                                <option value="true" ${reaSettings.keepAwake ? 'selected' : ''}>Enabled</option>
                                <option value="false" ${!reaSettings.keepAwake ? 'selected' : ''}>Disabled</option>
                            </select>
                            <span id="keepAwake-desc" class="visually-hidden">When enabled, prevents the tablet screen from turning off while the app is running</span>
                            <button class="btn btn-primary" onclick="updateReaSetting('keepAwake', document.getElementById('keepAwake').value === 'true')" aria-label="Save keep screen awake setting">Save</button>
                        </div>
                    </div>
                    ${reaSettings.chargingState ? `
                    <div class="setting-item">
                        <span class="setting-label">Battery Level</span>
                        <span class="readonly">${reaSettings.chargingState.batteryPercent}%</span>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Current Phase</span>
                        <span class="readonly">${escapeHtml(reaSettings.chargingState.currentPhase)}</span>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">USB Charger</span>
                        <span class="readonly">${reaSettings.chargingState.usbChargerOn ? 'On' : 'Off'}</span>
                    </div>
                    ${reaSettings.chargingState.isEmergency ? '<div class="setting-item error"><span class="setting-label">Emergency charging active (battery critically low)</span></div>' : ''}
                    ` : '<div class="setting-item"><span class="setting-label">Charging state not available</span><span class="readonly">Requires Android/iOS</span></div>'}
                </div>
                ` : '<div class="error" role="alert">Failed to load settings</div>'}
            </section>

            <!-- Machine Settings -->
            <section class="section" aria-labelledby="machine-settings-heading">
                <h2 id="machine-settings-heading">Machine Settings</h2>
            ${de1Settings ? `
                <div class="settings-grid" role="group" aria-label="Machine settings controls">
                    <div class="setting-item">
                        <label class="setting-label" for="fan">Fan Threshold (°C)</label>
                        <div class="setting-control">
                            <input type="number" id="fan" value="${de1Settings.fan !== undefined ? de1Settings.fan : ''}" step="1" min="0" max="100" aria-label="Fan threshold temperature in degrees Celsius">
                            <button class="btn btn-primary" onclick="updateDe1Setting('fan', parseInt(document.getElementById('fan').value))" aria-label="Save fan threshold setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="usb">USB Charger Mode</label>
                        <div class="setting-control">
                            <select id="usb" aria-label="USB charger mode enabled or disabled">
                                <option value="enable" ${de1Settings.usb ? 'selected' : ''}>Enabled</option>
                                <option value="disable" ${!de1Settings.usb ? 'selected' : ''}>Disabled</option>
                            </select>
                            <button class="btn btn-primary" onclick="updateDe1Setting('usb', document.getElementById('usb').value)" aria-label="Save USB charger mode setting">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Flush Temperature (°C)</span>
                        <div class="setting-control">
                            <input type="number" id="flushTemp" value="${de1Settings.flushTemp !== undefined ? de1Settings.flushTemp : ''}" step="0.1" min="0" max="100">
                            <button class="btn btn-primary" onclick="updateDe1Setting('flushTemp', parseFloat(document.getElementById('flushTemp').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Flush Timeout (s)</span>
                        <div class="setting-control">
                            <input type="number" id="flushTimeout" value="${de1Settings.flushTimeout !== undefined ? de1Settings.flushTimeout : ''}" step="0.1" min="0" max="300">
                            <button class="btn btn-primary" onclick="updateDe1Setting('flushTimeout', parseFloat(document.getElementById('flushTimeout').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Flush Flow (ml/s)</span>
                        <div class="setting-control">
                            <input type="number" id="flushFlow" value="${de1Settings.flushFlow !== undefined ? de1Settings.flushFlow : ''}" step="0.1" min="0" max="10">
                            <button class="btn btn-primary" onclick="updateDe1Setting('flushFlow', parseFloat(document.getElementById('flushFlow').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Hot Water Flow (ml/s)</span>
                        <div class="setting-control">
                            <input type="number" id="hotWaterFlow" value="${de1Settings.hotWaterFlow !== undefined ? de1Settings.hotWaterFlow : ''}" step="0.1" min="0" max="10">
                            <button class="btn btn-primary" onclick="updateDe1Setting('hotWaterFlow', parseFloat(document.getElementById('hotWaterFlow').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Steam Flow (ml/s)</span>
                        <div class="setting-control">
                            <input type="number" id="steamFlow" value="${de1Settings.steamFlow !== undefined ? de1Settings.steamFlow : ''}" step="0.1" min="0" max="10">
                            <button class="btn btn-primary" onclick="updateDe1Setting('steamFlow', parseFloat(document.getElementById('steamFlow').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Tank Temperature (°C)</span>
                        <div class="setting-control">
                            <input type="number" id="tankTemp" value="${de1Settings.tankTemp !== undefined ? de1Settings.tankTemp : ''}" step="1" min="0" max="100">
                            <button class="btn btn-primary" onclick="updateDe1Setting('tankTemp', parseInt(document.getElementById('tankTemp').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="steamPurgeMode">Steam Purge Mode</label>
                        <div class="setting-control">
                            <select id="steamPurgeMode" aria-label="Steam purge mode - normal or two tap stop">
                                <option value="0" ${de1Settings.steamPurgeMode === 0 ? 'selected' : ''}>Normal</option>
                                <option value="1" ${de1Settings.steamPurgeMode === 1 ? 'selected' : ''}>Two Tap Stop</option>
                            </select>
                            <button class="btn btn-primary" onclick="updateDe1Setting('steamPurgeMode', parseInt(document.getElementById('steamPurgeMode').value))" aria-label="Save steam purge mode setting">Save</button>
                        </div>
                    </div>
                </div>
            ` : '<div class="error" role="alert">Failed to load machine settings (machine may not be connected)</div>'}
            </section>

            <!-- Machine Advanced Settings -->
            <section class="section" aria-labelledby="machine-advanced-settings-heading">
                <h2 id="machine-advanced-settings-heading">Machine Advanced Settings</h2>
            ${de1AdvancedSettings ? `
                <div class="settings-grid">
                    <div class="setting-item">
                        <span class="setting-label">Heater Phase 1 Flow (ml/s)</span>
                        <div class="setting-control">
                            <input type="number" id="heaterPh1Flow" value="${de1AdvancedSettings.heaterPh1Flow !== undefined ? de1AdvancedSettings.heaterPh1Flow : ''}" step="0.1" min="0" max="10">
                            <button class="btn btn-primary" onclick="updateDe1AdvancedSetting('heaterPh1Flow', parseFloat(document.getElementById('heaterPh1Flow').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Heater Phase 2 Flow (ml/s)</span>
                        <div class="setting-control">
                            <input type="number" id="heaterPh2Flow" value="${de1AdvancedSettings.heaterPh2Flow !== undefined ? de1AdvancedSettings.heaterPh2Flow : ''}" step="0.1" min="0" max="10">
                            <button class="btn btn-primary" onclick="updateDe1AdvancedSetting('heaterPh2Flow', parseFloat(document.getElementById('heaterPh2Flow').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Heater Idle Temperature (°C)</span>
                        <div class="setting-control">
                            <input type="number" id="heaterIdleTemp" value="${de1AdvancedSettings.heaterIdleTemp !== undefined ? de1AdvancedSettings.heaterIdleTemp : ''}" step="0.1" min="0" max="100">
                            <button class="btn btn-primary" onclick="updateDe1AdvancedSetting('heaterIdleTemp', parseFloat(document.getElementById('heaterIdleTemp').value))">Save</button>
                        </div>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Heater Phase 2 Timeout (s)</span>
                        <div class="setting-control">
                            <input type="number" id="heaterPh2Timeout" value="${de1AdvancedSettings.heaterPh2Timeout !== undefined ? de1AdvancedSettings.heaterPh2Timeout : ''}" step="0.1" min="0" max="300">
                            <button class="btn btn-primary" onclick="updateDe1AdvancedSetting('heaterPh2Timeout', parseFloat(document.getElementById('heaterPh2Timeout').value))">Save</button>
                        </div>
                    </div>
                </div>
            ` : '<div class="error" role="alert">Failed to load machine advanced settings (machine may not be connected)</div>'}
            </section>

            <!-- Machine Calibration -->
            <section class="section" aria-labelledby="machine-calibration-heading">
                <h2 id="machine-calibration-heading">Calibration</h2>
            ${calibrationSettings ? `
                <div class="settings-grid">
                    <div class="setting-item">
                        <label class="setting-label" for="flowMultiplier">Flow Estimation Multiplier</label>
                        <div class="setting-control">
                            <input type="number" id="flowMultiplier" value="${calibrationSettings.flowMultiplier !== undefined ? calibrationSettings.flowMultiplier : 1.0}" step="0.01" min="0.13" max="2.0" aria-describedby="flowMultiplier-desc">
                            <span id="flowMultiplier-desc" class="visually-hidden">Adjusts the DE1 flow sensor calibration. Valid range: 0.13 to 2.0. Default is 1.0.</span>
                            <button class="btn btn-primary" onclick="updateCalibrationSetting('flowMultiplier', parseFloat(document.getElementById('flowMultiplier').value))" aria-label="Save flow estimation multiplier">Save</button>
                        </div>
                    </div>
                </div>
            ` : '<div class="error" role="alert">Failed to load calibration settings (machine may not be connected)</div>'}
            </section>

            <!-- Presence & Sleep -->
            <section class="section" aria-labelledby="presence-settings-heading">
                <h2 id="presence-settings-heading">Presence & Sleep</h2>
            ${presenceSettings ? `
                <div class="settings-grid" role="group" aria-label="Presence and sleep settings">
                    <div class="setting-item">
                        <span class="setting-label">User Presence</span>
                        <span class="readonly">${presenceSettings.userPresenceEnabled ? 'Enabled' : 'Disabled'}</span>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Sleep Timeout</span>
                        <span class="readonly">${presenceSettings.sleepTimeoutMinutes ? presenceSettings.sleepTimeoutMinutes + ' minutes' : 'Disabled'}</span>
                    </div>
                </div>
                ${presenceSettings.schedules && presenceSettings.schedules.length > 0 ? `
                <h3 style="margin-top: 15px; margin-bottom: 10px; color: #2c3e50;">Wake Schedules</h3>
                <table style="width: 100%; border-collapse: collapse; background: #f8f9fa; border-radius: 6px; overflow: hidden;">
                    <thead>
                        <tr style="background: #3498db; color: white;">
                            <th style="padding: 10px; text-align: left;">Time</th>
                            <th style="padding: 10px; text-align: left;">Days</th>
                            <th style="padding: 10px; text-align: left;">Enabled</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${presenceSettings.schedules.map(schedule => {
                            const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                            const days = !schedule.daysOfWeek || schedule.daysOfWeek.length === 0
                                ? 'Every day'
                                : schedule.daysOfWeek.map(d => dayNames[d - 1] || '?').join(', ');
                            return `<tr style="border-bottom: 1px solid #ddd;">
                            <td style="padding: 10px;">${escapeHtml(schedule.time)}</td>
                            <td style="padding: 10px;">${escapeHtml(days)}</td>
                            <td style="padding: 10px;">${schedule.enabled ? 'Yes' : 'No'}</td>
                        </tr>`;
                        }).join('')}
                    </tbody>
                </table>
                ` : '<p style="margin-top: 10px; color: #666;">No wake schedules configured.</p>'}
            ` : '<div class="error" role="alert">Failed to load presence settings</div>'}
            </section>

            <!-- Simulated Devices -->
            <section class="section" aria-labelledby="simulated-devices-heading">
                <h2 id="simulated-devices-heading">Simulated Devices</h2>
                ${reaSettings ? `
                <p style="color: #666; margin-bottom: 15px;">Enable simulated devices for testing without real hardware. Changes take effect after restarting the app.</p>
                <div class="settings-grid" role="group" aria-label="Simulated device toggles">
                    <div class="setting-item">
                        <label class="setting-label" for="sim-machine">Simulated Machine</label>
                        <div class="setting-control">
                            <input type="checkbox" id="sim-machine" ${(reaSettings.simulatedDevices || []).includes('machine') ? 'checked' : ''} onchange="toggleSimulatedDevice('machine', this.checked)" style="width: 20px; height: 20px; cursor: pointer;">
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="sim-scale">Simulated Scale</label>
                        <div class="setting-control">
                            <input type="checkbox" id="sim-scale" ${(reaSettings.simulatedDevices || []).includes('scale') ? 'checked' : ''} onchange="toggleSimulatedDevice('scale', this.checked)" style="width: 20px; height: 20px; cursor: pointer;">
                        </div>
                    </div>
                    <div class="setting-item">
                        <label class="setting-label" for="sim-sensor">Simulated Sensor</label>
                        <div class="setting-control">
                            <input type="checkbox" id="sim-sensor" ${(reaSettings.simulatedDevices || []).includes('sensor') ? 'checked' : ''} onchange="toggleSimulatedDevice('sensor', this.checked)" style="width: 20px; height: 20px; cursor: pointer;">
                        </div>
                    </div>
                </div>
                ` : '<div class="error" role="alert">Failed to load settings</div>'}
            </section>

            <!-- Web Interface -->
            <section class="section" aria-labelledby="webui-heading">
                <h2 id="webui-heading">Web Interface</h2>
                ${webUISkins ? `
                <div class="settings-grid" role="group" aria-label="Active skin and server status">
                    <div class="setting-item">
                        <label class="setting-label" for="activeSkin">Active Skin</label>
                        <div class="setting-control">
                            <select id="activeSkin" style="width: 200px;">
                                ${webUISkins.map(skin =>
                                    `<option value="${escapeHtml(skin.id)}" ${reaSettings && reaSettings.defaultSkinId === skin.id ? 'selected' : ''}>${escapeHtml(skin.name || skin.id)}${skin.version ? ' v' + escapeHtml(skin.version) : ''}</option>`
                                ).join('')}
                            </select>
                            <button class="btn btn-primary" onclick="switchSkin()">Apply</button>
                        </div>
                    </div>
                    ${webUIStatus ? `
                    <div class="setting-item">
                        <span class="setting-label">Server</span>
                        <span class="readonly">
                            <span class="status-indicator ${webUIStatus.serving ? 'status-ok' : 'status-error'}"></span>
                            ${webUIStatus.serving ? 'Serving' : 'Stopped'}
                            ${webUIStatus.serving ? ` at ${escapeHtml(webUIStatus.ip)}:${escapeHtml(webUIStatus.port)}` : ''}
                        </span>
                    </div>
                    <div class="setting-item">
                        <span class="setting-label">Controls</span>
                        <div class="setting-control">
                            ${webUIStatus.serving
                              ? `<button class="btn btn-primary" onclick="window.open('http://'+window.location.hostname+':3000/?_='+Date.now(),'_blank')" style="margin-right: 4px;">Open in Browser</button>
                                 <button class="btn" style="background: #e74c3c; color: white;" onclick="stopWebUI()">Stop Server</button>`
                              : '<button class="btn btn-primary" onclick="startWebUI()">Start Server</button>'}
                        </div>
                    </div>
                    ` : '<div class="setting-item"><span class="setting-label">Server</span><span class="readonly" style="color: #e74c3c;">Failed to load server status</span></div>'}
                </div>

                <h3 style="margin-top: 20px; margin-bottom: 10px; color: #2c3e50;">Installed Skins</h3>
                <table style="width: 100%; border-collapse: collapse; background: #f8f9fa; border-radius: 6px; overflow: hidden; margin-bottom: 20px;">
                    <thead>
                        <tr style="background: #3498db; color: white;">
                            <th style="padding: 10px; text-align: left;">Name</th>
                            <th style="padding: 10px; text-align: left;">Version</th>
                            <th style="padding: 10px; text-align: left;">Type</th>
                            <th style="padding: 10px; text-align: left;">Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${webUISkins.map(skin => `<tr style="border-bottom: 1px solid #ddd; ${reaSettings && reaSettings.defaultSkinId === skin.id ? 'background: #d5f5e3;' : ''}">
                            <td style="padding: 10px;">${escapeHtml(skin.name || skin.id)}${reaSettings && reaSettings.defaultSkinId === skin.id ? ' <strong>(active)</strong>' : ''}</td>
                            <td style="padding: 10px;">${escapeHtml(skin.version) || 'N/A'}</td>
                            <td style="padding: 10px;">${skin.isBundled ? 'Bundled' : 'Installed'}</td>
                            <td style="padding: 10px;">
                                ${!skin.isBundled ? `<button class="btn" style="background: #e74c3c; color: white;" onclick="removeSkin(${escapeHtml(JSON.stringify(skin.id))}, ${escapeHtml(JSON.stringify(skin.name || skin.id))})">Remove</button>` : ''}
                            </td>
                        </tr>`).join('')}
                    </tbody>
                </table>

                <div style="margin-bottom: 20px;">
                    <button class="btn btn-primary" onclick="checkSkinUpdates()">Check for Skin Updates</button>
                </div>

                <h3 style="margin-bottom: 10px; color: #2c3e50;">Install Skin</h3>
                <div class="setting-item" style="flex-wrap: wrap; gap: 10px;">
                    <label class="setting-label" for="skinSource" style="flex-basis: 100%;">GitHub repo (owner/repo) or ZIP URL</label>
                    <div class="setting-control" style="flex: 1;">
                        <input type="text" id="skinSource" placeholder="owner/repo or https://..." style="width: 100%; min-width: 250px;">
                        <button class="btn btn-primary" onclick="installSkin()">Install</button>
                    </div>
                </div>
                ` : '<div class="error" role="alert">Failed to load web interface data</div>'}
            </section>

            <!-- Data Management -->
            <section class="section" aria-labelledby="data-management-heading">
                <h2 id="data-management-heading">Data Management</h2>

                <h3 style="margin-bottom: 10px; color: #2c3e50;">Export</h3>
                <div class="setting-item" style="margin-bottom: 20px;">
                    <span class="setting-label">Download a full data export (ZIP)</span>
                    <div class="setting-control">
                        <a href="/api/v1/data/export" target="_blank" class="btn btn-primary" style="text-decoration: none;">Export Data</a>
                    </div>
                </div>

                <h3 style="margin-bottom: 10px; color: #2c3e50;">Import</h3>
                <div class="setting-item" style="margin-bottom: 20px; flex-wrap: wrap; gap: 10px;">
                    <label class="setting-label" for="importFile" style="flex-basis: 100%;">Upload a previously exported ZIP file</label>
                    <div class="setting-control">
                        <input type="file" id="importFile" accept=".zip" style="width: auto;">
                        <button class="btn btn-primary" onclick="importData()">Import</button>
                    </div>
                </div>

                <h3 style="margin-bottom: 10px; color: #2c3e50;">Sync</h3>
                <div style="background: #f8f9fa; border-radius: 6px; padding: 15px; border-left: 3px solid #3498db;">
                    <div class="settings-grid" style="margin-bottom: 10px;">
                        <div class="setting-item">
                            <label class="setting-label" for="syncTarget">Target URL</label>
                            <div class="setting-control">
                                <input type="text" id="syncTarget" placeholder="http://192.168.1.50:8080" style="width: 200px;">
                                <div style="font-size: 12px; color: #888; margin-top: 4px;">Host and optional port only, no path, query, or fragment.</div>
                            </div>
                        </div>
                        <div class="setting-item">
                            <label class="setting-label" for="syncMode">Direction</label>
                            <div class="setting-control">
                                <select id="syncMode" onchange="updateSyncContinueVisibility()">
                                    <option value="push">Push (local to remote)</option>
                                    <option value="pull">Pull (remote to local)</option>
                                    <option value="two_way">Two-way</option>
                                </select>
                            </div>
                        </div>
                        <div class="setting-item">
                            <label class="setting-label" for="syncConflict">On Conflict</label>
                            <div class="setting-control">
                                <select id="syncConflict">
                                    <option value="skip">Skip</option>
                                    <option value="overwrite">Overwrite</option>
                                </select>
                            </div>
                        </div>
                        <label id="syncContinueOption" style="display: none; align-items: center; gap: 4px;">
                            <input type="checkbox" id="syncContinue">
                            Continue with push if pull is incomplete
                        </label>
                    </div>
                    <div style="margin-bottom: 10px;">
                        <span class="setting-label" style="display: block; margin-bottom: 8px;">Sections to sync:</span>
                        <div style="display: flex; flex-wrap: wrap; gap: 12px;">
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="profiles" checked> Profiles</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="shots" checked> Shots</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="workflow" checked> Workflow</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="settings" checked> Settings</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="store" checked> KV Store</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="steams" checked> Steams</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="beans" checked> Beans</label>
                            <label style="display: flex; align-items: center; gap: 4px;"><input type="checkbox" class="sync-section" value="grinders" checked> Grinders</label>
                        </div>
                    </div>
                    <button class="btn btn-primary" onclick="syncData()">Sync</button>
                </div>
            </section>

            <!-- Plugin Management -->
            <section class="section" aria-labelledby="plugin-management-heading">
                <h2 id="plugin-management-heading">Plugin Management</h2>
                ${plugins ? `
                <table style="width: 100%; border-collapse: collapse; background: #f8f9fa; border-radius: 6px; overflow: hidden; margin-bottom: 20px;">
                    <thead>
                        <tr style="background: #3498db; color: white;">
                            <th style="padding: 10px; text-align: left;">Name</th>
                            <th style="padding: 10px; text-align: left;">Version</th>
                            <th style="padding: 10px; text-align: left;">Status</th>
                            <th style="padding: 10px; text-align: left;">Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${plugins.map(p => `<tr style="border-bottom: 1px solid #ddd;">
                            <td style="padding: 10px;">${escapeHtml(p.name || p.id)}${p.id === 'settings.reaplugin' ? ' <em style="color: #666;">(this plugin)</em>' : ''}</td>
                            <td style="padding: 10px;">${escapeHtml(p.version) || 'N/A'}</td>
                            <td style="padding: 10px;">
                                <span class="status-indicator ${p.loaded ? 'status-ok' : 'status-error'}"></span>
                                ${p.loaded ? 'Loaded' : 'Disabled'}
                            </td>
                            <td style="padding: 10px;">
                                ${p.id === 'settings.reaplugin'
                                  ? '<span style="color: #999; font-style: italic;">Cannot modify self</span>'
                                  : `<button class="btn ${p.loaded ? '' : 'btn-primary'}" style="${p.loaded ? 'background: #f39c12; color: white;' : ''} margin-right: 4px;" onclick="${p.loaded ? `disablePlugin(${escapeHtml(JSON.stringify(p.id))})` : `enablePlugin(${escapeHtml(JSON.stringify(p.id))})`}">${p.loaded ? 'Disable' : 'Enable'}</button><button class="btn" style="background: #e74c3c; color: white;" onclick="removePlugin(${escapeHtml(JSON.stringify(p.id))}, ${escapeHtml(JSON.stringify(p.name || p.id))})">Remove</button>`}
                            </td>
                        </tr>`).join('')}
                    </tbody>
                </table>
                <h3 style="margin-bottom: 10px; color: #2c3e50;">Install Plugin (coming soon)</h3>
                <div class="setting-item" style="flex-wrap: wrap; gap: 10px;">
                    <label class="setting-label" for="pluginUrl" style="flex-basis: 100%;">Plugin URL</label>
                    <div class="setting-control" style="flex: 1;">
                        <input type="text" id="pluginUrl" placeholder="https://example.com/plugin.zip" style="width: 100%; min-width: 250px;" disabled>
                        <button class="btn btn-primary" onclick="installPlugin()" disabled>Install</button>
                    </div>
                </div>
                ` : '<div class="error" role="alert">Failed to load plugins</div>'}
            </section>

            <!-- Feedback -->
            <section class="section" aria-labelledby="feedback-heading">
                <h2 id="feedback-heading">Feedback</h2>
                <p style="color: #666; margin-bottom: 15px;">Submit feedback or report an issue. This will create a GitHub issue if the feedback service is configured.</p>
                <div style="margin-bottom: 10px;">
                    <label for="feedbackText" class="setting-label" style="display: block; margin-bottom: 8px;">Your feedback</label>
                    <textarea id="feedbackText" rows="4" style="width: 100%; padding: 10px; border: 2px solid #999; border-radius: 4px; font-family: inherit; font-size: 14px; resize: vertical;" placeholder="Describe the issue or suggestion..."></textarea>
                </div>
                <button class="btn btn-primary" onclick="submitFeedback()">Submit Feedback</button>
            </section>

            <!-- About -->
            <section class="section" aria-labelledby="about-heading">
                <h2 id="about-heading">About</h2>
                ${appInfo ? `
                <div class="settings-grid" role="group" aria-label="Application information">
                    ${appInfo.version ? `<div class="setting-item">
                        <span class="setting-label">Version</span>
                        <span class="readonly">${escapeHtml(appInfo.version)}</span>
                    </div>` : ''}
                    ${appInfo.build ? `<div class="setting-item">
                        <span class="setting-label">Build</span>
                        <span class="readonly">${escapeHtml(appInfo.build)}</span>
                    </div>` : ''}
                    ${appInfo.commit ? `<div class="setting-item">
                        <span class="setting-label">Commit</span>
                        <span class="readonly" style="font-size: 12px;">${escapeHtml(appInfo.commit)}</span>
                    </div>` : ''}
                    ${appInfo.branch ? `<div class="setting-item">
                        <span class="setting-label">Branch</span>
                        <span class="readonly">${escapeHtml(appInfo.branch)}</span>
                    </div>` : ''}
                </div>
                ` : '<div class="error" role="alert">Failed to load app info</div>'}
            </section>
        </main>
    </div>

    <!-- Screen reader announcements -->
    <div id="sr-announcements" role="status" aria-live="polite" aria-atomic="true" class="visually-hidden"></div>

    <script>
        // Announce messages to screen readers
        function announceToScreenReader(message) {
            const announcer = document.getElementById('sr-announcements');
            announcer.textContent = message;
            // Clear after announcement
            setTimeout(() => {
                announcer.textContent = '';
            }, 1000);
        }

        function showToast(message, isError = false) {
            const toast = document.createElement('div');
            toast.className = isError ? 'error-toast' : 'success-toast';
            toast.setAttribute('role', isError ? 'alert' : 'status');
            toast.setAttribute('aria-live', isError ? 'assertive' : 'polite');
            toast.textContent = message;
            document.body.appendChild(toast);
            
            // Also announce to screen readers
            announceToScreenReader(message);
            
            setTimeout(() => {
                toast.remove();
            }, 3000);
        }

        const baseUrl = window.location.protocol + '//' + window.location.host;

        async function updateReaSetting(key, value) {
            try {
                const payload = {};
                payload[key] = value;
                
                const response = await fetch(baseUrl + '/api/v1/settings', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(payload)
                });

                if (response.ok) {
                    showToast('Decent setting updated successfully');
                    document.getElementById('timestamp').textContent = new Date().toLocaleString();
                } else {
                    const error = await response.text();
                    showToast('Failed to update Decent setting: ' + error, true);
                }
            } catch (e) {
                showToast('Error updating Decent setting: ' + e.message, true);
            }
        }

        async function updateDe1Setting(key, value) {
            try {
                const payload = {};
                payload[key] = value;
                
                const response = await fetch(baseUrl + '/api/v1/machine/settings', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(payload)
                });

                if (response.ok || response.status === 202) {
                    showToast('Machine setting updated successfully');
                    document.getElementById('timestamp').textContent = new Date().toLocaleString();
                } else {
                    const error = await response.text();
                    showToast('Failed to update machine setting: ' + error, true);
                }
            } catch (e) {
                showToast('Error updating machine setting: ' + e.message, true);
            }
        }

        async function updateCalibrationSetting(key, value) {
            try {
                const payload = {};
                payload[key] = value;

                const response = await fetch(baseUrl + '/api/v1/machine/calibration', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(payload)
                });

                if (response.ok || response.status === 202) {
                    showToast('Calibration setting updated successfully');
                    document.getElementById('timestamp').textContent = new Date().toLocaleString();
                } else {
                    const error = await response.text();
                    showToast('Failed to update calibration setting: ' + error, true);
                }
            } catch (e) {
                showToast('Error updating calibration setting: ' + e.message, true);
            }
        }

        async function updateDe1AdvancedSetting(key, value) {
            try {
                const payload = {};
                payload[key] = value;
                
                const response = await fetch(baseUrl + '/api/v1/machine/settings/advanced', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(payload)
                });

                if (response.ok || response.status === 202) {
                    showToast('Machine advanced setting updated successfully');
                    document.getElementById('timestamp').textContent = new Date().toLocaleString();
                } else {
                    const error = await response.text();
                    showToast('Failed to update machine advanced setting: ' + error, true);
                }
            } catch (e) {
                showToast('Error updating machine advanced setting: ' + e.message, true);
            }
        }

        // --- Simulated Devices ---
        async function toggleSimulatedDevice(type, checked) {
            try {
                // Fetch current settings to get existing list
                const res = await fetch(baseUrl + '/api/v1/settings');
                const settings = res.ok ? await res.json() : {};
                let devices = Array.isArray(settings.simulatedDevices) ? [...settings.simulatedDevices] : [];
                if (checked && !devices.includes(type)) {
                    devices.push(type);
                } else if (!checked) {
                    devices = devices.filter(d => d !== type);
                }
                const response = await fetch(baseUrl + '/api/v1/settings', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ simulatedDevices: devices })
                });
                if (response.ok) {
                    showToast('Simulated device ' + type + (checked ? ' enabled' : ' disabled') + '. Restart the app for changes to take effect.');
                } else {
                    const error = await response.text();
                    showToast('Failed to update simulated devices: ' + error, true);
                }
            } catch (e) {
                showToast('Error updating simulated devices: ' + e.message, true);
            }
        }

        // --- Skins Management ---
        // Switch skin: set as default, then restart server if running
        // Mirrors native settings_view.dart _restartServerWithSkin flow:
        //   1. Set default skin via PUT /api/v1/webui/skins/default
        //   2. If server is running: stop, then start (picks up new default)
        async function switchSkin() {
            const skinId = document.getElementById('activeSkin').value;
            if (!skinId) { showToast('Please select a skin', true); return; }
            try {
                showToast('Switching skin...');
                // Step 1: Set as default
                const setResponse = await fetch(baseUrl + '/api/v1/webui/skins/default', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ skinId: skinId })
                });
                if (!setResponse.ok) {
                    const error = await setResponse.text();
                    showToast('Failed to set default skin: ' + error, true);
                    return;
                }
                // Step 2: If server is running, restart with new skin
                const statusResponse = await fetch(baseUrl + '/api/v1/webui/server/status');
                const status = await statusResponse.json();
                if (status.serving) {
                    await fetch(baseUrl + '/api/v1/webui/server/stop', { method: 'POST' });
                    const startResponse = await fetch(baseUrl + '/api/v1/webui/server/start', { method: 'POST' });
                    if (startResponse.ok) {
                        showToast('Skin switched and server restarted');
                    } else {
                        showToast('Skin set but server failed to restart', true);
                    }
                } else {
                    showToast('Default skin updated');
                }
                setTimeout(() => location.reload(), 500);
            } catch (e) {
                showToast('Error switching skin: ' + e.message, true);
            }
        }

        async function removeSkin(id, name) {
            if (!confirm('Remove skin "' + name + '"? This cannot be undone.')) return;
            try {
                const response = await fetch(baseUrl + '/api/v1/webui/skins/' + encodeURIComponent(id), {
                    method: 'DELETE'
                });
                if (response.ok) {
                    showToast('Skin removed');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to remove skin: ' + error, true);
                }
            } catch (e) {
                showToast('Error removing skin: ' + e.message, true);
            }
        }

        async function checkSkinUpdates() {
            try {
                showToast('Checking for skin updates...');
                const response = await fetch(baseUrl + '/api/v1/webui/skins/update', { method: 'POST' });
                if (response.ok) {
                    showToast('Skin update check completed');
                    setTimeout(() => location.reload(), 1000);
                } else {
                    const error = await response.text();
                    showToast('Update check failed: ' + error, true);
                }
            } catch (e) {
                showToast('Error checking for updates: ' + e.message, true);
            }
        }

        async function installSkin() {
            const source = document.getElementById('skinSource').value.trim();
            if (!source) { showToast('Please enter a GitHub repo or URL', true); return; }

            try {
                let url, body;
                // Detect owner/repo format (e.g. "user/repo")
                if (source.indexOf('/') > 0 && source.indexOf('/') === source.lastIndexOf('/') && !source.startsWith('http')) {
                    url = baseUrl + '/api/v1/webui/skins/install/github-release';
                    body = JSON.stringify({ repo: source });
                } else {
                    url = baseUrl + '/api/v1/webui/skins/install/url';
                    body = JSON.stringify({ url: source });
                }
                showToast('Installing skin...');
                const response = await fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: body
                });
                if (response.ok) {
                    showToast('Skin installed successfully');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to install skin: ' + error, true);
                }
            } catch (e) {
                showToast('Error installing skin: ' + e.message, true);
            }
        }

        // --- WebUI Server ---
        async function startWebUI() {
            try {
                const response = await fetch(baseUrl + '/api/v1/webui/server/start', { method: 'POST' });
                if (response.ok) {
                    showToast('WebUI server started');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to start WebUI server: ' + error, true);
                }
            } catch (e) {
                showToast('Error starting WebUI server: ' + e.message, true);
            }
        }

        async function stopWebUI() {
            try {
                const response = await fetch(baseUrl + '/api/v1/webui/server/stop', { method: 'POST' });
                if (response.ok) {
                    showToast('WebUI server stopped');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to stop WebUI server: ' + error, true);
                }
            } catch (e) {
                showToast('Error stopping WebUI server: ' + e.message, true);
            }
        }

        // --- Data Management ---
        async function importData() {
            const fileInput = document.getElementById('importFile');
            if (!fileInput.files || !fileInput.files[0]) {
                showToast('Please select a ZIP file first', true);
                return;
            }
            showToast('Importing data...');
            try {
                const response = await fetch(baseUrl + '/api/v1/data/import', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/zip' },
                    body: fileInput.files[0]
                });
                const result = await response.json().catch(() => ({}));
                if (response.status === 200) {
                    showToast('Data imported successfully');
                    setTimeout(() => location.reload(), 1000);
                } else if (response.status === 207) {
                    const sections = Object.values(result).filter(section => section && typeof section === 'object');
                    const hasProgress = sections.some(section =>
                        section.status === 'complete' ||
                        section.status === 'partial' ||
                        (Number.isInteger(section.imported) && section.imported > 0) ||
                        (Number.isInteger(section.skipped) && section.skipped > 0)
                    );
                    const errors = sections
                        .filter(section => section && Array.isArray(section.errors))
                        .flatMap(section => section.errors);
                    const detail = errors.length ? ': ' + errors.join('; ') : '';
                    showToast(
                        (hasProgress ? 'Data import partially completed' : 'Data import completed with errors') + detail,
                        true
                    );
                } else {
                    const error = result.message || result.error || ('Server returned ' + response.status);
                    showToast('Failed to import data: ' + error, true);
                }
            } catch (e) {
                showToast('Error importing data: ' + e.message, true);
            }
        }

        async function syncData() {
            const target = document.getElementById('syncTarget').value.trim();
            if (!target) { showToast('Please enter a target URL', true); return; }

            const mode = document.getElementById('syncMode').value;
            const onConflict = document.getElementById('syncConflict').value;
            const continueOnPullFailure = document.getElementById('syncContinue').checked;
            const sectionCheckboxes = document.querySelectorAll('.sync-section:checked');
            const sections = Array.from(sectionCheckboxes).map(cb => cb.value);

            if (sections.length === 0) {
                showToast('Please select at least one section to sync', true);
                return;
            }

            try {
                showToast('Syncing data...');
                const response = await fetch(baseUrl + '/api/v1/data/sync', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        target,
                        mode,
                        onConflict,
                        sections,
                        ...(mode === 'two_way' && continueOnPullFailure
                            ? { continueOnPullFailure: true }
                            : {})
                    })
                });
                const result = await response.json().catch(() => null);
                const detail = syncResultDetail(result);
                if (result && result.complete === true) {
                    showToast('Sync completed successfully');
                } else if (result && result.partial === true) {
                    showToast(
                        response.status === 207
                            ? 'Sync partially completed' + detail
                            : 'Sync failed with partial progress' + detail,
                        true
                    );
                } else {
                    showToast('Sync failed' + detail, true);
                }
            } catch (e) {
                showToast('Error syncing data: ' + e.message, true);
            }
        }

        function updateSyncContinueVisibility() {
            const enabled = document.getElementById('syncMode').value === 'two_way';
            const option = document.getElementById('syncContinueOption');
            const checkbox = document.getElementById('syncContinue');
            option.style.display = enabled ? 'flex' : 'none';
            if (!enabled) checkbox.checked = false;
        }

        function syncResultDetail(result) {
            if (!result || typeof result !== 'object') return '';
            const details = [];
            Object.entries(result.phases || {}).forEach(([phase, value]) => {
                if (!value || typeof value !== 'object') return;
                if (value.status) details.push(phase + ': ' + value.status);
                if (value.message) details.push(value.message);
            });
            Object.entries({ pull: result.pull, push: result.push }).forEach(([phase, sections]) => {
                if (!sections || typeof sections !== 'object') return;
                Object.entries(sections).forEach(([section, value]) => {
                    if (!value || typeof value !== 'object') return;
                    const errors = Array.isArray(value.errors) ? value.errors.join('; ') : '';
                    if (value.status || errors) {
                        details.push(phase + '.' + section + ': ' + (value.status || 'failed') + (errors ? ' (' + errors + ')' : ''));
                    }
                });
            });
            return details.length ? ': ' + details.join('; ') : '';
        }

        updateSyncContinueVisibility();

        // --- Plugin Management ---
        async function enablePlugin(id) {
            try {
                const response = await fetch(baseUrl + '/api/v1/plugins/' + encodeURIComponent(id) + '/enable', { method: 'POST' });
                if (response.ok) {
                    showToast('Plugin enabled');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to enable plugin: ' + error, true);
                }
            } catch (e) {
                showToast('Error enabling plugin: ' + e.message, true);
            }
        }

        async function disablePlugin(id) {
            try {
                const response = await fetch(baseUrl + '/api/v1/plugins/' + encodeURIComponent(id) + '/disable', { method: 'POST' });
                if (response.ok) {
                    showToast('Plugin disabled');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to disable plugin: ' + error, true);
                }
            } catch (e) {
                showToast('Error disabling plugin: ' + e.message, true);
            }
        }

        async function removePlugin(id, name) {
            if (!confirm('Remove plugin "' + name + '"? This cannot be undone.')) return;
            try {
                const response = await fetch(baseUrl + '/api/v1/plugins/' + encodeURIComponent(id), {
                    method: 'DELETE'
                });
                if (response.ok) {
                    showToast('Plugin removed');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to remove plugin: ' + error, true);
                }
            } catch (e) {
                showToast('Error removing plugin: ' + e.message, true);
            }
        }

        async function installPlugin() {
            const url = document.getElementById('pluginUrl').value.trim();
            if (!url) { showToast('Please enter a plugin URL', true); return; }
            try {
                showToast('Installing plugin...');
                const response = await fetch(baseUrl + '/api/v1/plugins/install', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url: url })
                });
                if (response.ok) {
                    showToast('Plugin installed successfully');
                    setTimeout(() => location.reload(), 500);
                } else {
                    const error = await response.text();
                    showToast('Failed to install plugin: ' + error, true);
                }
            } catch (e) {
                showToast('Error installing plugin: ' + e.message, true);
            }
        }

        // --- Feedback ---
        async function submitFeedback() {
            const text = document.getElementById('feedbackText').value.trim();
            if (!text) { showToast('Please enter your feedback', true); return; }
            try {
                const response = await fetch(baseUrl + '/api/v1/feedback', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ description: text })
                });
                if (response.ok || response.status === 201) {
                    showToast('Feedback submitted. Thank you!');
                    document.getElementById('feedbackText').value = '';
                } else {
                    const error = await response.text();
                    showToast('Failed to submit feedback: ' + error, true);
                }
            } catch (e) {
                showToast('Error submitting feedback: ' + e.message, true);
            }
        }

        // Keyboard shortcuts
        document.addEventListener('keydown', function(e) {
            // Alt+R to refresh
            if (e.altKey && e.key === 'r') {
                e.preventDefault();
                location.reload();
                announceToScreenReader('Refreshing settings');
            }
        });

        // Improve form submission on Enter key
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && (e.target.tagName === 'SELECT' || e.target.type === 'number')) {
                e.preventDefault();
                const settingItem = e.target.closest('.setting-item');
                if (settingItem) {
                    const saveButton = settingItem.querySelector('.btn-primary');
                    if (saveButton) {
                        saveButton.click();
                    }
                }
            }
        });
    </script>
</body>
</html>`;
  }

  // Return the plugin object
  return {
    id: "settings.reaplugin",
    version: "0.1.8",

    onLoad(settings) {
      state.refreshInterval = settings.RefreshInterval !== undefined ? settings.RefreshInterval : 5;
      log(`Loaded with refresh interval: ${state.refreshInterval}s`);
    },

    onUnload() {
      log("Unloaded");
    },

    // HTTP request handler for the 'ui' endpoint
    __httpRequestHandler(request) {
      log(`Received HTTP request for ${request.endpoint}: ${request.method}`);

      if (request.endpoint === "ui") {
        // Fetch all settings and generate HTML
        return Promise.all([
          fetchReaSettings(),
          fetchDe1Settings(),
          fetchDe1AdvancedSettings(),
          fetchWebUISkins(),
          fetchCalibrationSettings(),
          fetchPresenceSettings(),
          fetchAppInfo(),
          fetchWebUIServerStatus(),
          fetchPlugins()
        ]).then(([reaSettings, de1Settings, de1AdvancedSettings, webUISkins, calibrationSettings, presenceSettings, appInfo, webUIStatus, plugins]) => {
          const backName = request.query && request.query.backName ? request.query.backName : null;
          const html = generateSettingsHTML(reaSettings, de1Settings, de1AdvancedSettings, webUISkins, calibrationSettings, presenceSettings, appInfo, webUIStatus, plugins, backName);
          
          return {
            requestId: request.requestId,
            status: 200,
            headers: {
              'Content-Type': 'text/html; charset=utf-8',
              'Cache-Control': 'no-cache'
            },
            body: html
          };
        }).catch((error) => {
          log(`Error generating settings page: ${error.message}`);
          return {
            requestId: request.requestId,
            status: 500,
            headers: {
              'Content-Type': 'text/plain'
            },
            body: `Error generating settings page: ${error.message}`
          };
        });
      }

      // Default 404 response
      return {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ error: "Endpoint not found" })
      };
    },

    onEvent(event) {
      if (!event || !event.name) return;

      // This plugin doesn't need to respond to state updates
      // It only serves HTTP requests on demand
      switch (event.name) {
        case "shutdown":
          log("Shutdown event received");
          break;
      }
    },
  };
}













