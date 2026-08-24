/* shot-upload.reaplugin
 *
 * Uploads finished espresso shots to the user's Decent account at
 * decentespresso.com (POST support/api/shot_upload) through the authenticated
 * Decent proxy, reusing the account the user is already logged into. The proxy
 * attaches the account credentials in Dart and never exposes them to plugin JS;
 * the server verifies the account and that the captured machine's serial
 * belongs to it, then stores the shot.
 *
 * Opt-in: AutoUpload defaults to FALSE, so nothing is uploaded until the user
 * turns it on. (Beta stance. Post-beta, logging into the Decent account will
 * itself serve as opt-in consent and AutoUpload will default to true.)
 *
 * The upload binds to the exact persisted shot via the `shotStored` event (fired
 * with the shot id after persistence), so there is no timer/`/shots/latest`
 * race, and machine identity is captured at shot start.
 *
 * Contract: must define createPlugin(host) returning {id, version, onLoad,
 * onUnload, onEvent}.
 */

function createPlugin(host) {
  "use strict";

  const NS = "shot-upload.reaplugin";
  const VERSION = "0.2.1";
  const LOCAL_API_URL = "http://localhost:8080/api/v1";
  const UPLOAD_PATH = "support/api/shot_upload"; // exact allowlisted proxy write path
  const RETRIES = 3;
  const RETRY_DELAY_MS = 2000;
  const RECONCILE_PAGE_SIZE = 20;
  const RECONCILE_PAGE_LIMIT = 5;
  const RECONCILE_BATCH_SIZE = 5;
  const RECONCILE_PERIOD_MS = 5 * 60 * 1000;
  const RECONCILE_RETRY_MS = 60 * 1000;
  const RECONCILE_CONTINUE_MS = 30 * 1000;
  const SAFE_MACHINE_STATES = new Set(["idle", "schedIdle", "sleeping"]);

  let isUploading = false;
  let isReconciling = false;
  let pendingLiveShotIds = [];
  const remotelyPostedShotIds = new Set();
  const permanentlyRejectedShotIds = new Set();
  let reconcileTimerId = null;
  let reconciliationPausedForConsent = false;
  let unloaded = false;
  let decaidVersion = null;

  const state = {
    autoUpload: false, // opt-in; see header
    lengthThreshold: 5,
    lastUploadedShot: null,
    lastResult: null,
    reconcileOffset: 0,
    machineState: null,
  };

  function log(msg) { try { host.log(`[shot-upload] ${msg}`); } catch (e) {} }

  async function fetchLocal(path) {
    const res = await fetch(`${LOCAL_API_URL}${path}`);
    if (!res.ok) { log(`local ${path} -> ${res.status}`); return null; }
    return await res.json();
  }

  async function updateShotExtras(shotId, extras) {
    const res = await fetch(`${LOCAL_API_URL}/shots/${shotId}`, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ annotations: { extras: extras } }),
    });
    if (!res || !res.ok) throw new Error(`mark ${shotId} -> HTTP ${res && res.status}`);
  }

  async function markUploaded(shotId) {
    try {
      await updateShotExtras(shotId, {
        uploaded_to_decent: Math.floor(Date.now() / 1000),
        decent_upload_rejected: null,
      });
    } catch (e) {
      log(`could not mark ${shotId} uploaded: ${e.message}`);
    }
  }

  async function markRejected(shotId, error) {
    try {
      await updateShotExtras(shotId, {
        decent_upload_rejected: {
          status: error.status,
          timestamp: Math.floor(Date.now() / 1000),
        },
      });
    } catch (e) {
      log(`could not mark ${shotId} rejected: ${e.message}`);
    }
  }

  // Decaid app version (for provenance), cached.
  async function getDecaidVersion() {
    if (decaidVersion) return decaidVersion;
    const info = await fetchLocal("/info");
    decaidVersion = (info && (info.version || info.fullVersion)) || "unknown";
    return decaidVersion;
  }

  // seconds between first and last measurement
  function shotDuration(shot) {
    const m = shot && shot.measurements;
    if (!m || m.length < 2) return 0;
    const t0 = Date.parse(m[0].machine.timestamp);
    const t1 = Date.parse(m[m.length - 1].machine.timestamp);
    return isNaN(t0) || isNaN(t1) ? 0 : (t1 - t0) / 1000;
  }

  function capturedMachine(shot) {
    const machine = shot && shot.workflow && shot.workflow.machine;
    if (!machine || !machine.serialNumber || /^mock/i.test(String(machine.serialNumber))) return null;
    return {
      serialNumber: String(machine.serialNumber),
      ...(machine.firmwareVersion ? { firmwareVersion: String(machine.firmwareVersion) } : {}),
      ...(machine.model ? { model: String(machine.model) } : {}),
    };
  }

  async function withMachine(shot, manualRetry) {
    const captured = shot && shot.workflow && shot.workflow.machine;
    let machine = capturedMachine(shot);
    if (captured && captured.serialNumber && !machine) return null;
    const hasProvenanceStatus = captured && Object.prototype.hasOwnProperty.call(captured, "provenanceStatus");
    if (hasProvenanceStatus) {
      if (captured.provenanceStatus === "captured" && !machine) return null;
      if (captured.provenanceStatus === "unavailable") {
        if (!manualRetry) return null;
        machine = null;
      } else if (captured.provenanceStatus !== "captured") {
        return null;
      }
    }
    if (!machine) {
      const current = await fetchLocal("/machine/info");
      if (!current || !current.serialNumber || /^mock/i.test(String(current.serialNumber))) return null;
      machine = {
        serialNumber: String(current.serialNumber),
        ...(current.version ? { firmwareVersion: String(current.version) } : {}),
        ...(current.model ? { model: String(current.model) } : {}),
      };
    }
    if (!machine) return null;
    return {
      ...shot,
      machine: machine,
      app: { name: "decaid", version: await getDecaidVersion(), sourceFormat: "decaid" },
      schemaVersion: 1,
    };
  }

  // POST the shot through the authenticated Decent proxy (reuses account login).
  async function postShot(shot) {
    const body = JSON.stringify(shot);
    let lastErr = null;
    for (let i = 0; i < RETRIES; i++) {
      if (unloaded || ((isUploading || isReconciling) && !state.autoUpload)) {
        throw skipped("automatic upload stopped");
      }
      if (isReconciling && !reconciliationIsSafe()) {
        throw skipped("machine is active");
      }
      try {
        const res = await host.decentProxy(UPLOAD_PATH, {
          method: "POST",
          body: body,
          contentType: "application/json",
        });
        const status = res && res.status;
        const text = (res && res.body) || "";
        if (status >= 200 && status < 300) {
          try { return JSON.parse(text); } catch (e) { return { ok: true }; }
        }
        const error = new Error(`HTTP ${status}: ${text}`);
        error.status = status;
        error.permanent = status >= 400 && status < 500 && status !== 401 && status !== 403 && status !== 408 && status !== 429;
        if (error.permanent) {
          throw error;
        }
        lastErr = error;
      } catch (e) {
        lastErr = e;
        if (e.code === "account_consent_denied") {
          e.consent = true;
          throw e;
        }
        if (e.permanent) throw e;
      }
      if (i < RETRIES - 1) await new Promise(r => setTimeout(r, RETRY_DELAY_MS * (i + 1)));
    }
    throw lastErr || new Error("upload failed");
  }

  function extrasFor(shot) {
    return shot && shot.annotations && shot.annotations.extras || {};
  }

  function skipped(message) {
    const error = new Error(message);
    error.skipped = true;
    return error;
  }

  async function uploadShot(shotId, manualRetry) {
    if (remotelyPostedShotIds.has(shotId)) throw skipped(`shot ${shotId} already uploaded`);
    if (!manualRetry && permanentlyRejectedShotIds.has(shotId)) throw skipped(`shot ${shotId} was rejected`);
    const full = await fetchLocal(`/shots/${shotId}`);
    if (!full || !full.id) throw skipped(`shot ${shotId} not found`);

    const extras = extrasFor(full);
    if (extras.uploaded_to_decent) throw skipped(`shot ${shotId} already uploaded`);
    if (extras.decent_upload_rejected && !manualRetry) throw skipped(`shot ${shotId} was rejected`);
    if (extras.upload_skipped === "mock-device") throw skipped(`shot ${shotId} came from a mock device`);

    const dur = shotDuration(full);
    if (dur < state.lengthThreshold) {
      throw skipped(`shot too short (${dur.toFixed(1)}s < ${state.lengthThreshold}s)`);
    }

    const payload = await withMachine(full, manualRetry);
    if (!payload) throw skipped("no real machine serial available");

    let result;
    try {
      result = await postShot(payload);
    } catch (e) {
      if (e.permanent) permanentlyRejectedShotIds.add(full.id);
      throw e;
    }
    remotelyPostedShotIds.add(full.id);
    await markUploaded(full.id);
    state.lastUploadedShot = full.id;
    state.lastResult = result;
    host.storage({ type: "write", key: "lastUploadedShot", data: full.id });
    host.emit("shotUploaded", { shotId: full.id, result: result, timestamp: Date.now() });
    return result;
  }

  function queueLiveShot(shotId) {
    if (!pendingLiveShotIds.includes(shotId)) {
      pendingLiveShotIds = [...pendingLiveShotIds, shotId];
    }
  }

  function takeLiveShot() {
    const shotId = pendingLiveShotIds[0];
    pendingLiveShotIds = pendingLiveShotIds.slice(1);
    return shotId;
  }

  async function uploadAutomatically(shotId) {
    if (shotId && shotId === state.lastUploadedShot) {
      log(`shot ${shotId} already uploaded`);
      return;
    }
    try {
      const r = await uploadShot(shotId, false);
      log(`uploaded ${shotId} -> ${r && r.profile_ref ? r.profile_ref : "ok"}`);
    } catch (e) {
      if (e.skipped) { log(`skipped ${shotId}: ${e.message}`); }
      else {
        if (e.permanent) {
          await markRejected(shotId, e);
        }
        log(`error uploading ${shotId}: ${e.message}`);
        host.emit("uploadError", { shotId: shotId, error: e.message, timestamp: Date.now() });
        if (e.consent) reconciliationPausedForConsent = true;
        else scheduleReconcile(RECONCILE_RETRY_MS);
      }
    }
  }

  async function autoUpload(shotId) {
    if (!state.autoUpload || reconciliationPausedForConsent || unloaded) return;
    if (isUploading || isReconciling) {
      queueLiveShot(shotId);
      return;
    }
    isUploading = true;
    try {
      await uploadAutomatically(shotId);
    } finally {
      isUploading = false;
      const nextShotId = takeLiveShot();
      if (nextShotId) autoUpload(nextShotId);
    }
  }

  function applySettings(settings) {
    if (!settings) return;
    // Opt-in: default OFF unless the user explicitly enabled it.
    state.autoUpload = settings.AutoUpload === true;
    state.lengthThreshold = settings.LengthThreshold !== undefined ? settings.LengthThreshold : 5;
  }

  function scheduleReconcile(delay) {
    if (!state.autoUpload || reconciliationPausedForConsent || unloaded) return;
    if (reconcileTimerId !== null) clearTimeout(reconcileTimerId);
    reconcileTimerId = setTimeout(() => {
      reconcileTimerId = null;
      reconcile();
    }, delay);
  }

  function currentMachineState(snapshot) {
    return snapshot && snapshot.state && snapshot.state.state || null;
  }

  function reconciliationIsSafe() {
    return SAFE_MACHINE_STATES.has(state.machineState);
  }

  async function confirmReconciliationIsSafe() {
    const snapshot = await fetchLocal("/machine/state");
    state.machineState = currentMachineState(snapshot);
    return reconciliationIsSafe();
  }

  function reconcileCandidate(shot) {
    const extras = extrasFor(shot);
    const captured = shot && shot.workflow && shot.workflow.machine;
    const hasProvenanceStatus = captured && Object.prototype.hasOwnProperty.call(captured, "provenanceStatus");
    return !remotelyPostedShotIds.has(shot.id) &&
      !permanentlyRejectedShotIds.has(shot.id) &&
      !extras.uploaded_to_decent &&
      !extras.decent_upload_rejected &&
      extras.upload_skipped !== "mock-device" &&
      (hasProvenanceStatus
        ? captured.provenanceStatus === "captured" && capturedMachine(shot) !== null
        : !captured || !captured.serialNumber || capturedMachine(shot) !== null);
  }

  function setReconcileOffset(offset) {
    state.reconcileOffset = offset;
    host.storage({ type: "write", key: "reconcileOffset", data: offset });
  }

  async function reconcile() {
    if (!state.autoUpload || reconciliationPausedForConsent || unloaded) return;
    if (isUploading || isReconciling) {
      scheduleReconcile(RECONCILE_RETRY_MS);
      return;
    }
    isReconciling = true;
    let nextDelay = RECONCILE_PERIOD_MS;
    try {
      if (!await confirmReconciliationIsSafe()) return;
      let pages = 0;
      let attempts = 0;
      while (pages < RECONCILE_PAGE_LIMIT && attempts < RECONCILE_BATCH_SIZE && state.autoUpload && !reconciliationPausedForConsent && !unloaded && reconciliationIsSafe()) {
        const page = await fetchLocal(`/shots?limit=${RECONCILE_PAGE_SIZE}&offset=${state.reconcileOffset}&order=desc`);
        if (!page || !Array.isArray(page.items)) throw new Error("could not list local shots");
        if (page.items.length === 0 || state.reconcileOffset >= page.total) {
          setReconcileOffset(0);
          break;
        }
        let scanned = 0;
        for (const shot of page.items) {
          if (!state.autoUpload || reconciliationPausedForConsent || unloaded || !reconciliationIsSafe() || attempts >= RECONCILE_BATCH_SIZE) break;
          while (pendingLiveShotIds.length > 0 && attempts < RECONCILE_BATCH_SIZE && !reconciliationPausedForConsent) {
            await uploadAutomatically(takeLiveShot());
            attempts++;
          }
          if (reconciliationPausedForConsent || attempts >= RECONCILE_BATCH_SIZE) break;
          scanned++;
          if (!reconcileCandidate(shot)) continue;
          try {
            await uploadShot(shot.id, false);
            attempts++;
          } catch (e) {
            if (e.skipped) continue;
            if (!e.permanent) throw e;
            await markRejected(shot.id, e);
            attempts++;
            log(`shot ${shot.id} rejected: ${e.message}`);
          }
        }
        setReconcileOffset(state.reconcileOffset + scanned);
        pages++;
        if (state.reconcileOffset >= page.total) {
          setReconcileOffset(0);
          break;
        }
      }
      if (attempts >= RECONCILE_BATCH_SIZE) nextDelay = RECONCILE_CONTINUE_MS;
    } catch (e) {
      log(`reconciliation paused: ${e.message}`);
      if (e.consent) reconciliationPausedForConsent = true;
      nextDelay = e.consent ? null : RECONCILE_RETRY_MS;
    } finally {
      isReconciling = false;
      const nextShotId = reconciliationPausedForConsent ? null : takeLiveShot();
      if (nextShotId) {
        autoUpload(nextShotId);
        scheduleReconcile(RECONCILE_CONTINUE_MS);
      } else if (nextDelay !== null) {
        scheduleReconcile(nextDelay);
      }
    }
  }

  function jsonResponse(status, obj) {
    return { status: status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(obj) };
  }

  return {
    id: NS,
    version: VERSION,

    onLoad(settings) {
      unloaded = false;
      reconciliationPausedForConsent = false;
      applySettings(settings);
      // Storage reads are event-based: this triggers a `storageRead` event,
      // handled in onEvent, that restores lastUploadedShot.
      try { host.storage({ type: "read", key: "lastUploadedShot" }); } catch (e) {}
      try { host.storage({ type: "read", key: "reconcileOffset" }); } catch (e) {}
      log(`loaded (autoUpload ${state.autoUpload})`);
      scheduleReconcile(1000);
    },

    onUnload() {
      unloaded = true;
      if (reconcileTimerId !== null) clearTimeout(reconcileTimerId);
      reconcileTimerId = null;
      pendingLiveShotIds = [];
    },

    onEvent(event) {
      switch (event.name) {
        case "shotStored": {
          const id = event.payload && event.payload.id;
          if (id && state.autoUpload) autoUpload(id);
          break;
        }
        case "storageRead":
          if (event.payload && event.payload.key === "lastUploadedShot") {
            state.lastUploadedShot = event.payload.value || null;
          }
          if (event.payload && event.payload.key === "reconcileOffset") {
            const offset = Number(event.payload.value);
            state.reconcileOffset = Number.isFinite(offset) && offset >= 0 ? Math.trunc(offset) : 0;
          }
          break;
        case "stateUpdate": {
          const previousMachineState = state.machineState;
          state.machineState = currentMachineState(event.payload);
          if (state.machineState !== previousMachineState && reconciliationIsSafe()) {
            scheduleReconcile(0);
          }
          break;
        }
        case "settingsUpdated": {
          const wasEnabled = state.autoUpload;
          applySettings(event.payload);
          if (!state.autoUpload) {
            if (reconcileTimerId !== null) clearTimeout(reconcileTimerId);
            reconcileTimerId = null;
            pendingLiveShotIds = [];
          } else if (state.autoUpload) {
            if (!wasEnabled) {
              reconciliationPausedForConsent = false;
              setReconcileOffset(0);
            }
            scheduleReconcile(0);
          }
          break;
        }
      }
    },

    // Control endpoints. GET status; POST upload of the latest eligible shot.
    async __httpRequestHandler(request) {
      const endpoint = request && request.endpoint;
      if (endpoint === "status") {
        return jsonResponse(200, {
          autoUpload: state.autoUpload,
          lastUploaded: state.lastUploadedShot,
          lastResult: state.lastResult,
        });
      }
      if (endpoint === "upload") {
        try {
          const latest = await fetchLocal("/shots/latest");
          if (!latest || !latest.id) return jsonResponse(404, { ok: false, error: "no shot available" });
          const result = await uploadShot(latest.id, true);
          return jsonResponse(200, { ok: true, id: latest.id, result: result });
        } catch (e) {
          if (e.skipped) return jsonResponse(200, { ok: false, skipped: true, error: e.message });
          return jsonResponse(502, { ok: false, error: e.message });
        }
      }
      return jsonResponse(404, { error: "unknown endpoint" });
    },
  };
}
