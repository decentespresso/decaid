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

  const MIN_WARMED_CELSIUS = 2;

  function createState() {
    return {
      ticksSeen: 0,
      loadedAt: null,
      heatStartTime: null,
      heatStartTemp: null,
      maximumRemainingTimeSeconds: null,
      lastEstimation: null,
      lastMachineState: null,
      lastTargetTemp: null,
    };
  }

  let state = createState();

  function log(msg) {
    host.log(`[time-to-ready] ${msg}`);
  }

  function resetHeatStart() {
    state.heatStartTime = null;
    state.heatStartTemp = null;
    state.maximumRemainingTimeSeconds = null;
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

    if (state.lastTargetTemp !== null && state.lastTargetTemp !== targetTemp) {
      resetHeatStart();
    }
    state.lastTargetTemp = targetTemp;

    if (machineState === 'sleeping') {
      resetHeatStart();
    } else if (currentTemp >= targetTemp) {
      resetHeatStart();
    } else if (machineState === 'ready') {
      state.heatStartTime = now;
      state.heatStartTemp = currentTemp;
      state.maximumRemainingTimeSeconds = null;
    } else if (state.heatStartTime !== null &&
      currentTemp < state.heatStartTemp - 2) {
      resetHeatStart();
    }
    state.lastTemp = currentTemp;

    if (state.heatStartTime === null && machineState !== 'sleeping' &&
      currentTemp < targetTemp) {
      state.heatStartTime = now;
      state.heatStartTemp = currentTemp;
      state.maximumRemainingTimeSeconds = null;
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

    if (state.heatStartTime === null || state.heatStartTemp === null ||
      currentTemp - state.heatStartTemp < MIN_WARMED_CELSIUS) {
      return {
        remainingTimeMs: null,
        heatingRate: null,
        status: 'insufficient_data',
        message: 'Collecting temperature data...',
      };
    }

    const elapsed = Math.max(1, (now - state.heatStartTime) / 1000);
    const warmed = Math.max(1, currentTemp - state.heatStartTemp);
    const togo = clamp((targetTemp - 10) - currentTemp, 1, 100);
    const progress = warmed / togo;
    const rawSeconds = roundToTens(Math.trunc(elapsed / progress));
    const estimatedSeconds = clamp(rawSeconds, 5, 300);

    if (state.maximumRemainingTimeSeconds === null) {
      state.maximumRemainingTimeSeconds = estimatedSeconds;
    } else {
      state.maximumRemainingTimeSeconds = Math.min(
        state.maximumRemainingTimeSeconds,
        estimatedSeconds,
      );
    }

    const remainingTimeSeconds = state.maximumRemainingTimeSeconds;
    const remainingTimeMs = remainingTimeSeconds * 1000;
    return {
      remainingTimeMs,
      heatingRate: warmed / elapsed,
      status: 'heating',
      message: `Estimated ${formatTime(remainingTimeMs)} remaining`,
      formattedTime: formatTime(remainingTimeMs),
    };
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
