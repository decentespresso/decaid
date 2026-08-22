/* shot-upload.reaplugin
 *
 * Uploads finished espresso shots to the user's Decent account at
 * decentespresso.com (POST support/api/shot_upload) through the authenticated
 * Decent proxy, reusing the account the user is already logged into. The proxy
 * attaches the account credentials in Dart and never exposes them to plugin JS;
 * the server verifies the account and that the connected machine's serial
 * belongs to it, then stores the shot.
 *
 * Opt-in: AutoUpload defaults to FALSE, so nothing is uploaded until the user
 * turns it on. (Beta stance. Post-beta, logging into the Decent account will
 * itself serve as opt-in consent and AutoUpload will default to true.)
 *
 * The upload binds to the exact persisted shot via the `shotStored` event (fired
 * with the shot id after persistence), so there is no timer/`/shots/latest`
 * race, and machine identity is captured at completion time.
 *
 * Backlog drain (DrainHistory, also opt-in): shots recorded before the plugin was
 * enabled -- including history imported from the de1app -- are uploaded by a paced
 * background pass. It runs only while the machine is idle/asleep, one shot at a
 * time with a delay between them, so a first run over a long history never
 * arrives as a burst. The ledger is the shot itself: `uploadShot` stamps
 * annotations.extras.uploaded_to_decent, the list endpoint returns that field, so
 * a re-run skips what is already up and nothing extra has to be persisted or kept
 * in sync. Uploads are idempotent server-side (INSERT OR REPLACE on the shot id),
 * so a shot uploaded twice is harmless.
 *
 * Contract: must define createPlugin(host) returning {id, version, onLoad,
 * onUnload, onEvent}.
 */

