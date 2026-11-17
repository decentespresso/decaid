function createPlugin(host) {
  const service = "00000ffe-0000-1000-8000-00805f9b34fb";
  const dataCharacteristic = "0000ff11-0000-1000-8000-00805f9b34fb";
  const commandCharacteristic = "0000ff12-0000-1000-8000-00805f9b34fb";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  function decode(data) {
    if (typeof data !== "string" || data.length !== 28 || data[27] !== "=") return null;
    const bytes = [];
    for (let i = 0; i < data.length; i += 4) {
      const a = alphabet.indexOf(data[i]);
      const b = alphabet.indexOf(data[i + 1]);
      const c = alphabet.indexOf(data[i + 2]);
      const d = data[i + 3] === "=" ? 0 : alphabet.indexOf(data[i + 3]);
      if (a < 0 || b < 0 || c < 0 || d < 0) return null;
      bytes.push((a << 2) | (b >> 4), ((b & 15) << 4) | (c >> 2));
      if (data[i + 3] !== "=") bytes.push(((c & 3) << 6) | d);
    }
    if (bytes[0] !== 3 || bytes[1] !== 11 || (bytes[6] !== 43 && bytes[6] !== 45)) return null;
    if (bytes.slice(0, 19).reduce((checksum, byte) => checksum ^ byte, 0) !== bytes[19]) return null;
    const magnitude = (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
    return {weight: (bytes[6] === 45 ? -magnitude : magnitude) / 100, battery: bytes[13]};
  }

  return {
    id: "bookoo-mini.reaplugin",
    onLoad() {
      return host.devices.bindDriver("bookoo", {
        create() {
          let active;
          function stop(state) {
            if (!state || state.stopped) return;
            state.stopped = true;
            clearTimeout(state.timer);
          }
          function command(opcode) {
            if (!active || active.stopped) return Promise.reject(new Error("Bookoo session is not connected"));
            const bytes = [3, 10, opcode, 0, 0];
            bytes.push(bytes.reduce((checksum, byte) => checksum ^ byte, 0));
            return active.session.gatt.writeWithResponse(service, commandCharacteristic,
              btoa(String.fromCharCode(...bytes)));
          }
          return {
            async connect(session) {
              const state = {session, stopped: false, timer: null};
              active = state;
              let battery = null;
              let ready;
              let failed;
              let settled = false;
              const firstPacket = new Promise((resolve, reject) => {ready = resolve; failed = reject;});
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
                  fail(new Error("Bookoo protocol silence"));
                  session.reportDisconnected().catch(() => {});
                }, 2000);
              }
              try {
                const services = await session.gatt.discoverServices();
                if (!services.includes(service)) throw new Error("Bookoo service unavailable");
                session.gatt.onDisconnect(() => {
                  stop(state);
                  fail(new Error("Bookoo disconnected before readiness"));
                });
                await session.gatt.subscribe(service, dataCharacteristic, async (data, sample) => {
                  if (state.stopped) return;
                  const decoded = decode(data);
                  if (!decoded) return;
                  watchPackets();
                  if (decoded.battery <= 100) battery = decoded.battery;
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
            disconnect() { stop(active); },
            tare() { return command(1); },
            startTimer() { return command(4); },
            stopTimer() { return command(5); },
            resetTimer() { return command(6); }
          };
        }
      });
    }
  };
}
