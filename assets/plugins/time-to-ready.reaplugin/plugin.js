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

  const MIN_SAMPLE_COUNT = 8;
  const MIN_WINDOW_MS = 5000;
  const HISTORY_WINDOW_MS = 30000;
  const MAX_OBSERVATION_GAP_MS = 10000;
  const MAX_ESTIMATE_UNCERTAINTY_MS = 3000;
  const CONFIDENCE_MULTIPLIER = 2;

  function createState() {
    return {
      ticksSeen: 0,
      loadedAt: null,
      tempHistory: [],
      lastEstimation: null,
      lastMachineState: null,
      lastTargetTemp: null,
    };
  }

  let state = createState();

  function log(msg) {
    host.log(`[time-to-ready] ${msg}`);
  }

  function resetTrend() {
    state.tempHistory = [];
    state.lastEstimation = null;
    state.lastTargetTemp = null;
  }

  function handleStateUpdate(payload) {
    state.ticksSeen++;

    const machineState = payload && payload.state && payload.state.state;
    if (machineState === 'sleeping') {
      resetTrend();
      state.lastMachineState = machineState;
      return;
    }

    if (payload['groupTemperature'] == undefined || payload['targetGroupTemperature'] == undefined) {
      log(`missing fields in ${JSON.stringify(payload)}`);
      return;
    }

    const currentTemp = payload['groupTemperature'];
    const targetTemp = payload['targetGroupTemperature'];
    const now = Date.now();

    if (state.lastMachineState !== null &&
      machineState === 'heating' &&
      state.lastMachineState !== 'heating') {
      resetTrend();
    }
    if (state.lastTargetTemp !== null && state.lastTargetTemp !== targetTemp) {
      resetTrend();
    }

    const lastReading = state.tempHistory[state.tempHistory.length - 1];
    if (lastReading && (now < lastReading.timestamp ||
      now - lastReading.timestamp > MAX_OBSERVATION_GAP_MS)) {
      resetTrend();
    }

    if (lastReading && now === lastReading.timestamp) {
      lastReading.temperature = currentTemp;
    } else {
      state.tempHistory.push({
        timestamp: now,
        temperature: currentTemp
      });
    }

    while (state.tempHistory.length > 0 &&
      now - state.tempHistory[0].timestamp > HISTORY_WINDOW_MS) {
      state.tempHistory.shift();
    }

    const estimation = estimateRemainingTime(
      currentTemp,
      targetTemp,
      state.tempHistory
    );

    state.lastEstimation = estimation;
    state.lastTargetTemp = targetTemp;
    state.lastMachineState = machineState;

    host.emit(
      "timeToReady",
      {
        ...estimation,
        currentTemp: currentTemp,
        targetTemp: targetTemp,
        timestamp: now
      }
    );
  }

  function handleStorageRead(payload) {
    if (payload.key === "lastEstimation") {
      log(`Loaded last estimation from storage: ${JSON.stringify(payload.value)}`);
      // You could use this to restore state
      if (payload.value) {
        state.lastEstimation = payload.value;
      }
    }
  }

  function handleStorageWrite(payload) {
    log(`Saved to storage: ${JSON.stringify(payload)}`);
  }

  function handleShutdown() {
    log("Shutdown requested");
  }

  /**
   * Estimate remaining time to reach target temperature
   * @param {number} currentTemp - Current temperature
   * @param {number} targetTemp - Target temperature
   * @param {Array} history - Array of {timestamp, temperature} objects
   * @returns {Object|null} Estimation object or null if not enough data
   */
  function estimateRemainingTime(currentTemp, targetTemp, history) {
    // Edge cases
    if (currentTemp >= targetTemp) {
      return {
        remainingTimeMs: 0,
        heatingRate: 0,
        status: 'reached',
        message: 'Target temperature reached'
      };
    }

    const regression = calculateHeatingRate(history);
    const tempDifference = targetTemp - currentTemp;
    const estimateUncertaintyMs = regression === null
      ? Infinity
      : calculateEstimateUncertaintyMs(tempDifference, regression);
    if (regression === null ||
      history.length < MIN_SAMPLE_COUNT ||
      history[history.length - 1].timestamp - history[0].timestamp < MIN_WINDOW_MS ||
      regression.rate <= 0 ||
      regression.rate - (CONFIDENCE_MULTIPLIER * regression.standardError) <= 0 ||
      !Number.isFinite(estimateUncertaintyMs) ||
      estimateUncertaintyMs > MAX_ESTIMATE_UNCERTAINTY_MS) {
      return {
        remainingTimeMs: null,
        heatingRate: regression ? regression.rate : null,
        status: 'insufficient_data',
        message: 'Collecting temperature data...'
      };
    }

    const remainingTimeMs = (tempDifference / regression.rate) * 1000;
    const displayedRemainingTimeMs = Math.min(remainingTimeMs, 300000);

    return {
      remainingTimeMs: Math.round(displayedRemainingTimeMs),
      heatingRate: regression.rate,
      status: 'heating',
      message: `Estimated ${formatTime(displayedRemainingTimeMs)} remaining`,
      formattedTime: formatTime(displayedRemainingTimeMs)
    };
  }

  /**
   * Calculate current heating rate (temperature change per second)
   * Fits a least-squares slope over the retained history
   * @param {Array} history - Array of {timestamp, temperature} objects
   * @returns {{rate: number, standardError: number, residualStandardDeviation: number}|null} Regression details
   */
  function calculateHeatingRate(history) {
    if (history.length < 2) return null;

    const origin = history[0].timestamp;
    const points = history.map((point) => ({
      time: (point.timestamp - origin) / 1000,
      temperature: point.temperature
    }));
    const meanTime = points.reduce((sum, point) => sum + point.time, 0) / points.length;
    const meanTemperature = points.reduce((sum, point) => sum + point.temperature, 0) / points.length;
    let covariance = 0;
    let variance = 0;

    for (const point of points) {
      covariance += (point.time - meanTime) * (point.temperature - meanTemperature);
      variance += (point.time - meanTime) ** 2;
    }
    if (variance === 0) return null;

    const rate = covariance / variance;
    let residualSum = 0;
    for (const point of points) {
      const predicted = meanTemperature + rate * (point.time - meanTime);
      residualSum += (point.temperature - predicted) ** 2;
    }

    const residualStandardDeviation = points.length > 2
      ? Math.sqrt(residualSum / (points.length - 2))
      : Infinity;
    const standardError = points.length > 2
      ? residualStandardDeviation / Math.sqrt(variance)
      : Infinity;
    return { rate, standardError, residualStandardDeviation };
  }

  function calculateEstimateUncertaintyMs(tempDifference, regression) {
    const slopeUncertainty = tempDifference *
      (CONFIDENCE_MULTIPLIER * regression.standardError) /
      (regression.rate ** 2);
    const temperatureUncertainty = CONFIDENCE_MULTIPLIER *
      regression.residualStandardDeviation / regression.rate;
    return (slopeUncertainty + temperatureUncertainty) * 1000;
  }

  /**
   * Format milliseconds into human-readable time string
   * @param {number} ms - Time in milliseconds
   * @returns {string} Formatted time string
   */
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
        settings: settings
      });

      // Example: Load saved state from storage
      host.storage({
        type: "read",
        key: "lastEstimation",
        namespace: "time-to-ready.reaplugin"
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
          data: state.lastEstimation
        });
      }

      state = createState();
    },

    onEvent(event) {
      if (!event || typeof event.name !== "string") {
        return;
      }

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
