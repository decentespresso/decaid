function createPlugin(host) {
  const service = "0000ff08-0000-1000-8000-00805f9b34fb";
  const weightCharacteristic = "0000ef81-0000-1000-8000-00805f9b34fb";
  const commandCharacteristic = "0000ef80-0000-1000-8000-00805f9b34fb";
  const buttonCharacteristic = "0000ef82-0000-1000-8000-00805f9b34fb";
  const batteryService = "0000180f-0000-1000-8000-00805f9b34fb";
  const batteryCharacteristic = "00002a19-0000-1000-8000-00805f9b34fb";
  const deviceInformationService = "0000180a-0000-1000-8000-00805f9b34fb";
  const firmwareCharacteristic = "00002a26-0000-1000-8000-00805f9b34fb";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const initStepDelay = 1000;
  const batteryRefreshInterval = 30 * 60 * 1000;
  const settingsStoreUrl = "http://127.0.0.1:8080/api/v1/store/kvStore/";
  const apiBaseUrl = "http://127.0.0.1:8080/api/v1";
  const deviceSettings = new Map();
  const settingsOperations = new Map();
  const instanceControls = new Map();

  function settingKey(deviceId) {
    return "skale.reaplugin.device." + deviceId;
  }

  function jsonResponse(status, body) {
    return {
      status,
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(body),
    };
  }

  function htmlResponse(status, body) {
    return {
      status,
      headers: {"Content-Type": "text/html; charset=utf-8"},
      body,
    };
  }

  const settingsPage = `<!doctype html>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta charset="utf-8">
<title>Skale settings</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 1rem; max-width: 32rem; }
  label { display: block; margin: .9rem 0; }
  input, button { font: inherit; min-height: 2.5rem; }
  output { display: block; min-height: 1.5rem; margin-top: .75rem; }
</style>
<form id="settings">
  <input id="deviceId" type="hidden">
  <p>Device: <span id="deviceLabel"></span></p>
  <label><input id="usbPower" type="checkbox"> USB powered (suppress battery reads)</label>
  <label><input id="squareAction" type="checkbox"> Square action (default off)</label>
  <button id="save" disabled>Save</button>
  <output id="status" role="status"></output>
</form>
<script>
const form = document.getElementById("settings");
const deviceId = document.getElementById("deviceId");
const deviceLabel = document.getElementById("deviceLabel");
const usbPower = document.getElementById("usbPower");
const squareAction = document.getElementById("squareAction");
const save = document.getElementById("save");
const status = document.getElementById("status");
let loadGeneration = 0;
let loaded = false;
deviceId.value = new URLSearchParams(location.search).get("deviceId") || "";
const deviceName = new URLSearchParams(location.search).get("deviceName");
deviceLabel.textContent = deviceName || deviceId.value || "Unavailable";
async function load() {
  const id = deviceId.value;
  const generation = ++loadGeneration;
  loaded = false;
  save.disabled = true;
  if (!id) {
    status.textContent = "Device unavailable";
    return;
  }
  status.textContent = "Loading...";
  try {
    const response = await fetch("device-settings?deviceId=" + encodeURIComponent(id));
    if (!response.ok) throw new Error("Settings could not be loaded");
    const value = await response.json();
    if (generation !== loadGeneration) return;
    usbPower.checked = value.usbPower === true;
    squareAction.checked = value.squareAction === true;
    loaded = true;
    save.disabled = false;
    status.textContent = "";
  } catch (error) {
    if (generation === loadGeneration) status.textContent = error.message;
  }
}
form.addEventListener("submit", async event => {
  event.preventDefault();
  if (!loaded) return;
  status.textContent = "";
  save.disabled = true;
  try {
    const response = await fetch("device-settings?deviceId=" + encodeURIComponent(deviceId.value), {
      method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({usbPower: usbPower.checked, squareAction: squareAction.checked}),
    });
    if (!response.ok) throw new Error("Settings could not be saved");
    status.textContent = "Saved";
  } catch (error) {
    status.textContent = error.message;
  } finally {
    if (loaded) save.disabled = false;
  }
});
deviceId.addEventListener("change", load);
load();
</script>`;

  function requestDeviceId(request) {
    const deviceId = request.query && request.query.deviceId;
    return typeof deviceId === "string" && deviceId.length > 0 && deviceId.length <= 256
      ? deviceId
      : null;
  }

  function queueSettings(deviceId, operation) {
    const previous = settingsOperations.get(deviceId) || Promise.resolve();
    const next = previous.catch(() => {}).then(operation);
    settingsOperations.set(deviceId, next);
    return next.finally(() => {
      if (settingsOperations.get(deviceId) === next) {
        settingsOperations.delete(deviceId);
      }
    });
  }

  async function loadSettings(deviceId) {
    return queueSettings(deviceId, async () => {
      if (deviceSettings.has(deviceId)) {
        return {value: deviceSettings.get(deviceId), known: true};
      }
      try {
        const response = await fetch(
          settingsStoreUrl + encodeURIComponent(settingKey(deviceId)),
        );
        if (!response.ok) {
          if (response.status === 404) {
            const value = {usbPower: false, squareAction: false};
            deviceSettings.set(deviceId, value);
            return {value, known: true};
          }
          return {value: null, known: false};
        }
        const stored = await response.json();
        if (stored == null) {
          const value = {usbPower: false, squareAction: false};
          deviceSettings.set(deviceId, value);
          return {value, known: true};
        }
        if (typeof stored.usbPower !== "boolean" ||
            (stored.squareAction !== undefined &&
             typeof stored.squareAction !== "boolean")) {
          return {value: null, known: false};
        }
        const value = {
          usbPower: stored.usbPower,
          squareAction: stored.squareAction === true,
        };
        deviceSettings.set(deviceId, value);
        return {value, known: true};
      } catch (_) {
        return {value: null, known: false};
      }
    });
  }

  async function saveSettings(deviceId, value) {
    return queueSettings(deviceId, async () => {
      const response = await fetch(
        settingsStoreUrl + encodeURIComponent(settingKey(deviceId)),
        {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(value),
        },
      );
      if (!response.ok) throw new Error("Skale settings persistence failed");
      deviceSettings.set(deviceId, value);
    });
  }

  function decodeBase64(data) {
    if (typeof data !== "string" || data.length % 4 !== 0) return null;
    const bytes = [];
    for (let i = 0; i < data.length; i += 4) {
      const a = alphabet.indexOf(data[i]);
      const b = alphabet.indexOf(data[i + 1]);
      const c = data[i + 2] === "=" ? 0 : alphabet.indexOf(data[i + 2]);
      const d = data[i + 3] === "=" ? 0 : alphabet.indexOf(data[i + 3]);
      if (a < 0 || b < 0 || c < 0 || d < 0) return null;
      bytes.push((a << 2) | (b >> 4));
      if (data[i + 2] !== "=") bytes.push(((b & 15) << 4) | (c >> 2));
      if (data[i + 3] !== "=") bytes.push(((c & 3) << 6) | d);
    }
    return bytes;
  }

  function encode(bytes) {
    return btoa(String.fromCharCode(...bytes));
  }

  function decodeWeight(data) {
    const bytes = decodeBase64(data);
    if (!bytes) return null;
    if (bytes.length === 4) {
      const raw = (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24));
      return raw / 2560;
    }
    if (bytes.length !== 5 && bytes.length !== 9) return null;
    let mantissa = bytes[1] | (bytes[2] << 8) | (bytes[3] << 16);
    if ((mantissa & 0x800000) !== 0) mantissa -= 0x1000000;
    const exponent = bytes[4] >= 0x80 ? bytes[4] - 0x100 : bytes[4];
    const weight = mantissa * Math.pow(10, exponent);
    return Number.isFinite(weight) ? weight : null;
  }

  function decodeBattery(data) {
    const bytes = decodeBase64(data);
    return bytes && bytes.length === 1 && bytes[0] <= 100 ? bytes[0] : null;
  }

  function decodeFirmware(data) {
    const bytes = decodeBase64(data);
    if (!bytes || bytes.length === 0) return null;
    let encoded = "";
    for (const byte of bytes) encoded += "%" + byte.toString(16).padStart(2, "0");
    let value;
    try {
      value = decodeURIComponent(encoded).replace(/\0+$/, "").trim();
    } catch (_) {
      return null;
    }
    if (value.length === 0) return null;
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code < 0x20 || code === 0x7f) return null;
    }
    return value;
  }

  function buttonValue(data) {
    const bytes = decodeBase64(data);
    if (!bytes || bytes.length === 0) return null;
    return bytes[0] === 1 || bytes[0] === 2 ? bytes[0] : null;
  }

  function delay() {
    return new Promise(resolve => setTimeout(resolve, initStepDelay));
  }

  return {
    id: "skale.reaplugin",
    onLoad() {
      return host.devices.bindDriver("skale", {
        create(device) {
          const deviceId = device && typeof device.id === "string" ? device.id : "";
          let active = null;

          async function applySettings(nextSettings) {
            const state = active;
            if (!isActive(state)) return;
            const enabled = nextSettings.usbPower === true;
            const squareAction = nextSettings.squareAction === true;
            const pendingBatteryRead = state.batteryReadPromise;
            if (state.usbPowerKnown && state.usbPower === enabled &&
                state.squareAction === squareAction) return;
            state.settingsEpoch++;
            state.buttonEpoch++;
            state.usbPowerKnown = true;
            state.usbPower = enabled;
            state.squareAction = squareAction;
            clearTimeout(state.batteryTimer);
            state.batteryTimer = null;
            state.battery = null;
            state.session.publishInfo({batteryLevel: null}).catch(() => {});
            if (pendingBatteryRead) await pendingBatteryRead.catch(() => {});
            if (!enabled && state.services.includes(batteryService)) {
              while (state.batteryReadInFlight) {
                await state.batteryReadPromise;
              }
              await readBattery(state);
              if (isActive(state)) scheduleBatteryRefresh(state);
            }
          }

          function isActive(state) {
            return state != null && active === state && !state.stopped;
          }

          function stop(state) {
            if (!state || state.stopped) return;
            state.stopped = true;
            state.settingsEpoch++;
            state.buttonEpoch++;
            clearTimeout(state.batteryTimer);
            if (instanceControls.get(deviceId) === applySettings) {
              instanceControls.delete(deviceId);
            }
            if (!state.settled) {
              state.settled = true;
              state.reject(new Error("Skale session stopped"));
            }
          }

          function fail(state, error) {
            if (!state.settled) {
              state.settled = true;
              state.reject(error);
            }
          }

          async function readBattery(state) {
            if (!isActive(state) || !state.usbPowerKnown || state.usbPower) return;
            if (state.batteryReadInFlight) return state.batteryReadPromise;
            state.batteryReadInFlight = true;
            const readEpoch = state.settingsEpoch;
            state.batteryReadPromise = (async () => {
              let value = null;
              try {
                value = decodeBattery(await state.session.gatt.read(
                  batteryService,
                  batteryCharacteristic,
                ));
              } catch (_) {
                value = null;
              }
              if (!isActive(state) || readEpoch !== state.settingsEpoch || state.usbPower) return;
              state.battery = value;
              state.session.publishInfo({batteryLevel: value}).catch(() => {});
            })();
            try {
              await state.batteryReadPromise;
            } finally {
              state.batteryReadInFlight = false;
              state.batteryReadPromise = null;
            }
          }

          async function publishInfo(state, services) {
            if (!isActive(state) || !services.includes(deviceInformationService)) return;
            const firmwareRead = state.session.gatt.read(
              deviceInformationService,
              firmwareCharacteristic,
            ).then(decodeFirmware).catch(() => null);
            const batteryRead = services.includes(batteryService)
              ? readBattery(state)
              : Promise.resolve();
            const firmwareVersion = await firmwareRead;
            await batteryRead;
            state.firmwareVersion = firmwareVersion;
            if (isActive(state)) {
              await state.session.publishInfo({
                firmwareVersion,
                batteryLevel: state.battery,
              });
            }
          }

          function scheduleBatteryRefresh(state) {
            clearTimeout(state.batteryTimer);
            if (!state.usbPowerKnown || state.usbPower) return;
            state.batteryTimer = setTimeout(async () => {
              if (!isActive(state) || !state.usbPowerKnown || state.usbPower) return;
              await readBattery(state);
              if (isActive(state)) scheduleBatteryRefresh(state);
            }, batteryRefreshInterval);
          }

          function command(bytes) {
            const state = active;
            if (!isActive(state)) {
              return Promise.reject(new Error("Skale session is not connected"));
            }
            return state.session.gatt.writeWithoutResponse(
              service,
              commandCharacteristic,
              encode(bytes),
            );
          }

          async function apiJson(path, options) {
            const response = await fetch(apiBaseUrl + path, options);
            if (!response.ok) throw new Error("Skale machine API request failed");
            const body = await response.text();
            return body.length === 0 ? null : JSON.parse(body);
          }

          async function currentScaleRole(state) {
            const devices = await apiJson("/devices");
            if (!Array.isArray(devices)) return null;
            const candidate = devices.find(entry =>
              entry && entry.id === state.deviceId &&
              (entry.connectionRole === "primary" ||
               entry.connectionRole === "auxiliary"));
            return candidate ? candidate.connectionRole : null;
          }

          async function currentPrimaryScale(state) {
            const connections = await apiJson("/scale/connections");
            const connectionId = state.session.connectionId;
            if (typeof connectionId !== "string") return null;
            const candidate = connections && connections.primary;
            if (candidate && candidate.deviceId === state.deviceId &&
                candidate.connectionId === connectionId &&
                typeof candidate.selectionId === "string") {
              return {role: "primary", source: candidate};
            }
            return null;
          }

          async function runButtonAction(state, button, epoch) {
            if (!isActive(state) || state.buttonEpoch !== epoch) return;
            const role = await currentScaleRole(state);
            if (!isActive(state) || state.buttonEpoch !== epoch || !role) return;
            if (button === 1) {
              await command([0x10]);
              return;
            }
            if (!state.squareAction || role !== "primary") return;
            const sourceScale = await currentPrimaryScale(state);
            if (!isActive(state) || state.buttonEpoch !== epoch || !sourceScale) return;
            const machine = await apiJson("/machine/state");
            if (!isActive(state) || state.buttonEpoch !== epoch || !machine) return;
            const currentState = machine.state && machine.state.state;
            if (currentState !== "idle" && currentState !== "espresso") return;
            let requireInactiveGhc = false;
            if (currentState === "idle") {
              const info = await apiJson("/machine/info");
              if (!isActive(state) || state.buttonEpoch !== epoch || !info ||
                  info.GHC !== false || typeof info.version !== "string" ||
                  typeof info.model !== "string" || typeof info.serialNumber !== "string" ||
                  !info.version || !info.model || !info.serialNumber) return;
              requireInactiveGhc = true;
            }
            const targetState = currentState === "idle" ? "espresso" : "idle";
            await apiJson("/machine/state/" + targetState, {
              method: "PUT",
              headers: {"Content-Type": "application/json"},
              body: JSON.stringify({
                guarded: true,
                expectedMachineId: machine.deviceId,
                expectedMachineGeneration: machine.connectionGeneration,
                expectedState: currentState,
                requireInactiveGhc,
                sourceScale: {role: "primary", ...sourceScale.source},
              }),
            });
          }

          function queueButtonAction(state, button) {
            if (!isActive(state)) return;
            const epoch = state.buttonEpoch;
            if (button === 1) {
              state.buttonQueue = state.buttonQueue
                .then(() => runButtonAction(state, button, epoch))
                .catch(() => {});
              return;
            }
            runButtonAction(state, button, epoch).catch(() => {});
          }

          return {
            async connect(session) {
              const state = {
                session,
                deviceId,
                services: [],
                stopped: false,
                settled: false,
                batteryTimer: null,
                batteryReadInFlight: false,
                batteryReadPromise: null,
                battery: null,
                firmwareVersion: null,
                usbPower: false,
                usbPowerKnown: false,
                squareAction: false,
                settingsEpoch: 0,
                buttonEpoch: 0,
                buttonQueue: Promise.resolve(),
                readyForWeight: false,
                resolve: null,
                reject: null,
              };
              active = state;
              instanceControls.set(deviceId, applySettings);
              const firstWeight = new Promise((resolve, reject) => {
                state.resolve = resolve;
                state.reject = reject;
              });
              firstWeight.catch(() => {});
              try {
                const services = await session.gatt.discoverServices();
                state.services = services;
                if (!services.includes(service)) {
                  throw new Error("Skale service unavailable");
                }
                const usbSetting = await loadSettings(deviceId);
                if (!usbSetting.known) {
                  throw new Error("Skale settings unavailable");
                }
                state.usbPower = usbSetting.value.usbPower;
                state.usbPowerKnown = true;
                state.squareAction = usbSetting.value.squareAction;
                session.gatt.onDisconnect(() => {
                  if (!isActive(state)) return;
                  stop(state);
                  fail(state, new Error("Skale disconnected before readiness"));
                });
                await session.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0xed]));
                await session.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0xec]));
                await delay();
                await session.gatt.subscribe(service, weightCharacteristic, async (data, sample) => {
                  if (!isActive(state)) return;
                  if (!state.readyForWeight) return;
                  const weight = decodeWeight(data);
                  if (weight === null) return;
                  try {
                    await session.publish({weight, battery: state.battery}, sample);
                    if (!state.settled && isActive(state)) {
                      state.settled = true;
                      state.resolve();
                    }
                  } catch (_) {
                    if (isActive(state)) fail(state, new Error("Skale weight publication failed"));
                  }
                });
                await delay();
                await session.gatt.subscribe(service, buttonCharacteristic, async data => {
                  if (!isActive(state)) return;
                  const button = buttonValue(data);
                  if (button !== null) {
                    queueButtonAction(state, button);
                  }
                });
                await delay();
                if (!isActive(state)) throw new Error("Skale session retired");
                await session.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0xed]));
                await session.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0xec]));
                await session.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0x03]));
                state.readyForWeight = true;
                if (services.includes(deviceInformationService)) {
                  publishInfo(state, services).catch(() => {});
                } else if (services.includes(batteryService) && state.usbPowerKnown &&
                           !state.usbPower) {
                  readBattery(state).catch(() => {});
                }
                if (services.includes(batteryService) && state.usbPowerKnown &&
                    !state.usbPower) {
                  scheduleBatteryRefresh(state);
                }
                await firstWeight;
              } catch (error) {
                stop(state);
                fail(state, error);
                throw error;
              }
            },
            async disconnect(context) {
              const state = active;
              stop(state);
              if (context && context.gatt) {
                try {
                  await context.gatt.writeWithoutResponse(service, commandCharacteristic, encode([0xee]));
                } catch (_) {}
              }
            },
            tare() { return command([0x10]); },
            startTimer() { return command([0xdd]); },
            stopTimer() { return command([0xd1]); },
            resetTimer() { return command([0xd0]); },
            sleepDisplay() { return command([0xee]); },
            async wakeDisplay() {
              await command([0xed]);
              await command([0xec]);
            },
          };
        }
      });
    },
    handleHttpRequest(request) {
      if (request.method === "GET" && request.query && request.query.ui === "1") {
        return htmlResponse(200, settingsPage);
      }
      const deviceId = requestDeviceId(request);
      if (!deviceId) return jsonResponse(400, {error: "deviceId is required"});
      if (request.method === "GET") {
        return loadSettings(deviceId).then(setting => setting.known
          ? jsonResponse(200, {deviceId, ...setting.value})
          : jsonResponse(503, {error: "settings unavailable"}));
      }
      if (request.method !== "POST" || !request.body ||
          typeof request.body.usbPower !== "boolean" ||
          (request.body.squareAction !== undefined &&
           typeof request.body.squareAction !== "boolean") ||
          Object.keys(request.body).some(key => key !== "usbPower" && key !== "squareAction")) {
        return jsonResponse(400, {error: "usbPower and squareAction must be booleans"});
      }
      const settings = {
        usbPower: request.body.usbPower,
        squareAction: request.body.squareAction === true,
      };
      return saveSettings(deviceId, settings).then(async () => {
        const update = instanceControls.get(deviceId);
        if (update) await update(settings);
        return jsonResponse(200, {
          deviceId,
          ...settings,
        });
      }).catch(() => jsonResponse(502, {error: "settings persistence failed"}));
    },
    onUnload() {
      instanceControls.clear();
      deviceSettings.clear();
      settingsOperations.clear();
    },
  };
}
