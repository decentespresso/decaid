/* time-to-ready.reaplugin
 *
 * Contract:
 * - This file must define a function named 'createPlugin'
 * - Factory function receives 'host' object as parameter
 * - Returns a plugin object with onLoad, onUnload, onEvent methods
 */

// Standard factory function - receives host object from PluginManager
function createPlugin(host) {
  "use strict";

  const RATE_WINDOW_SECONDS = 18;
  const MIN_RATE_SAMPLES = 8;
  const MIN_WARMED_CELSIUS = 5;
  const SESSION_AGE_FALLBACK_SECONDS = 45;
  const MIN_FALLBACK_WARMED_CELSIUS = 1;
  const RATE_SPAN_STEP_SECONDS = 6;
  const MIN_INTERVAL_RISE_CELSIUS = 0.1;
  const CONFIDENT_SPAN_RISE_CELSIUS = 3;
  const MACHINE_INFO_URL = "http://127.0.0.1:8080/api/v1/machine/info";
  const MACHINE_INFO_RETRY_MS = 30000;
  const MACHINE_INFO_ATTEMPTS = 5;
  const MACHINE_INFO_REFRESH_MS = 60000;
  const STALL_WINDOW_SECONDS = 60;
  const STALL_GAIN_CELSIUS = 0.5;
  const MIN_CONTINUING_WARMED_CELSIUS = 0.2;
  const DECELERATION_TRIGGER = 0.8;
  const MAX_DECELERATION_FACTOR = 1.4;

  function createState() {
    return {
      ticksSeen: 0,
      loadedAt: null,
      heatStartTime: null,
      heatStartTemp: null,
      maximumRemainingTimeSeconds: null,
      peakRate: null,
      lastEstimation: null,
      lastMachineState: null,
      lastTargetTemp: null,
      temperatureSamples: [],
      stallSamples: [],
      published: false,
    };
  }

  let state = createState();
  let pluginLoaded = false;
  let machineModel = null;
  let modelAttempts = 0;
  let modelRequestedAt = 0;
  let modelGeneration = 0;
  let modelRetry = null;

  function cancelModelRetry() {
    if (modelRetry != null && typeof clearTimeout === "function") {
      clearTimeout(modelRetry);
    }
    modelRetry = null;
  }

  function scheduleModelRetry() {
    if (!pluginLoaded || modelAttempts >= MACHINE_INFO_ATTEMPTS) return;
    if (typeof setTimeout !== "function") return;
    cancelModelRetry();
    modelRetry = setTimeout(() => {
      modelRetry = null;
      detectMachineModel();
    }, MACHINE_INFO_RETRY_MS);
  }

  function applyMachineModel(model) {
    if (model === machineModel) return;
    machineModel = model;
    resetHeatStart();
    if (model) log(`Machine model: ${model}`);
  }

  function detectMachineModel() {
    if (!pluginLoaded) return;
    if (typeof fetch !== "function") {
      log("fetch unavailable; estimating without a machine model");
      return;
    }
    modelAttempts++;
    modelRequestedAt = Date.now();
    const generation = modelGeneration;
    const stale = () => !pluginLoaded || generation !== modelGeneration;
    try {
      Promise.resolve(fetch(MACHINE_INFO_URL))
        .then((response) => {
          if (!response || response.ok !== true) {
            throw new Error(`machine info status ${response && response.status}`);
          }
          return response.json();
        })
        .then((info) => {
          if (stale()) return;
          const model = info && typeof info.model === "string"
            ? info.model.trim()
            : "";
          if (model === "") {
            applyMachineModel(null);
            scheduleModelRetry();
            return;
          }
          modelAttempts = 0;
          cancelModelRetry();
          applyMachineModel(model);
        })
        .catch((error) => {
          if (stale()) return;
          log(`Machine info fetch failed: ${error}`);
          applyMachineModel(null);
          scheduleModelRetry();
        });
    } catch (error) {
      if (stale()) return;
      log(`Machine info fetch threw: ${error}`);
      applyMachineModel(null);
      scheduleModelRetry();
    }
  }

  function refreshMachineModel(now) {
    if (!pluginLoaded) return;
    if (now - modelRequestedAt < MACHINE_INFO_REFRESH_MS) return;
    detectMachineModel();
  }

  function deceleratingMachine() {
    if (machineModel == null) return false;
    return !/bengle/i.test(machineModel);
  }

  function log(msg) {
    host.log(`[time-to-ready] ${msg}`);
  }

  function resetHeatStart() {
    state.heatStartTime = null;
    state.heatStartTemp = null;
    state.maximumRemainingTimeSeconds = null;
    state.peakRate = null;
    state.published = false;
    state.temperatureSamples = [];
    state.stallSamples = [];
  }

  function startHeatSession(now, temperature) {
    state.heatStartTime = now;
    state.heatStartTemp = temperature;
    state.maximumRemainingTimeSeconds = null;
    state.peakRate = null;
    state.published = false;
    state.temperatureSamples = [];
    state.stallSamples = [];
  }

  function recordSample(history, now, temperature, windowSeconds) {
    const cutoff = now - windowSeconds * 1000;
    const trimmed = history.filter((sample) => sample.timestamp >= cutoff);
    const lastSample = trimmed.at(-1);
    if (lastSample && lastSample.timestamp === now) {
      lastSample.temperature = temperature;
    } else {
      trimmed.push({ timestamp: now, temperature });
    }
    return trimmed;
  }

  function recordTemperature(now, temperature) {
    state.temperatureSamples = recordSample(
      state.temperatureSamples,
      now,
      temperature,
      RATE_WINDOW_SECONDS,
    );
    state.stallSamples = recordSample(
      state.stallSamples,
      now,
      temperature,
      STALL_WINDOW_SECONDS,
    );
  }

  function handleStateUpdate(payload) {
    state.ticksSeen++;

    const machineState = payload && payload.state && payload.state.state;
    if (payload == null || payload.groupTemperature == undefined ||
      payload.targetGroupTemperature == undefined) {
      if (machineState === 'sleeping') resetHeatStart();
      state.lastMachineState = machineState || null;
      log(`missing fields in ${JSON.stringify(payload)}`);
      return;
    }

    const currentTemp = payload.groupTemperature;
    const targetTemp = payload.targetGroupTemperature;
    const now = Date.now();

    refreshMachineModel(now);

    if (state.lastTargetTemp !== null && state.lastTargetTemp !== targetTemp) {
      resetHeatStart();
    }
    state.lastTargetTemp = targetTemp;

    if (machineState === 'sleeping') {
      resetHeatStart();
    } else if (currentTemp >= targetTemp) {
      resetHeatStart();
    } else if (machineState === 'ready') {
      startHeatSession(now, currentTemp);
    } else if (state.heatStartTime !== null &&
      currentTemp < state.heatStartTemp - 2) {
      resetHeatStart();
    }
    if (state.heatStartTime === null && machineState !== 'sleeping' &&
      currentTemp < targetTemp) {
      startHeatSession(now, currentTemp);
    }
    if (state.heatStartTime !== null && currentTemp < targetTemp) {
      recordTemperature(now, currentTemp);
    }

    const estimation = estimateRemainingTime(currentTemp, targetTemp, now);

    state.lastEstimation = estimation;
    state.lastMachineState = machineState || null;

    host.emit(
      "timeToReady",
      {
        ...estimation,
        currentTemp,
        targetTemp,
        timestamp: now,
      },
    );
  }

  function handleStorageRead(payload) {
    if (payload.key === "lastEstimation") {
      log(`Loaded last estimation from storage: ${JSON.stringify(payload.value)}`);
      if (payload.value) state.lastEstimation = payload.value;
    }
  }

  function handleStorageWrite(payload) {
    log(`Saved to storage: ${JSON.stringify(payload)}`);
  }

  function handleShutdown() {
    log("Shutdown requested");
  }

  function estimateRemainingTime(currentTemp, targetTemp, now) {
    if (currentTemp >= targetTemp) {
      return {
        remainingTimeMs: 0,
        heatingRate: 0,
        status: 'reached',
        message: 'Target temperature reached',
      };
    }

    const heatingRate = calculateRecentRate(now);
    if (heatingRate === null) {
      const stalled = state.heatStartTime !== null &&
        now - state.heatStartTime >= STALL_WINDOW_SECONDS * 1000 &&
        !isHeating(now, STALL_WINDOW_SECONDS);
      if (stalled) {
        state.published = false;
        state.maximumRemainingTimeSeconds = null;
      }
      return {
        remainingTimeMs: null,
        heatingRate: stalled ? 0 : null,
        status: stalled ? 'not_heating' : 'insufficient_data',
        message: stalled
          ? 'Temperature is stable or decreasing'
          : 'Collecting temperature data...',
      };
    }

    state.peakRate = state.peakRate === null
      ? heatingRate
      : Math.max(state.peakRate, heatingRate);

    const remaining = Math.max(targetTemp - currentTemp, 0);
    let effectiveRate = heatingRate;
    let decelerating = false;
    if (deceleratingMachine() && state.peakRate > 0 &&
      heatingRate < state.peakRate * DECELERATION_TRIGGER) {
      const factor = clamp(
        state.peakRate / heatingRate,
        1,
        MAX_DECELERATION_FACTOR,
      );
      effectiveRate = heatingRate / factor;
      decelerating = factor > 1;
    }
    const rawSeconds = remaining / effectiveRate;
    const estimatedSeconds = clamp(roundToTens(rawSeconds), 5, 300);

    if (state.maximumRemainingTimeSeconds === null || decelerating) {
      state.maximumRemainingTimeSeconds = estimatedSeconds;
    } else {
      state.maximumRemainingTimeSeconds = Math.min(
        state.maximumRemainingTimeSeconds,
        estimatedSeconds,
      );
    }

    state.published = true;
    const remainingTimeSeconds = state.maximumRemainingTimeSeconds;
    const remainingTimeMs = remainingTimeSeconds * 1000;
    return {
      remainingTimeMs,
      heatingRate,
      status: 'heating',
      message: `Estimated ${formatTime(remainingTimeMs)} remaining`,
      formattedTime: formatTime(remainingTimeMs),
    };
  }

  function calculateRecentRate(now) {
    const cutoff = now - RATE_WINDOW_SECONDS * 1000;
    state.temperatureSamples = state.temperatureSamples.filter(
      (sample) => sample.timestamp >= cutoff,
    );
    if (state.temperatureSamples.length < MIN_RATE_SAMPLES) return null;

    const last = state.temperatureSamples.at(-1);
    const warmed = last.temperature - state.temperatureSamples[0].temperature;
    const sessionSeconds =
      (last.timestamp - state.heatStartTime) / 1000;
    const established = warmed >= MIN_WARMED_CELSIUS ||
      (sessionSeconds >= SESSION_AGE_FALLBACK_SECONDS &&
        warmed >= MIN_FALLBACK_WARMED_CELSIUS);
    const continuing = state.published && warmed > MIN_CONTINUING_WARMED_CELSIUS;
    if (!established && !continuing) return null;

    let fallbackRate = null;
    for (let spanSeconds = RATE_SPAN_STEP_SECONDS;
      spanSeconds <= RATE_WINDOW_SECONDS;
      spanSeconds += RATE_SPAN_STEP_SECONDS) {
      let anchorIndex = state.temperatureSamples.findIndex(
        (sample) => sample.timestamp >= last.timestamp - spanSeconds * 1000,
      );
      if (anchorIndex < 0) continue;
      const spanStart = anchorIndex;
      while (anchorIndex + 1 < state.temperatureSamples.length &&
        state.temperatureSamples[anchorIndex + 1].temperature -
          state.temperatureSamples[spanStart].temperature <
            MIN_INTERVAL_RISE_CELSIUS) {
        anchorIndex++;
      }
      const anchor = state.temperatureSamples[anchorIndex];
      if (anchor === last) continue;
      const elapsedSeconds = (last.timestamp - anchor.timestamp) / 1000;
      if (elapsedSeconds <= 0) continue;
      const rise = last.temperature - anchor.temperature;
      const rate = rise / elapsedSeconds;
      if (rate <= 0) continue;
      if (rise >= CONFIDENT_SPAN_RISE_CELSIUS) return rate;
      fallbackRate = rate;
    }
    return fallbackRate;
  }

  function isHeating(now, spanSeconds) {
    const cutoff = now - spanSeconds * 1000;
    const window = state.stallSamples.filter(
      (sample) => sample.timestamp >= cutoff,
    );
    if (window.length < 2) return true;
    const coveredSeconds = (window.at(-1).timestamp - window[0].timestamp) / 1000;
    if (coveredSeconds < spanSeconds) return true;
    const gain = window.at(-1).temperature - window[0].temperature;
    return gain >= STALL_GAIN_CELSIUS;
  }

  function clamp(value, minimum, maximum) {
    return Math.min(Math.max(value, minimum), maximum);
  }

  function roundToTens(value) {
    return Math.round(value / 10) * 10;
  }

  function formatTime(ms) {
    if (ms === null || ms === undefined) return '--:--';

    const totalSeconds = Math.round(ms / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;

    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  }

  // Return the plugin object
  return {
    id: "time-to-ready.reaplugin",
    version: "1.0.0",

    onLoad(settings) {
      state.loadedAt = Date.now();
      pluginLoaded = true;
      modelAttempts = 0;
      detectMachineModel();

      log(`Loaded with settings: ${JSON.stringify(settings)}`);

      host.emit("plugin.loaded", {
        plugin: this.id,
        version: this.version,
        settings,
      });

      // Example: Load saved state from storage
      host.storage({
        type: "read",
        key: "lastEstimation",
        namespace: "time-to-ready.reaplugin",
      });
    },

    onUnload() {
      pluginLoaded = false;
      modelGeneration++;
      cancelModelRetry();
      log(`Unloaded after ${state.ticksSeen} ticks`);

      // Save last estimation to storage
      if (state.lastEstimation) {
        host.storage({
          type: "write",
          key: "lastEstimation",
          namespace: "time-to-ready.reaplugin",
          data: state.lastEstimation,
        });
      }

      state = createState();
    },

    onEvent(event) {
      if (!event || typeof event.name !== "string") return;

      switch (event.name) {
        case "stateUpdate":
          handleStateUpdate(event.payload);
          break;
        case "shutdown":
          handleShutdown();
          break;
        case "storageRead":
          handleStorageRead(event.payload);
          break;
        case "storageWrite":
          handleStorageWrite(event.payload);
          break;
        default:
          // Ignore unknown events (important for forward compatibility)
          break;
      }
    },
  };
}
