function createPlugin(host) {
  const pendingReads = new Map();
  let pendingWrite = null;

  return {
    id: "plugin-device-settings.reaplugin",
    onEvent(event) {
      if (event.name === "storageRead") {
        const resolve = pendingReads.get(event.payload.key);
        pendingReads.delete(event.payload.key);
        if (resolve) resolve(event.payload.value);
      } else if (event.name === "storageWrite" && pendingWrite) {
        const resolve = pendingWrite;
        pendingWrite = null;
        resolve();
      }
    },
    async __httpRequestHandler(request) {
      if (request.endpoint !== "device-settings") {
        return {
          requestId: request.requestId,
          status: 404,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ error: "Unknown endpoint" })
        };
      }

      const deviceId = request.query.deviceId;
      const key = deviceId;
      let value;
      if (Object.prototype.hasOwnProperty.call(request.query, "value")) {
        value = request.query.value;
        await new Promise(resolve => {
          pendingWrite = resolve;
          host.storage({ type: "write", key, data: value });
        });
      } else {
        value = await new Promise(resolve => {
          pendingReads.set(key, resolve);
          host.storage({ type: "read", key });
        });
      }
      return {
        requestId: request.requestId,
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deviceId, value })
      };
    }
  };
}
