/* visualizer.reaplugin
 *
 * Contract:
 * - This file must define a function named 'createPlugin'
 * - Factory function receives 'host' object as parameter
 * - Returns a plugin object with onLoad, onUnload, onEvent methods
 */

// Standard factory function - receives host object from PluginManager
function createPlugin(host) {
  "use strict";

  const SHOT_FETCH_DELAY_MS = 5000;
  const NS = "visualizer.reaplugin";
  const LOCAL_API_URL = "http://localhost:8080/api/v1";
  const VISUALIZER_API_URL = "https://visualizer.coffee/api";
  const VISUALIZER_SHARED_API = "https://visualizer.coffee/api/shots/shared?code=";
  const VISUALIZER_PROFILE_API = "https://visualizer.coffee/api/shots/%1/profile?format=json";

  let shotFetchTimeoutId = null;
  let backSyncTimeoutId = null;
  let isUploading = false;

  const state = {
    lastUploadedShot: null,
    lastVisualizerId: null,
    lastCheckedShotId: null,
    username: null,
    password: null,
    autoUpload: true,
    lengthThreshold: 5,
    lastMachineState: null,
    // Back-sync: pull metadata edited on Visualizer back onto local shots.
    backSyncEnabled: false,
    backSyncIntervalSeconds: 300,
    backSyncCursor: 0, // newest remote updated_at we've processed
    shotMap: {}, // visualizerId -> localShotId, for our own uploads only
    backSyncState: {}, // visualizerId -> { remoteUpdatedAt }
    backSyncRunning: false,
    localSyncPending: {},
    localSyncRunning: {},
    localSyncSuppressions: {},
    localTagRevisions: {},
    managedLocalTags: {},
    localSyncStatus: { lastCheck: null, lastResult: null, lastError: null, lastShotId: null, lastVisualizerId: null },
    backSyncStatus: { lastCheck: null, lastResult: null, lastError: null, lastApplied: 0 },
  };

  function log(msg) {
    host.log(`[visualizer] ${msg}`);
  }

  async function fetchShot(shotId) {
    try {
      const url = shotId
        ? `http://localhost:8080/api/v1/shots/${shotId}`
        : "http://localhost:8080/api/v1/shots/latest";
      const res = await fetch(url);
      if (!res.ok) {
        log(`Failed to fetch shot: ${res.status} ${res.statusText}`);
        return null;
      }
      return await res.json();
    } catch (e) {
      log(`Error fetching shot: ${e.message}`);
      return null;
    }
  }

  function getAuthHeader(authState) {
    if (authState == null) {
      authState = state;
    }

    if (!authState.username || !authState.password) {
      throw new Error("Username or password not configured");
    }
    return "Basic " + btoa(authState.username + ":" + authState.password);
  }

  function buildMultipartBody({ fieldName, filename, contentType, data }) {
    const boundary = "----reaBoundary" + Math.random().toString(16).slice(2);

    const body =
      `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="${fieldName}"; filename="${filename}"\r\n` +
      `Content-Type: ${contentType}\r\n\r\n` +
      data + `\r\n` +
      `--${boundary}--\r\n`;

    return {
      body,
      boundary,
    };
  }
  /// FormData and Blob not available in Flutter_JS
  async function uploadShot(shotData, onRetry) {
    const retries = 3;
    const delay = 2000;
    const url = `${VISUALIZER_API_URL}/shots/upload`;

    log(`shot duration: ${shotData.duration}`);
    if (shotData.duration < state.lengthThreshold) {
      log(`Not uploading shot because it's too short: ${shotData.duration}`);
      throw new Error(`Not uploading shot because it's too short: ${shotData.duration}`);
    }

    const payload = buildMultipartBody({
      fieldName: "file",
      filename: "file.shot",
      contentType: "application/json",
      data: JSON.stringify(shotData),
    });

    for (let i = 0; i < retries; i++) {
      try {
        const authHeader = getAuthHeader();
        const response = await fetch(url, {
          method: "POST",
          headers: {
            "Authorization": authHeader,
            "Content-Type": `multipart/form-data; boundary=${payload.boundary}`,
          },
          body: payload.body,
        });

        if (response.ok) {
          return await response.json();
        }

        const errorText = await response.text();

        // 4xx → fail fast
        if (response.status >= 400 && response.status < 500) {
          throw new Error(`HTTP ${response.status}: ${errorText}`);
        }

        throw new Error(`HTTP ${response.status}: ${errorText}`);

      } catch (error) {
        console.error(`Upload attempt ${i + 1}/${retries} failed:`, error.message, error.stack);

        if (i === retries - 1) {
          throw error;
        }

        if (onRetry) {
          onRetry(i + 1, retries);
        }

        await new Promise(res => setTimeout(res, delay));
      }
    }
  }

  function isEspressoUploadFrame(measurement) {
    const substate = measurement?.machine?.state?.substate;
    return substate === 'preinfusion' || substate === 'pouring';
  }

  function visualizerUploadMeasurements(measurements) {
    const firstEspressoIndex = measurements.findIndex(isEspressoUploadFrame);
    if (firstEspressoIndex < 0) {
      throw new Error("Shot has no espresso frames for Visualizer upload.");
    }

    let lastEspressoIndex = firstEspressoIndex;
    for (let i = firstEspressoIndex + 1; i < measurements.length; i++) {
      if (!isEspressoUploadFrame(measurements[i])) break;
      lastEspressoIndex = i;
    }

    return measurements.slice(firstEspressoIndex, lastEspressoIndex + 1);
  }

  function normalizeTags(tags) {
    if (!Array.isArray(tags)) return [];
    return Array.from(new Set(tags.map((tag) => String(tag).trim()).filter((tag) => tag.length > 0)));
  }

  function extractTags(shot) {
    const annotations = shot?.annotations || {};
    const context = shot?.workflow?.context || {};
    const recipeTags = Array.isArray(context.extras?.tags) ? context.extras.tags : [];
    const shotTags = Array.isArray(annotations.extras?.tags) ? annotations.extras.tags : [];
    return normalizeTags([...recipeTags, ...shotTags]);
  }

  function convertReaToVisualizerFormat(reaShot) {
    if (!reaShot || !reaShot.measurements || reaShot.measurements.length === 0) {
      throw new Error("Invalid or empty Decent shot data for conversion.");
    }

    const uploadMeasurements = visualizerUploadMeasurements(reaShot.measurements);
    const firstTimestamp = new Date(uploadMeasurements[0].machine.timestamp).getTime();
    const lastMeasurement = uploadMeasurements[uploadMeasurements.length - 1];
    const lastTimestamp = new Date(lastMeasurement.machine.timestamp).getTime();
    const annotations = reaShot.annotations || {};
    const context = reaShot.workflow?.context || {};
    let totalWaterDispensed = 0;

    const visualizerShot = {
      // start_time: reaShot.measurements[0].machine.timestamp,
      timestamp: Math.floor(firstTimestamp / 1000),
      duration: (lastTimestamp - firstTimestamp) / 1000,
      elapsed: [],
      pressure: { pressure: [], goal: [] },
      flow: { flow: [], goal: [], by_weight: [] },
      temperature: { mix: [], basket: [], goal: [], mix_goal: [] },
      totals: { weight: [], water_dispensed: [] },
      state_change: [],
      profile: reaShot.workflow.profile,
      app: {
        data: {
          settings: {
            bean_weight: String(annotations.actualDoseWeight ?? context.targetDoseWeight ?? reaShot.workflow.doseData?.doseIn ?? 0),
            drink_weight: String(annotations.actualYield ?? lastMeasurement.scale?.weight ?? 0),
            target_weight: String(context.targetYield ?? reaShot.workflow.profile.target_weight),
            grinder_model: context.grinderModel ?? reaShot.workflow.grinderData?.model,
            grinder_setting: context.grinderSetting ?? reaShot.workflow.grinderData?.setting,
            bean_brand: context.coffeeRoaster ?? reaShot.workflow.coffeeData?.roaster,
            bean_type: context.coffeeName ?? reaShot.workflow.coffeeData?.name,
            drink_tds: annotations.drinkTds != null ? String(annotations.drinkTds) : undefined,
            drink_ey: annotations.drinkEy != null ? String(annotations.drinkEy) : undefined,
            espresso_enjoyment: annotations.enjoyment != null ? String(Math.round(Number(annotations.enjoyment))) : undefined,
            espresso_notes: annotations.espressoNotes,
          }
        }
      },
    };

    for (let i = 0; i < uploadMeasurements.length; i++) {
      const m = uploadMeasurements[i];
      const machine = m.machine;
      const scale = m.scale;

      const currentTimestamp = new Date(machine.timestamp).getTime();
      const elapsed = (currentTimestamp - firstTimestamp) / 1000;
      if (i > 0) {
        const prevMachine = uploadMeasurements[i - 1].machine;
        const timeDelta = elapsed - visualizerShot.elapsed[i - 1];
        totalWaterDispensed += prevMachine.flow * timeDelta;
      }
      const waterDispensed = Number.isFinite(m.volume) ? m.volume : totalWaterDispensed;

      visualizerShot.elapsed.push(elapsed);

      visualizerShot.pressure.pressure.push(machine.pressure);
      visualizerShot.pressure.goal.push(machine.targetPressure);
      visualizerShot.flow.flow.push(machine.flow);
      visualizerShot.flow.goal.push(machine.targetFlow);
      visualizerShot.flow.by_weight.push(scale?.weightFlow ?? 0);
      visualizerShot.temperature.mix.push(machine.mixTemperature);
      visualizerShot.temperature.basket.push(machine.groupTemperature);
      visualizerShot.temperature.goal.push(machine.targetGroupTemperature);
      visualizerShot.temperature.mix_goal.push(machine.targetMixTemperature);
      visualizerShot.totals.weight.push(scale?.weight ?? 0);
      visualizerShot.totals.water_dispensed.push(waterDispensed / 10);
      // Visualizer's stage parser ignores numeric 0, so the zero-based DE1
      // frame index must be shifted to a 1-based marker.
      visualizerShot.state_change.push(machine.profileFrame + 1);
    }

    return visualizerShot;
  }

  async function handleShotComplete() {
    if (isUploading) return;
    isUploading = true;

    try {
      if (!state.autoUpload) {
        log("Auto upload disabled, skipping");
        return;
      }

      // Fetch latest shot metadata (without measurements)
      const latestMeta = await fetchShot();
      if (!latestMeta || !latestMeta.id) {
        log("No shot data available");
        return;
      }

      if (latestMeta.id === state.lastCheckedShotId) {
        log(`Shot ${latestMeta.id} already checked`);
        return;
      }

      state.lastCheckedShotId = latestMeta.id;

      if (!state.username || !state.password) {
        log("Username/password not configured. Skipping upload.");
        return;
      }

      // Fetch full shot with measurements for upload
      const fullShot = await fetchShot(latestMeta.id);
      if (!fullShot) {
        log(`Failed to fetch full shot ${latestMeta.id}`);
        return;
      }

      const result = await uploadShot(convertReaToVisualizerFormat(fullShot), null);
      rememberSuccessfulUpload(fullShot.id, result.id);
      syncSuccessfulUpload(fullShot.id, result.id, fullShot);

      log(`Uploaded ${fullShot.id} → ${result.id}`);

      host.emit("shotUploaded", {
        shotId: fullShot.id,
        visualizerId: result.id,
        tagSyncPending: true,
        timestamp: Date.now()
      });
    } catch (e) {
      log(`Error: ${e.message}`);
      host.emit("uploadError", {
        error: e.message,
        timestamp: Date.now()
      });
    } finally {
      isUploading = false;
    }
  }

  function handleStorageRead(payload) {
    if (payload.key === "lastUploadedShot") {
      state.lastUploadedShot = payload.value;
      log(`Loaded lastUploadedShot from storage: ${payload.value}`);
    } else if (payload.key === "lastVisualizerId") {
      state.lastVisualizerId = payload.value;
      log(`Loaded lastVisualizerId from storage: ${payload.value}`);
    } else if (payload.key === "shotMap") {
      state.shotMap = safeParseObject(payload.value) || {};
      log(`Loaded shot map (${Object.keys(state.shotMap).length} entries)`);
    } else if (payload.key === "backSyncCursor") {
      state.backSyncCursor = Number(payload.value) || 0;
    } else if (payload.key === "backSyncState") {
      state.backSyncState = safeParseObject(payload.value) || {};
    }
  }

  function handleStorageWrite(payload) {
    log(`Saved to storage: ${payload.key} = ${payload.value}`);
  }

  async function checkCredentials(body) {
    log(`checking creds: ${JSON.stringify(body)}`)
    const url = `${VISUALIZER_API_URL}/me`;
    const headers = {
      'Authorization': getAuthHeader(body)
    };

    try {
      const response = await fetch(url, {
        method: 'GET',
        headers: headers
      });

      return response.ok;
    } catch (error) {
      log('Error checking Visualizer credentials:', error);
      return false;
    }
  }

  async function importFromShareCode(shareCode) {
    const code = shareCode.trim();

    if (!code) {
      throw new Error("No share code provided");
    }

    log(`Importing profile from share code: ${code}`);

    // Step 1: Fetch shot metadata from share code
    const sharedUrl = `${VISUALIZER_SHARED_API}${code}`;
    log(`Fetching from: ${sharedUrl}`);

    const sharedResponse = await fetch(sharedUrl, {
      method: 'GET',
      headers: {
        'Authorization': getAuthHeader(),
        'Content-Type': 'application/json'
      }
    });

    if (!sharedResponse.ok) {
      const statusCode = sharedResponse.status;
      if (statusCode === 401) {
        throw new Error("Invalid Visualizer credentials");
      }
      throw new Error(`Failed to fetch share code: HTTP ${statusCode} ${sharedResponse.statusText}`);
    }

    const sharedData = await sharedResponse.json();
    log(`Share code response: ${JSON.stringify(sharedData).slice(0, 200)}`);

    // Handle both array and object responses
    let shotId;
    if (Array.isArray(sharedData)) {
      if (sharedData.length === 0) {
        throw new Error("No shared shots found for this code");
      }
      shotId = sharedData[0]?.id;
    } else {
      shotId = sharedData?.id;
    }

    if (!shotId) {
      throw new Error("Share code response missing shot ID");
    }

    log(`Got shot ID: ${shotId}, fetching profile...`);

    // Step 2: Fetch profile data using shot ID
    const profileUrl = VISUALIZER_PROFILE_API.replace('%1', shotId);
    log(`Fetching profile from: ${profileUrl}`);

    const profileResponse = await fetch(profileUrl, {
      method: 'GET',
      headers: {
        'Authorization': getAuthHeader(),
        'Content-Type': 'application/json'
      }
    });

    if (!profileResponse.ok) {
      const statusCode = profileResponse.status;
      if (statusCode === 401) {
        throw new Error("Invalid Visualizer credentials");
      }
      throw new Error(`Failed to fetch profile: HTTP ${statusCode} ${profileResponse.statusText}`);
    }

    const profileData = await profileResponse.json();
    log(`Fetched profile: ${JSON.stringify(profileData).slice(0, 200)}`);

    // Step 3: POST profile to Decent workflow endpoint
    log(`Posting profile to Decent workflow endpoint...`);
    const workflowResponse = await fetch('http://localhost:8080/api/v1/profiles', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        profile: profileData,
        metadata: { 'comment': `imported from visualizer: ${profileData.id}` }
      })
    });

    if (!workflowResponse.ok) {
      throw new Error(`Failed to import profile to Decent: HTTP ${workflowResponse.status} ${workflowResponse.statusText}`);
    }

    const workflowResult = await workflowResponse.json();
    log(`Profile imported successfully: ${JSON.stringify(workflowResult).slice(0, 100)}`);

    return {
      success: true,
      profileTitle: profileData.title || 'Imported Profile',
      profileId: workflowResult.id || workflowResult.profile?.id || null,
      shotId: shotId,
      workflowResult: workflowResult
    };
  }

  // ---- Back-sync: pull metadata edited on Visualizer back onto local shots ----

  function safeParseObject(value) {
    if (value == null) return null;
    if (typeof value === "object") return value;
    try {
      const parsed = JSON.parse(value);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch (e) {
      return null;
    }
  }

  function persistBackSyncState() {
    host.storage({ type: "write", key: "shotMap", namespace: NS, data: JSON.stringify(state.shotMap) });
    host.storage({ type: "write", key: "backSyncCursor", namespace: NS, data: String(state.backSyncCursor) });
    host.storage({ type: "write", key: "backSyncState", namespace: NS, data: JSON.stringify(state.backSyncState) });
  }

  function localShotVisualizerId(shot) {
    const extras = shot?.annotations?.extras || {};
    if (extras.visualizerId != null) return String(extras.visualizerId);
    if (extras.visualizer?.shot_id != null) return String(extras.visualizer.shot_id);
    return null;
  }

  async function refreshLocalShotMap() {
    let offset = 0;
    const limit = 100;
    let total = null;
    let added = 0;

    do {
      const res = await fetch(`${LOCAL_API_URL}/shots?limit=${limit}&offset=${offset}&order=desc`);
      if (!res.ok) throw new Error(`Local shots lookup failed: HTTP ${res.status}`);
      const page = await res.json();
      const items = Array.isArray(page) ? page : (page.items || []);
      if (total == null) total = Number(page.total) || items.length;

      for (const shot of items) {
        const visualizerId = localShotVisualizerId(shot);
        if (!visualizerId || !shot.id) continue;
        if (state.shotMap[visualizerId] !== shot.id) {
          state.shotMap[visualizerId] = shot.id;
          added++;
        }
      }

      offset += items.length;
      if (items.length === 0) break;
    } while (offset < total);

    if (added > 0) {
      persistBackSyncState();
      log(`Back-sync: discovered ${added} local Visualizer mapping(s)`);
    }
    return { total: Object.keys(state.shotMap).length, added };
  }

  function rememberUpload(localId, visualizerId) {
    if (!localId || visualizerId == null) return;
    state.shotMap = { ...state.shotMap, [String(visualizerId)]: localId };
    persistBackSyncState();
    const update = { annotations: { extras: { visualizerId: String(visualizerId) } } };
    suppressLocalSync(localId, update);
    fetch(`${LOCAL_API_URL}/shots/${localId}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(update),
    })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
      })
      .catch((e) => {
        consumeLocalSyncSuppression(localId, update);
        log(`Could not stamp visualizerId on ${localId}: ${e.message}`);
      });
  }

  function rememberSuccessfulUpload(localId, visualizerId) {
    state.lastUploadedShot = localId;
    state.lastVisualizerId = visualizerId;
    host.storage({ type: "write", key: "lastUploadedShot", namespace: NS, data: localId });
    host.storage({ type: "write", key: "lastVisualizerId", namespace: NS, data: visualizerId });
    rememberUpload(localId, visualizerId);
  }

  function syncSuccessfulUpload(localId, visualizerId, fallbackShot) {
    const id = String(visualizerId);
    const tagRevision = Number(state.localTagRevisions[id]) || 0;
    return fetchShot(localId)
      .then((currentShot) => {
        if ((Number(state.localTagRevisions[id]) || 0) !== tagRevision) {
          return { skipped: "newer tag update" };
        }
        return queueLocalSync(localId, id, { tags: extractTags(currentShot || fallbackShot) });
      })
      .catch((e) => {
        log(`Post-upload tag sync failed for ${localId}: ${e.message}`);
        recordLocalSyncStatus(localId, visualizerId, "error", e.message);
      });
  }

  async function visualizerGet(path) {
    const res = await fetch(`${VISUALIZER_API_URL}${path}`, {
      method: "GET",
      headers: { "Authorization": getAuthHeader(), "Content-Type": "application/json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
    return await res.json();
  }

  async function visualizerPatch(path, body) {
    const res = await fetch(`${VISUALIZER_API_URL}${path}`, {
      method: "PATCH",
      headers: {
        "Authorization": getAuthHeader(),
        "Content-Type": "application/json",
        "Accept": "application/json"
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`HTTP ${res.status}: ${text || res.statusText}`);
    }
    return await res.json();
  }

  function withoutKey(object, key) {
    return Object.fromEntries(Object.entries(object).filter(([entryKey]) => entryKey !== key));
  }

  function suppressLocalSync(localId, patch) {
    if (!localId) return;
    const id = String(localId);
    state.localSyncSuppressions = {
      ...state.localSyncSuppressions,
      [id]: [...(state.localSyncSuppressions[id] || []), JSON.stringify(patch || {})]
    };
    setTimeout(() => consumeLocalSyncSuppression(id, patch), 10000);
  }

  function consumeLocalSyncSuppression(localId, patch) {
    const id = String(localId || "");
    const suppressions = state.localSyncSuppressions[id] || [];
    const index = suppressions.indexOf(JSON.stringify(patch || {}));
    if (index < 0) return false;
    const remaining = [...suppressions.slice(0, index), ...suppressions.slice(index + 1)];
    state.localSyncSuppressions = remaining.length > 0
      ? { ...state.localSyncSuppressions, [id]: remaining }
      : withoutKey(state.localSyncSuppressions, id);
    return true;
  }

  function visualizerIdForLocalShot(shot) {
    const localId = shot?.id;
    if (!localId) return null;
    const extras = shot.annotations?.extras || {};
    if (extras.visualizerId != null) return String(extras.visualizerId);
    if (extras.visualizer?.shot_id != null) return String(extras.visualizer.shot_id);
    if (state.lastUploadedShot === localId && state.lastVisualizerId != null) {
      return String(state.lastVisualizerId);
    }
    for (const [visualizerId, mappedLocalId] of Object.entries(state.shotMap)) {
      if (mappedLocalId === localId) return String(visualizerId);
    }
    return null;
  }

  function hasOwn(object, key) {
    return object != null && Object.prototype.hasOwnProperty.call(object, key);
  }

  function localTagsTouched(patch) {
    if (hasOwn(patch, "metadata")) {
      if (patch.metadata == null || hasOwn(patch.metadata, "tags")) return true;
    }
    if (hasOwn(patch, "annotations")) {
      if (patch.annotations == null) return true;
      if (hasOwn(patch.annotations, "extras")) {
        if (patch.annotations.extras == null || hasOwn(patch.annotations.extras, "tags")) return true;
      }
    }
    if (hasOwn(patch, "workflow")) {
      if (patch.workflow == null) return true;
      if (hasOwn(patch.workflow, "context")) {
        if (patch.workflow.context == null) return true;
        if (hasOwn(patch.workflow.context, "extras")) {
          if (patch.workflow.context.extras == null || hasOwn(patch.workflow.context.extras, "tags")) return true;
        }
      }
    }
    return false;
  }

  // Build a Visualizer update from a local shot. In edit mode (force=false) a
  // field is pushed ONLY when the incoming patch touched it, so editing one
  // field (e.g. enjoyment) never re-sends — and clobbers — Visualizer-side
  // edits to other fields that haven't been back-synced yet. In force mode
  // (manual full sync) every mapped field is pushed: local-wins.
  function localShotToVisualizerUpdate(shot, patch, force) {
    const annotations = shot.annotations || {};
    const context = shot.workflow?.context || {};
    const patchAnnotations = patch?.annotations || {};
    const patchContext = patch?.workflow?.context || {};
    const payload = {};
    const touched = (source, sourceKey) => force === true || hasOwn(source, sourceKey);
    const setNumber = (key, value, source, sourceKey, transform) => {
      if (!touched(source, sourceKey)) return;
      if (hasOwn(source, sourceKey) && (value == null || value === "")) {
        payload[key] = null;
        return;
      }
      if (value == null || value === "") return;
      const number = Number(value);
      if (!Number.isFinite(number)) return;
      payload[key] = transform ? transform(number) : String(number);
    };
    const setString = (key, value, source, sourceKey, extraTouched) => {
      if (!extraTouched && !touched(source, sourceKey)) return;
      if ((extraTouched || hasOwn(source, sourceKey)) && (value == null || value === "")) {
        payload[key] = null;
        return;
      }
      if (typeof value === "string" && value.trim() !== "") payload[key] = value;
    };

    setNumber("espresso_enjoyment", annotations.enjoyment, patchAnnotations, "enjoyment", (n) => Math.round(n));
    setNumber("drink_tds", annotations.drinkTds, patchAnnotations, "drinkTds");
    setNumber("drink_ey", annotations.drinkEy, patchAnnotations, "drinkEy");
    setNumber("bean_weight", annotations.actualDoseWeight ?? context.targetDoseWeight, patchAnnotations, "actualDoseWeight");
    setNumber("drink_weight", annotations.actualYield ?? context.targetYield, patchAnnotations, "actualYield");
    setString(
      "espresso_notes",
      annotations.espressoNotes,
      patchAnnotations,
      "espressoNotes",
      hasOwn(patch, "shotNotes")
    );
    setString("barista", context.baristaName, patchContext, "baristaName");
    setString("grinder_setting", context.grinderSetting, patchContext, "grinderSetting");
    setString("bean_brand", context.coffeeRoaster, patchContext, "coffeeRoaster");
    setString("bean_type", context.coffeeName, patchContext, "coffeeName");
    // profile_title has no patch key; only send it in a full (force) sync.
    if (force === true) {
      const title = shot.workflow?.profile?.title || shot.workflow?.name;
      if (typeof title === "string" && title.trim() !== "") payload.profile_title = title;
    }
    if (force === true || localTagsTouched(patch)) {
      payload.tags = extractTags(shot);
    }

    return payload;
  }

  function recordLocalSyncStatus(shotId, visualizerId, result, error) {
    state.localSyncStatus = {
      lastCheck: Date.now(),
      lastResult: result || null,
      lastError: error || null,
      lastShotId: shotId || null,
      lastVisualizerId: visualizerId || null,
    };
  }

  async function mergeCurrentVisualizerTags(visualizerId, pending) {
    if (!hasOwn(pending.update, "tags")) {
      return { update: pending.update, managedTags: null };
    }
    const detail = await visualizerGet(`/shots/${visualizerId}?essentials=1`);
    const localTags = normalizeTags(pending.update.tags);
    const managedTags = new Set(normalizeTags(state.managedLocalTags[visualizerId]));
    const remoteOnlyTags = normalizeTags(detail?.tags).filter((tag) => !managedTags.has(tag));
    const remoteOnlySet = new Set(remoteOnlyTags);
    return {
      update: { ...pending.update, tags: normalizeTags([...localTags, ...remoteOnlyTags]) },
      managedTags: localTags.filter((tag) => !remoteOnlySet.has(tag))
    };
  }

  async function drainLocalSync(visualizerId) {
    while (state.localSyncPending[visualizerId]) {
      const pending = state.localSyncPending[visualizerId];
      try {
        const merged = await mergeCurrentVisualizerTags(visualizerId, pending);
        if (merged.managedTags !== null) {
          state.managedLocalTags = {
            ...state.managedLocalTags,
            [visualizerId]: merged.managedTags
          };
        }
        const detail = await visualizerPatch(`/shots/${visualizerId}`, { shot: merged.update });
        const updatedAt = Number(detail?.updated_at) || Number(detail?.meta?.visualizer?.updated_at) || 0;
        if (updatedAt > 0) {
          state.backSyncState = {
            ...state.backSyncState,
            [visualizerId]: { remoteUpdatedAt: updatedAt }
          };
          persistBackSyncState();
        }
        const current = state.localSyncPending[visualizerId];
        if (current?.revision !== pending.revision) {
          const update = Object.fromEntries(
            Object.entries(current.update).filter(([key, value]) =>
              !hasOwn(pending.update, key) || JSON.stringify(value) !== JSON.stringify(pending.update[key])
            )
          );
          if (Object.keys(update).length > 0) {
            state.localSyncPending = {
              ...state.localSyncPending,
              [visualizerId]: { ...current, update }
            };
            continue;
          }
        }
        state.localSyncPending = withoutKey(state.localSyncPending, visualizerId);
        host.emit("shotForwardSynced", {
          shotId: pending.shotId,
          visualizerId,
          timestamp: Date.now()
        });
        log(`Local sync: updated ${pending.shotId} → ${visualizerId}`);
        recordLocalSyncStatus(pending.shotId, visualizerId, "updated", null);
        return { ok: true, visualizerId };
      } catch (e) {
        const current = state.localSyncPending[visualizerId] || pending;
        if (current.revision !== pending.revision) continue;
        state.localSyncPending = withoutKey(state.localSyncPending, visualizerId);
        log(`Local sync failed for ${current.shotId}: ${e.message}`);
        host.emit("shotForwardSyncError", {
          shotId: current.shotId,
          visualizerId,
          error: e.message,
          timestamp: Date.now()
        });
        recordLocalSyncStatus(current.shotId, visualizerId, "error", e.message);
        return { error: e.message, visualizerId };
      }
    }
    return { ok: true, visualizerId };
  }

  function startLocalSync(visualizerId) {
    const id = String(visualizerId);
    if (state.localSyncRunning[id]) return state.localSyncRunning[id];
    const running = drainLocalSync(id).finally(() => {
      state.localSyncRunning = withoutKey(state.localSyncRunning, id);
      if (state.localSyncPending[id]) startLocalSync(id);
    });
    state.localSyncRunning = { ...state.localSyncRunning, [id]: running };
    return running;
  }

  function queueLocalSync(shotId, visualizerId, update) {
    const id = String(visualizerId);
    const previous = state.localSyncPending[id] || {};
    if (hasOwn(update, "tags")) {
      state.localTagRevisions = {
        ...state.localTagRevisions,
        [id]: (Number(state.localTagRevisions[id]) || 0) + 1
      };
    }
    state.localSyncPending = {
      ...state.localSyncPending,
      [id]: {
        shotId,
        update: { ...(previous.update || {}), ...update },
        revision: (Number(previous.revision) || 0) + 1
      }
    };
    return startLocalSync(id);
  }

  async function pushLocalShotUpdate(shot, patch, opts) {
    opts = opts || {};
    if (!shot || !shot.id) {
      recordLocalSyncStatus(null, null, "skipped: missing shot", null);
      return { skipped: "missing shot" };
    }
    if (!opts.force && consumeLocalSyncSuppression(shot.id, patch)) {
      recordLocalSyncStatus(shot.id, null, "skipped: suppressed", null);
      return { skipped: "suppressed" };
    }
    if (!state.username || !state.password) {
      recordLocalSyncStatus(shot.id, null, "skipped: no credentials", null);
      return { skipped: "no credentials" };
    }

    const visualizerId = visualizerIdForLocalShot(shot);
    if (!visualizerId) {
      log(`Local sync: ${shot.id} has no visualizer mapping`);
      recordLocalSyncStatus(shot.id, null, "skipped: no mapping", null);
      return { skipped: "no mapping" };
    }

    const update = localShotToVisualizerUpdate(shot, patch || {}, opts.force === true);
    if (Object.keys(update).length === 0) {
      recordLocalSyncStatus(shot.id, visualizerId, "skipped: empty update", null);
      return { skipped: "empty update" };
    }

    return await queueLocalSync(shot.id, visualizerId, update);
  }

  async function syncLocalShotNow(shotId) {
    const id = shotId || state.lastUploadedShot;
    if (!id) {
      recordLocalSyncStatus(null, null, "skipped: no shot id", null);
      return { skipped: "no shot id" };
    }
    const shot = await fetchShot(id);
    if (!shot) {
      recordLocalSyncStatus(id, null, "error", "shot not found");
      return { error: "shot not found" };
    }
    return await pushLocalShotUpdate(shot, {}, { force: true });
  }

  // /api/me returns 401 on bad creds, 200 when valid. Gate back-sync on it so we
  // never hit /api/shots unauthenticated (which would return the public feed).
  async function verifyCredentials() {
    try {
      const res = await fetch(`${VISUALIZER_API_URL}/me`, {
        method: "GET",
        headers: { "Authorization": getAuthHeader() },
      });
      if (!res.ok) return null;
      try { return await res.json(); } catch (e) { return {}; }
    } catch (e) {
      log(`Back-sync: /me check failed: ${e.message}`);
      return null;
    }
  }

  // The shot index echoes the authenticated user's id at the top level. If it's
  // present and isn't us, we are not looking at our own shots — bail rather than
  // risk writing someone else's edits onto local shots. (Absent => older server
  // without the field; the own-uploads map downstream is the real backstop, so
  // don't hard-fail on absence.)
  function assertOwnShotIndex(resp, myUserId) {
    if (!resp || Array.isArray(resp)) return;
    if (resp.user_id != null && myUserId != null && String(resp.user_id) !== String(myUserId)) {
      throw new Error("shot index user_id mismatch");
    }
  }

  // Authenticated → server returns only Current.user.shots, and `updated_after`
  // (Unix seconds) makes it return only shots changed since our cursor. So we
  // just page newest-first until a short page; no client-side cursor comparison.
  // Older servers ignore the unknown param and return everything, but the
  // per-shot sync state below still prevents re-applying unchanged shots.
  async function listChangedShots(cursor, myUserId) {
    const items = [];
    const maxPages = 20;
    const after = cursor > 0 ? `&updated_after=${cursor}` : "";
    for (let page = 1; page <= maxPages; page++) {
      const resp = await visualizerGet(`/shots?sort=updated_at&items=50&page=${page}${after}`);
      assertOwnShotIndex(resp, myUserId);
      const data = Array.isArray(resp) ? resp : (resp && resp.data) || [];
      if (data.length === 0) break;
      for (const shot of data) {
        items.push({ id: String(shot.id), updatedAt: Number(shot.updated_at) || 0 });
      }
      if (data.length < 50) break;
      if (page === maxPages) {
        log(`Back-sync: hit ${maxPages}-page cap (${items.length} changed shots); remaining advance next tick`);
      }
    }
    return items;
  }

  // Newest remote updated_at, for the first-run baseline — one item, so enabling
  // back-sync records a starting point without paging the whole library.
  async function newestRemoteUpdatedAt(myUserId) {
    const resp = await visualizerGet(`/shots?sort=updated_at&items=1`);
    assertOwnShotIndex(resp, myUserId);
    const data = Array.isArray(resp) ? resp : (resp && resp.data) || [];
    return data.reduce((max, shot) => Math.max(max, Number(shot.updated_at) || 0), 0);
  }

  // Build a partial reaprime shot update from a visualizer shot detail. PUT
  // /api/v1/shots/<id> deep-merges it, so only the changed fields are sent.
  function mapRemoteToLocal(remote) {
    const annotations = {};
    const context = {};
    const extras = {};
    const has = (key) => Object.prototype.hasOwnProperty.call(remote || {}, key);
    const numberField = (key) => {
      const value = has(key) ? remote[key] : null;
      if (value == null || value === "") return null;
      const number = Number(value);
      return Number.isFinite(number) ? number : undefined;
    };
    const stringField = (key) => {
      const value = has(key) ? remote[key] : null;
      if (value == null) return null;
      if (typeof value !== "string") return undefined;
      return value.trim() === "" ? null : value;
    };
    const set = (obj, key, value) => {
      if (value !== undefined) obj[key] = value;
    };

    set(annotations, "drinkTds", numberField("drink_tds"));
    set(annotations, "drinkEy", numberField("drink_ey"));
    set(annotations, "enjoyment", numberField("espresso_enjoyment"));
    set(annotations, "espressoNotes", stringField("espresso_notes"));
    set(annotations, "actualDoseWeight", numberField("bean_weight"));
    set(annotations, "actualYield", numberField("drink_weight"));
    set(context, "coffeeRoaster", stringField("bean_brand"));
    set(context, "coffeeName", stringField("bean_type"));
    set(context, "grinderModel", stringField("grinder_model"));
    set(context, "grinderSetting", stringField("grinder_setting"));

    for (const key of ["roast_level", "roast_date", "bean_notes", "private_notes",
      "tags", "fragrance", "aroma", "flavor", "aftertaste", "acidity",
      "bitterness", "sweetness", "mouthfeel"]) {
      set(extras, key, has(key) ? (remote[key] == null || remote[key] === "" ? null : remote[key]) : null);
    }

    const update = {};
    if (Object.keys(annotations).length || Object.keys(extras).length) {
      update.annotations = annotations;
      if (Object.keys(extras).length) update.annotations.extras = { visualizer: extras };
    }
    if (Object.keys(context).length) update.workflow = { context };
    return update;
  }

  async function runBackSync(opts) {
    opts = opts || {};
    if (state.backSyncRunning) return { skipped: "already running" };
    if (!state.backSyncEnabled && !opts.force) return { skipped: "disabled" };
    if (!state.username || !state.password) return { skipped: "no credentials" };

    state.backSyncRunning = true;
    state.backSyncStatus.lastCheck = Date.now();
    let applied = 0;
    try {
      // 1) Never query shots unless we're a verified, authenticated user.
      const me = await verifyCredentials();
      if (me == null) {
        state.backSyncStatus.lastError = "invalid credentials";
        log("Back-sync: credentials not valid — not querying shots");
        return { error: "invalid credentials" };
      }
      const myUserId = me.id != null ? me.id : (me.user_id != null ? me.user_id : (me.user && me.user.id));

      // The map is persisted and kept current on upload via rememberUpload, so
      // routine ticks rely on it; only a forced run re-pages the whole library
      // (heavy on large libraries) to rediscover mappings stamped out-of-band.
      const forceAll = opts.force === true;
      const localMap = forceAll
        ? await refreshLocalShotMap()
        : { total: Object.keys(state.shotMap).length, added: 0 };

      // 2) First run: set a baseline and apply nothing, so enabling back-sync
      // doesn't rewrite the entire history. Record the newest remote updated_at
      // (one item) rather than paging the whole library.
      if (!forceAll && state.backSyncCursor === 0) {
        state.backSyncCursor = await newestRemoteUpdatedAt(myUserId);
        persistBackSyncState();
        state.backSyncStatus.lastResult = "baseline set";
        state.backSyncStatus.lastError = null;
        log(`Back-sync baseline set at ${state.backSyncCursor}`);
        return { baseline: true };
      }

      const items = forceAll
        ? Object.keys(state.shotMap).map((id) => ({ id, updatedAt: 0, force: true }))
        : await listChangedShots(state.backSyncCursor, myUserId);

      // Process oldest-first so the cursor advances monotonically.
      const ordered = items.slice().sort((a, b) => a.updatedAt - b.updatedAt);
      let maxProcessed = state.backSyncCursor;
      let cursorBlocked = false;
      for (const item of ordered) {
        // 3) Only ever touch shots we uploaded ourselves.
        const localId = state.shotMap[item.id];
        if (!localId) {
          if (!cursorBlocked) maxProcessed = Math.max(maxProcessed, item.updatedAt);
          continue;
        }

        const prev = state.backSyncState[item.id];
        if (!item.force && prev && Number(prev.remoteUpdatedAt) >= item.updatedAt) {
          if (!cursorBlocked) maxProcessed = Math.max(maxProcessed, item.updatedAt);
          continue;
        }

        let detail;
        try {
          detail = await visualizerGet(`/shots/${item.id}?essentials=1`);
        } catch (e) {
          log(`Back-sync: failed to fetch ${item.id}: ${e.message}`);
          cursorBlocked = true;
          continue;
        }
        const itemUpdatedAt = Number(detail?.updated_at) || item.updatedAt || 0;

        const update = mapRemoteToLocal(detail);
        let processed = Object.keys(update).length === 0;
        if (Object.keys(update).length > 0) {
          suppressLocalSync(localId, update);
          const res = await fetch(`${LOCAL_API_URL}/shots/${localId}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(update),
          });
          if (res.ok) {
            applied++;
            processed = true;
            host.emit("shotBackSynced", { shotId: localId, visualizerId: item.id, timestamp: Date.now() });
          } else {
            consumeLocalSyncSuppression(localId, update);
            log(`Back-sync: PUT ${localId} failed ${res.status}`);
          }
        }

        if (processed) {
          state.backSyncState[item.id] = { remoteUpdatedAt: itemUpdatedAt };
          if (!cursorBlocked) maxProcessed = Math.max(maxProcessed, itemUpdatedAt);
        } else {
          cursorBlocked = true;
        }
      }

      state.backSyncCursor = maxProcessed;
      persistBackSyncState();
      state.backSyncStatus.lastResult = `applied ${applied}${forceAll ? ` (checked ${items.length}, mapped ${localMap.total})` : ''}`;
      state.backSyncStatus.lastApplied = applied;
      state.backSyncStatus.lastError = null;
      log(`Back-sync applied ${applied} change(s)`);
      return { applied };
    } catch (e) {
      state.backSyncStatus.lastError = e.message;
      log(`Back-sync error: ${e.message}`);
      return { error: e.message };
    } finally {
      state.backSyncRunning = false;
    }
  }

  // Arm a single back-sync run after delayMs, then re-arm at the configured
  // interval. A no-op (and cancels any pending run) when back-sync is disabled.
  function armBackSync(delayMs) {
    if (backSyncTimeoutId !== null) {
      clearTimeout(backSyncTimeoutId);
      backSyncTimeoutId = null;
    }
    if (!state.backSyncEnabled) return;
    backSyncTimeoutId = setTimeout(async () => {
      backSyncTimeoutId = null;
      try { await runBackSync(); } catch (e) { log(`Back-sync tick error: ${e.message}`); }
      const configured = Number(state.backSyncIntervalSeconds) || 300;
      const intervalSeconds = Math.max(60, configured);
      if (configured < 60) {
        log(`Back-sync interval ${configured}s is below the 60s minimum, clamped to 60s`);
      }
      armBackSync(intervalSeconds * 1000);
    }, delayMs);
  }

  // Return the plugin object
  return {
    id: "visualizer.reaplugin",
    version: "1.5.4",

    onLoad(settings) {
      state.username = settings.Username;
      state.password = settings.Password;
      state.autoUpload = settings.AutoUpload != undefined ? settings.AutoUpload : true;
      state.lengthThreshold = settings.LengthThreshold != undefined ? settings.LengthThreshold : 5;
      state.backSyncEnabled = settings.BackSync === true;
      state.backSyncIntervalSeconds = settings.BackSyncIntervalSeconds != undefined ? settings.BackSyncIntervalSeconds : 300;

      log(`Loaded with username: ${state.username ? 'configured' : 'not configured'}, back-sync ${state.backSyncEnabled ? 'on' : 'off'}`);

      // Load saved state from storage
      host.storage({ type: "read", key: "lastUploadedShot", namespace: NS });
      host.storage({ type: "read", key: "lastVisualizerId", namespace: NS });
      host.storage({ type: "read", key: "shotMap", namespace: NS });
      host.storage({ type: "read", key: "backSyncCursor", namespace: NS });
      host.storage({ type: "read", key: "backSyncState", namespace: NS });

      // First run ~30s after load so storage reads have settled.
      if (state.backSyncEnabled) armBackSync(30000);
    },

    onUnload() {
      log("Unloaded");
      if (shotFetchTimeoutId !== null) {
        clearTimeout(shotFetchTimeoutId);
        shotFetchTimeoutId = null;
      }
      if (backSyncTimeoutId !== null) {
        clearTimeout(backSyncTimeoutId);
        backSyncTimeoutId = null;
      }
      persistBackSyncState();

      // Save current state to storage
      if (state.lastUploadedShot) {
        host.storage({
          type: "write",
          key: "lastUploadedShot",
          namespace: "visualizer.reaplugin",
          data: state.lastUploadedShot
        });
      }

      if (state.lastVisualizerId) {
        host.storage({
          type: "write",
          key: "lastVisualizerId",
          namespace: "visualizer.reaplugin",
          data: state.lastVisualizerId
        });
      }
    },

    // HTTP request handler (optional - can also handle via onEvent)
    __httpRequestHandler(request) {
      host.log(`Received HTTP request for ${request.endpoint}: ${request.method}`);

      if (request.endpoint === "status") {
        return {
          requestId: request.requestId,
          status: 200,
          headers: {
            'Content-Type': 'application/json',
            'X-Custom-Header': 'Plugin-Response'
          },
          body: JSON.stringify({
            status: "online",
            timestamp: Date.now(),
          })
        };
      }

      if (request.endpoint === "upload") {
        const shotId = request.body?.shotId;

        if (!shotId) {
          return {
            requestId: request.requestId,
            status: 400,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ error: "shotId is required" }),
          };
        }

        let requestedShot;
        return fetch(`${LOCAL_API_URL}/shots/${encodeURIComponent(shotId)}`)
          .then(async (response) => {
            const body = await response.text();

            if (!response.ok) {
              throw new Error(
                `Failed to fetch local shot ${shotId}: HTTP ${response.status}: ${body}`,
              );
            }

            return JSON.parse(body);
          })
          .then((shot) => {
            requestedShot = shot;
            return uploadShot(convertReaToVisualizerFormat(shot), null);
          })
          .then((shotResponse) => {
            rememberSuccessfulUpload(shotId, shotResponse.id);
            syncSuccessfulUpload(shotId, shotResponse.id, requestedShot);

            return {
              requestId: request.requestId,
              status: 202,
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                visualizer_id: shotResponse.id,
                tag_sync_pending: true
              }),
            };
          })
          .catch((error) => ({
            requestId: request.requestId,
            status: 502,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              error: "Visualizer upload failed",
              detail: error.message,
            }),
          }));
      }

      if (request.endpoint === "verifyCredentials") {
        log(`verifying ${JSON.stringify(request.body)}`)
        return checkCredentials(request.body).then((verified) => {
          return {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              'valid': verified
            })
          }

        });
      }

      if (request.endpoint === 'lastUpload') {

        return {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            reaId: state.lastUploadedShot,
            visId: state.lastVisualizerId,
          })
        };
      }

      if (request.endpoint === 'import') {
        if (request.method !== 'POST') {
          return {
            status: 405,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ error: 'Method not allowed' })
          };
        }

        const shareCode = request.body?.shareCode;
        if (!shareCode) {
          return {
            status: 400,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ error: 'shareCode is required' })
          };
        }

        // Call importFromShareCode and handle the async result
        return importFromShareCode(shareCode)
          .then((result) => {
            // Emit event for UI listeners
            host.emit('profileImported', {
              success: true,
              profileTitle: result.profileTitle,
              shotId: result.shotId,
              timestamp: Date.now()
            });

            return {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify(result)
            };
          })
          .catch((error) => {
            log(`Import failed: ${error.message}`);

            // Emit error event for UI listeners
            host.emit('importError', {
              success: false,
              error: error.message,
              timestamp: Date.now()
            });

            return {
              status: error.message.includes('credentials') ? 401 : 400,
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                success: false,
                error: error.message
              })
            };
          });
      }

      if (request.endpoint === 'backSyncStatus') {
        return {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            enabled: state.backSyncEnabled,
            intervalSeconds: state.backSyncIntervalSeconds,
            cursor: state.backSyncCursor,
            mappedShots: Object.keys(state.shotMap).length,
            lastCheck: state.backSyncStatus.lastCheck,
            lastResult: state.backSyncStatus.lastResult,
            lastError: state.backSyncStatus.lastError,
            lastApplied: state.backSyncStatus.lastApplied,
          })
        };
      }

      if (request.endpoint === 'backSyncNow') {
        if (request.method !== 'POST') {
          return {
            status: 405,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ error: 'Method not allowed' })
          };
        }
        return runBackSync({ force: true }).then((result) => ({
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ok: true, result })
        }));
      }

      if (request.endpoint === 'forwardSyncStatus') {
        return {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            lastCheck: state.localSyncStatus.lastCheck,
            lastResult: state.localSyncStatus.lastResult,
            lastError: state.localSyncStatus.lastError,
            lastShotId: state.localSyncStatus.lastShotId,
            lastVisualizerId: state.localSyncStatus.lastVisualizerId,
            running: Object.keys(state.localSyncRunning),
            pending: Object.keys(state.localSyncPending),
          })
        };
      }

      if (request.endpoint === 'forwardSyncNow') {
        if (request.method !== 'POST') {
          return {
            status: 405,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ error: 'Method not allowed' })
          };
        }
        return syncLocalShotNow(request.body?.shotId).then((result) => ({
          status: result && result.error ? 400 : 200,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ok: !(result && result.error), result, status: state.localSyncStatus })
        }));
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

      switch (event.name) {
        case "stateUpdate":
          const currentState = event.payload?.state?.state;
          if (state.lastMachineState === "espresso" && currentState !== "espresso") {
            log(`Shot ended (${state.lastMachineState} → ${currentState}), scheduling upload in ${SHOT_FETCH_DELAY_MS / 1000}s`);
            if (shotFetchTimeoutId !== null) {
              clearTimeout(shotFetchTimeoutId);
            }
            shotFetchTimeoutId = setTimeout(() => {
              shotFetchTimeoutId = null;
              handleShotComplete();
            }, SHOT_FETCH_DELAY_MS);
          }
          state.lastMachineState = currentState;
          break;

        case "shutdown":
          if (shotFetchTimeoutId !== null) {
            clearTimeout(shotFetchTimeoutId);
            shotFetchTimeoutId = null;
          }
          break;

        case "storageRead":
          handleStorageRead(event.payload);
          break;

        case "storageWrite":
          handleStorageWrite(event.payload);
          break;

        case "settingsUpdated":
          if (event.payload?.AutoUpload !== undefined) {
            state.autoUpload = event.payload.AutoUpload;
            log(`AutoUpload updated: ${state.autoUpload}`);
          }
          if (event.payload?.Username !== undefined) {
            state.username = event.payload.Username;
          }
          if (event.payload?.Password !== undefined) {
            state.password = event.payload.Password;
          }
          if (event.payload?.LengthThreshold !== undefined) {
            state.lengthThreshold = event.payload.LengthThreshold;
          }
          if (event.payload?.BackSyncIntervalSeconds !== undefined) {
            state.backSyncIntervalSeconds = event.payload.BackSyncIntervalSeconds;
            if (state.backSyncEnabled) armBackSync(2000);
          }
          if (event.payload?.BackSync !== undefined) {
            state.backSyncEnabled = event.payload.BackSync === true;
            log(`BackSync updated: ${state.backSyncEnabled}`);
            // armBackSync cancels the pending run when disabled, or kicks one
            // off shortly after enabling.
            armBackSync(2000);
          }
          break;

        case "shotUpdated":
          pushLocalShotUpdate(event.payload?.shot || { id: event.payload?.id }, event.payload?.patch || {})
            .catch((e) => {
              log(`Local sync unexpected failure: ${e.message}`);
              recordLocalSyncStatus(event.payload?.id, null, "error", e.message);
            });
          break;
      }
    },
  };
}
