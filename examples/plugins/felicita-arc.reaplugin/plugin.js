function createPlugin(host) {
  const service = "0000ffe0-0000-1000-8000-00805f9b34fb";
  const characteristic = "0000ffe1-0000-1000-8000-00805f9b34fb";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

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

  function decode(data) {
    const bytes = decodeBase64(data);
    if (!bytes || bytes.length !== 18) return null;
    const sign = bytes[2];
    let digits = "";
    for (let i = 3; i <= 8; i++) {
      if (bytes[i] < 48 || bytes[i] > 57) return null;
      digits += String.fromCharCode(bytes[i]);
    }
    const magnitude = Number(digits);
    const rawBattery = bytes[15];
    const battery = rawBattery >= 129 && rawBattery <= 158
      ? Math.round((rawBattery - 129) * 100 / 29)
      : null;
    return {weight: (sign === 45 ? -magnitude : magnitude) / 100, battery};
  }

  return {
    id: "felicita-arc.reaplugin",
    onLoad() {
      return host.devices.bindDriver("felicita", {
        create() {
          let active = null;
          let battery = null;

          function stop(state) {
            if (!state || state.stopped) return;
            state.stopped = true;
            clearTimeout(state.timer);
          }

          function command(opcode) {
            if (!active || active.stopped) {
              return Promise.reject(new Error("Felicita session is not connected"));
            }
            return active.session.gatt.writeWithResponse(
              service,
              characteristic,
              btoa(String.fromCharCode(opcode)),
            );
          }

          return {
            async connect(session) {
              const state = {session, stopped: false, timer: null};
              active = state;
              battery = null;
              let ready;
              let failed;
              let settled = false;
              const firstPacket = new Promise((resolve, reject) => {
                ready = resolve;
                failed = reject;
              });
              firstPacket.catch(() => {});
              function succeed() {
                if (!settled) {
                  settled = true;
                  ready();
                }
              }
              function fail(error) {
                if (!settled) {
                  settled = true;
                  failed(error);
                }
              }
              function watchPackets() {
                clearTimeout(state.timer);
                state.timer = setTimeout(() => {
                  stop(state);
                  fail(new Error("Felicita protocol silence"));
                  session.reportDisconnected().catch(() => {});
                }, 2000);
              }
              try {
                const services = await session.gatt.discoverServices();
                if (!services.includes(service)) {
                  throw new Error("Felicita service unavailable");
                }
                session.gatt.onDisconnect(() => {
                  stop(state);
                  fail(new Error("Felicita disconnected before readiness"));
                });
                await session.gatt.subscribe(service, characteristic, async (data, sample) => {
                  if (state.stopped) return;
                  const decoded = decode(data);
                  if (!decoded) return;
                  watchPackets();
                  if (decoded.battery !== null) battery = decoded.battery;
                  await session.publish({weight: decoded.weight, battery}, sample);
                  if (!state.stopped) succeed();
                });
                if (!state.stopped && state.timer === null) watchPackets();
                await firstPacket;
              } catch (error) {
                stop(state);
                fail(error);
                throw error;
              }
            },
            disconnect() {
              stop(active);
            },
            tare() { return command(0x54); },
            startTimer() { return command(0x52); },
            stopTimer() { return command(0x53); },
            resetTimer() { return command(0x43); }
          };
        }
      });
    }
  };
}