function createPlugin(host) {
  "use strict";

  const NS = "shot-upload.reaplugin";
  const VERSION = "0.2.0";
  const LOCAL_API_URL = "http://localhost:8080/api/v1";
  const UPLOAD_PATH = "support/api/shot_upload"; // exact allowlisted proxy write path
  const RETRIES = 3;
  const RETRY_DELAY_MS = 2000;

  // Backlog drain tuning. The delay is the whole point: a first run may be
  // hundreds of shots, and each upload costs the server a git dedup check.
  const DRAIN_PAGE = 100;              // max the list endpoint allows
  const DRAIN_DELAY_MS = 2000;         // between two uploads
  const DRAIN_BUSY_RECHECK_MS = 30000; // machine in use -> look again later
  const DRAIN_BUSY_MAX_WAITS = 40;     // ~20 min of waiting, then give up this pass
  const DRAIN_MAX_ATTEMPTS = 3;        // per shot, across passes, before it is parked
  const DRAIN_BACKOFF_MS = 5000;       // doubled per attempt
  // Draining while the machine is brewing would compete with live use.
  const DRAIN_IDLE_STATES = ["idle", "schedIdle", "sleeping"];

  let isUploading = false;
  let decaidVersion = null;

  const state = {
    autoUpload: false, // opt-in; see header
    drainHistory: false, // opt-in; see header
    lengthThreshold: 5,
    lastUploadedShot: null,
    lastResult: null,
  };

  // Drain bookkeeping. `failed` is persisted (id -> attempts) so a shot the
  // server keeps rejecting is not retried forever across restarts; `skipped` is
  // per-session only, just to stop repeat passes re-fetching known-short shots.
  const drain = {
    running: false,
    stop: false,
    failed: {},
    skipped: {},
    // Uploaded during THIS run. The stamp written by uploadShot is the durable
    // ledger, but it is best-effort: if that PUT fails the shot still looks
    // pending, and without this a repeat pass would upload it again and the
    // "repeat until a pass achieves nothing" rule would never terminate.
    done: {},
    counters: { scanned: 0, uploaded: 0, skipped: 0, failed: 0 },
    lastError: null,
    lastRunAt: null,
  };

  function log(msg) { try { host.log(`[shot-upload] ${msg}`); } catch (e) {} }

  async function fetchLocal(path) {
    const res = await fetch(`${LOCAL_API_URL}${path}`);
    if (!res.ok) { log(`local ${path} -> ${res.status}`); return null; }
    return await res.json();
  }

  // Mark the stored shot as uploaded, mirroring the de1app plugin: write
  // `uploaded_to_decent <clock seconds>` into the shot's annotations.extras so
  // the record itself records that it was uploaded (deep-merged by the app's
  // PUT /shots/<id> handler). Best-effort -- never fails the upload.
  async function markUploaded(shotId) {
    try {
      const seconds = Math.floor(Date.now() / 1000);
      const res = await fetch(`${LOCAL_API_URL}/shots/${shotId}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ annotations: { extras: { uploaded_to_decent: seconds } } }),
      });
      if (!res || !res.ok) log(`mark ${shotId} uploaded -> HTTP ${res && res.status}`);
    } catch (e) {
      log(`could not mark ${shotId} uploaded: ${e.message}`);
    }
  }

  // A shot pulled on a simulated DE1 is not a real extraction and must never
  // reach the account. Decaid does not record which device a shot came from --
  // the serial is stamped at upload time from whatever is connected -- so the
  // only honest moment to judge a shot is while that machine is still attached.
  // Hence: refuse at upload time, and write a permanent marker on the shot so a
  // later drain, with a real machine connected, cannot misattribute it.
  // MOCK_DE1_SERIAL overrides the mock's serial and is the deliberate escape
  // hatch for end-to-end testing against a local server; such a build is opting
  // in and is not caught here.
  const isMockSerial = (serial) => /^mock/i.test(String(serial || ""));

  async function markSkipped(shotId, reason) {
    try {
      const res = await fetch(`${LOCAL_API_URL}/shots/${shotId}`, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ annotations: { extras: { upload_skipped: reason } } }),
      });
      if (!res || !res.ok) log(`mark ${shotId} skipped -> HTTP ${res && res.status}`);
    } catch (e) {
      log(`could not mark ${shotId} skipped: ${e.message}`);
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

  // Inject machine identity (serial not carried in the shot JSON) + provenance,
  // populated from the actual /machine/info fields (firmware = `version`).
  async function withMachine(shot) {
    const info = await fetchLocal("/machine/info");
    const serial = info && info.serialNumber;
    if (!serial) return null;
    if (isMockSerial(serial)) {
      const e = new Error(`simulated machine (${serial})`);
      e.mock = true;
      throw e;
    }
    shot.machine = { serialNumber: String(serial) };
    if (info.version) shot.machine.firmwareVersion = String(info.version);
    if (info.model) shot.machine.model = String(info.model);
    shot.app = { name: "decaid", version: await getDecaidVersion(), sourceFormat: "decaid" };
    shot.schemaVersion = 1;
    return shot;
  }

  // POST the shot through the authenticated Decent proxy (reuses account login).
  async function postShot(shot) {
    const body = JSON.stringify(shot);
    let lastErr = null;
    for (let i = 0; i < RETRIES; i++) {
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
        // 4xx (not logged in / not your machine / bad shot) -> don't retry
        if (status >= 400 && status < 500) {
          throw new Error(`HTTP ${status}: ${text}`);
        }
        lastErr = new Error(`HTTP ${status}: ${text}`);
      } catch (e) {
        lastErr = e;
        if (String(e.message).indexOf("HTTP 4") === 0) throw e;
      }
      if (i < RETRIES - 1) await new Promise(r => setTimeout(r, RETRY_DELAY_MS));
    }
    throw lastErr || new Error("upload failed");
  }

  // Upload one stored shot by id. Throws on failure (so callers can report
  // status); marks e.skipped=true for a too-short shot. Returns the server result.
  async function uploadShot(shotId) {
    const full = await fetchLocal(`/shots/${shotId}`);
    if (!full || !full.id) throw new Error(`shot ${shotId} not found`);

    const dur = shotDuration(full);
    if (dur < state.lengthThreshold) {
      const e = new Error(`shot too short (${dur.toFixed(1)}s < ${state.lengthThreshold}s)`);
      e.skipped = true;
      throw e;
    }

    const payload = await withMachine(full);
    if (!payload) throw new Error("no machine serial available");

    const result = await postShot(payload);
    state.lastUploadedShot = full.id;
    state.lastResult = result;
    host.storage({ type: "write", key: "lastUploadedShot", data: full.id });
    await markUploaded(full.id);
    host.emit("shotUploaded", { shotId: full.id, result: result, timestamp: Date.now() });
    return result;
  }

  // Auto path: fire-and-forget with dedup + error handling (never throws).
  async function autoUpload(shotId) {
    if (isUploading) return;
    if (shotId && shotId === state.lastUploadedShot) { log(`shot ${shotId} already uploaded`); return; }
    isUploading = true;
    try {
      const r = await uploadShot(shotId);
      log(`uploaded ${shotId} -> ${r && r.profile_ref ? r.profile_ref : "ok"}`);
    } catch (e) {
      if (e.mock) { log(`not uploading ${shotId}: ${e.message}`); await markSkipped(shotId, "mock-device"); }
      else if (e.skipped) { log(`skipped ${shotId}: ${e.message}`); }
      else { log(`error uploading ${shotId}: ${e.message}`); host.emit("uploadError", { shotId: shotId, error: e.message, timestamp: Date.now() }); }
    } finally {
      isUploading = false;
    }
  }

  // ---- backlog drain -------------------------------------------------------

  const sleep = (ms) => new Promise(r => setTimeout(r, ms));

  // Conservative: anything we cannot read counts as "not idle", so a drain never
  // competes with a shot in progress just because the state call failed.
  async function machineIsIdle() {
    try {
      const snap = await fetchLocal("/machine/state");
      const st = snap && snap.state && snap.state.state;
      return DRAIN_IDLE_STATES.indexOf(st) >= 0;
    } catch (e) {
      return false;
    }
  }

  const shotExtras = (shot) => {
    const ann = shot && shot.annotations;
    return (ann && ann.extras) || {};
  };
  const uploadedStamp = (shot) => shotExtras(shot).uploaded_to_decent;
  const skippedMark = (shot) => shotExtras(shot).upload_skipped;

  // One pass over the local history, oldest first. The list endpoint omits
  // measurements, so this is cheap even with thousands of shots, and it carries
  // annotations.extras -- the upload stamp -- so nothing has to be fetched to
  // decide whether a shot still needs uploading.
  async function listCandidates() {
    const out = [];
    let offset = 0;
    for (;;) {
      const page = await fetchLocal(`/shots?limit=${DRAIN_PAGE}&offset=${offset}`);
      const items = (page && page.items) || [];
      if (!items.length) break;
      for (const shot of items) {
        const id = shot && shot.id;
        if (!id) continue;
        if (uploadedStamp(shot)) continue;
        if (skippedMark(shot)) continue;
        if (drain.done[id]) continue;
        if (drain.skipped[id]) continue;
        if ((drain.failed[id] || 0) >= DRAIN_MAX_ATTEMPTS) continue;
        out.push(id);
      }
      offset += items.length;
      const total = page && page.total;
      if (typeof total === "number" && offset >= total) break;
      if (items.length < DRAIN_PAGE) break;
    }
    // The list is newest-first; upload oldest-first so history fills in order.
    return out.reverse();
  }

  // Wait for the machine to go idle, giving up after a bounded wait so a pass
  // cannot pin itself open forever on a machine that is in use all afternoon.
  async function waitForIdle() {
    for (let waited = 0; waited < DRAIN_BUSY_MAX_WAITS; waited++) {
      if (drain.stop || !state.drainHistory) return false;
      if (await machineIsIdle()) return true;
      await sleep(DRAIN_BUSY_RECHECK_MS);
    }
    return false;
  }

  // Upload every not-yet-uploaded shot, paced. Returns how many went up, so the
  // caller can repeat until a pass achieves nothing (offset paging is unstable
  // if a shot is recorded mid-pass, and a repeat pass costs one list call).
  async function drainOnce() {
    const ids = await listCandidates();
    drain.counters.scanned += ids.length;
    let uploaded = 0;
    for (const id of ids) {
      if (drain.stop || !state.drainHistory) break;
      if (!(await waitForIdle())) break;
      if (isUploading) { await sleep(DRAIN_DELAY_MS); continue; }
      isUploading = true;
      try {
        await uploadShot(id);
        drain.done[id] = true;
        uploaded++;
        drain.counters.uploaded++;
        delete drain.failed[id];
        log(`drain uploaded ${id}`);
      } catch (e) {
        if (e.mock) {
          await markSkipped(id, "mock-device");
          drain.skipped[id] = true;
          drain.counters.skipped++;
        } else if (e.skipped) {
          // Too short to be a shot (a flush): not a failure, but remember it so
          // later passes in this run do not fetch it again.
          drain.skipped[id] = true;
          drain.counters.skipped++;
        } else if (String(e.message).indexOf("HTTP 4") >= 0) {
          // Rejected by the server (not logged in, not your machine, bad shot):
          // retrying cannot help, so park it immediately.
          drain.failed[id] = DRAIN_MAX_ATTEMPTS;
          drain.counters.failed++;
          drain.lastError = e.message;
          log(`drain gave up on ${id}: ${e.message}`);
        } else {
          const attempts = (drain.failed[id] || 0) + 1;
          drain.failed[id] = attempts;
          drain.lastError = e.message;
          log(`drain failed ${id} (attempt ${attempts}): ${e.message}`);
          if (attempts >= DRAIN_MAX_ATTEMPTS) drain.counters.failed++;
          await sleep(DRAIN_BACKOFF_MS * Math.pow(2, attempts - 1));
        }
      } finally {
        isUploading = false;
      }
      persistFailed();
      await sleep(DRAIN_DELAY_MS);
    }
    return uploaded;
  }

  function persistFailed() {
    try { host.storage({ type: "write", key: "drainFailed", data: JSON.stringify(drain.failed) }); } catch (e) {}
  }

  async function startDrain(reason) {
    if (drain.running || !state.drainHistory) return;
    // Nothing identifies the machine these shots belong to if none is connected,
    // and the server checks that serial against the account, so do not even scan.
    const info = await fetchLocal("/machine/info");
    if (!info || !info.serialNumber) { log("drain skipped: no machine connected"); return; }
    // Refuse wholesale rather than walk the backlog: with a simulator attached
    // every upload would be attributed to it, and shots recorded earlier on the
    // real machine are indistinguishable from the simulator's own.
    if (isMockSerial(info.serialNumber)) { log(`drain skipped: simulated machine (${info.serialNumber})`); return; }
    drain.running = true;
    drain.stop = false;
    drain.done = {};
    drain.lastRunAt = Date.now();
    log(`drain started (${reason})`);
    try {
      for (;;) {
        const n = await drainOnce();
        if (n === 0) break;
      }
      log(`drain finished (uploaded ${drain.counters.uploaded}, skipped ${drain.counters.skipped}, failed ${drain.counters.failed})`);
    } catch (e) {
      drain.lastError = e.message;
      log(`drain aborted: ${e.message}`);
    } finally {
      drain.running = false;
    }
  }

  function applySettings(settings) {
    if (!settings) return;
    // Opt-in: default OFF unless the user explicitly enabled it.
    state.autoUpload = settings.AutoUpload === true;
    state.drainHistory = settings.DrainHistory === true;
    state.lengthThreshold = settings.LengthThreshold !== undefined ? settings.LengthThreshold : 5;
  }

  function jsonResponse(status, obj) {
    return { status: status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(obj) };
  }

  return {
    id: NS,
    version: VERSION,

    onLoad(settings) {
      applySettings(settings);
      // Storage reads are event-based: this triggers a `storageRead` event,
      // handled in onEvent, that restores lastUploadedShot.
      try { host.storage({ type: "read", key: "lastUploadedShot" }); } catch (e) {}
      try { host.storage({ type: "read", key: "drainFailed" }); } catch (e) {}
      log(`loaded (autoUpload ${state.autoUpload}, drainHistory ${state.drainHistory})`);
      if (state.drainHistory) startDrain("load");
    },

    onUnload() { drain.stop = true; },

    onEvent(event) {
      switch (event.name) {
        case "shotStored": {
          const id = event.payload && event.payload.id;
          if (id && state.autoUpload) autoUpload(id);
          // A finished shot means the machine is awake and probably idle again:
          // a good moment to catch up on anything the backlog still owes.
          if (state.drainHistory) startDrain("shotStored");
          break;
        }
        case "storageRead":
          if (event.payload && event.payload.key === "lastUploadedShot") {
            state.lastUploadedShot = event.payload.value || null;
          }
          if (event.payload && event.payload.key === "drainFailed") {
            try { drain.failed = JSON.parse(event.payload.value || "{}") || {}; } catch (e) { drain.failed = {}; }
          }
          break;
        case "settingsUpdated": {
          const wasDraining = state.drainHistory;
          applySettings(event.payload);
          // Turning it off stops the run in progress at the next shot boundary.
          if (!state.drainHistory) drain.stop = true;
          else if (!wasDraining) startDrain("enabled");
          break;
        }
      }
    },

    // Control endpoints. GET status; POST upload (uploads the latest shot, which
    // belongs to the currently-connected machine — avoids misattributing an
    // arbitrary historical id to the wrong machine).
    async __httpRequestHandler(request) {
      const endpoint = request && request.endpoint;
      if (endpoint === "status") {
        return jsonResponse(200, {
          autoUpload: state.autoUpload,
          lastUploaded: state.lastUploadedShot,
          lastResult: state.lastResult,
          drainHistory: state.drainHistory,
          drainRunning: drain.running,
          drainCounters: drain.counters,
          drainParked: Object.keys(drain.failed).filter(k => drain.failed[k] >= DRAIN_MAX_ATTEMPTS).length,
          drainLastError: drain.lastError,
          drainLastRunAt: drain.lastRunAt,
        });
      }
      if (endpoint === "drain") {
        if (!state.drainHistory) return jsonResponse(409, { ok: false, error: "DrainHistory is off" });
        if (drain.running) return jsonResponse(200, { ok: true, alreadyRunning: true, counters: drain.counters });
        startDrain("manual");   // deliberately not awaited: this can run for hours
        return jsonResponse(202, { ok: true, started: true });
      }
      if (endpoint === "upload") {
        try {
          const latest = await fetchLocal("/shots/latest");
          if (!latest || !latest.id) return jsonResponse(404, { ok: false, error: "no shot available" });
          const result = await uploadShot(latest.id);
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
