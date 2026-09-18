function createPlugin(host) {
  "use strict";

  const maxInstances = 8;
  const requestTimeoutMs = 5000;
  const maxPendingRequests = 32;
  const minPollMs = 100;
  const maxPollMs = 3600000;
  const idPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
  const commands = {
    readState: {
      request: "RequestDriverState",
      result: "RequestDriverStateResult"
    },
    readConfig: {
      request: "RequestDriverConfig",
      result: "RequestDriverConfigResult"
    },
    readMachineInfo: {
      request: "RequestNachineInfo",
      result: "RequestNachineInfoResult"
    },
    readLogMessages: {
      request: "RequestLogMessages",
      result: "RequestLogMessagesResult"
    }
  };

  function configurationError(message) {
    throw new Error("E64 configuration error: " + message);
  }

  function parseSetting(settings, key, fallback) {
    const value = settings && settings[key] !== undefined ? settings[key] : fallback;
    if (typeof value !== "string") configurationError(key + " must be JSON text");
    try {
      return JSON.parse(value);
    } catch (_) {
      configurationError(key + " is invalid JSON");
    }
  }

  function validateConfiguration(settings) {
    const entries = parseSetting(settings, "InstancesJson", "[]");
    const tokens = parseSetting(settings, "TokensJson", "{}");
    if (!Array.isArray(entries) || entries.length > maxInstances) {
      configurationError("InstancesJson must contain at most 8 entries");
    }
    if (!tokens || typeof tokens !== "object" || Array.isArray(tokens)) {
      configurationError("TokensJson must be an object");
    }
    const ids = new Set();
    const configs = entries.map((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        configurationError("each instance must be an object");
      }
      const id = entry.id;
      const name = entry.name;
      const scheme = entry.scheme === undefined ? "ws" : entry.scheme;
      const hostName = entry.host;
      const port = entry.port;
      const pollMs = entry.pollMs === undefined ? 0 : entry.pollMs;
      if (typeof id !== "string" || !idPattern.test(id) || ids.has(id)) {
        configurationError("instance ids must be safe and unique");
      }
      if (typeof name !== "string" || name.length === 0 || name.length > 128) {
        configurationError("instance names are required");
      }
      if (scheme !== "ws" && scheme !== "wss") {
        configurationError("instance scheme must be ws or wss");
      }
      if (!validHost(hostName)) {
        configurationError("instance host is invalid");
      }
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        configurationError("instance port is invalid");
      }
      if (!Number.isInteger(pollMs) ||
          (pollMs !== 0 && (pollMs < minPollMs || pollMs > maxPollMs))) {
        configurationError("instance pollMs is out of bounds");
      }
      const token = tokens[id];
      if (typeof token !== "string" || token.length === 0 || token.length > 2048) {
        configurationError("each instance needs a secure token");
      }
      ids.add(id);
      return {id, name, scheme, host: hostName, port, pollMs, token};
    });
    for (const tokenId of Object.keys(tokens)) {
      if (!ids.has(tokenId)) configurationError("TokensJson contains an unknown id");
    }
    return configs;
  }

  function validHost(hostName) {
    if (typeof hostName !== "string" || hostName.length === 0 ||
        hostName.length > 253 || /[\\/\\?#@\s]/.test(hostName)) return false;
    if (hostName.charAt(0) === "[") {
      return hostName.charAt(hostName.length - 1) === "]" &&
        validIpv6(hostName.slice(1, -1));
    }
    if (hostName.indexOf(":") >= 0) return validIpv6(hostName);
    return hostName.split(".").every((label) =>
      /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label));
  }

  function validIpv6(value) {
    if (value.length === 0 || value.indexOf("::") !== value.lastIndexOf("::")) {
      return false;
    }
    const hasCompression = value.indexOf("::") >= 0;
    const sections = hasCompression ? value.split("::") : [value];
    const left = sections[0] ? sections[0].split(":") : [];
    const right = hasCompression && sections[1] ? sections[1].split(":") : [];
    const all = [...left, ...right];
    let sectionCount = 0;
    for (let index = 0; index < all.length; index++) {
      const section = all[index];
      if (section.length === 0) return false;
      if (section.indexOf(".") >= 0) {
        if (index !== all.length - 1 || !value.endsWith(section) ||
            !validIpv4(section)) return false;
        sectionCount += 2;
      } else {
        if (!/^[0-9A-Fa-f]{1,4}$/.test(section)) return false;
        sectionCount++;
      }
    }
    return hasCompression ? sectionCount < 8 : sectionCount === 8;
  }

  function validIpv4(value) {
    const octets = value.split(".");
    return octets.length === 4 && octets.every((octet) =>
      /^(?:0|[1-9][0-9]{0,2})$/.test(octet) && Number(octet) <= 255);
  }

  function urlFor(config) {
    let hostName = config.host;
    if (hostName.indexOf(":") >= 0 && hostName.charAt(0) !== "[") {
      hostName = "[" + hostName + "]";
    }
    return config.scheme + "://" + hostName + ":" + config.port +
      "/?token=" + encodeURIComponent(config.token);
  }

  function createInstance(config) {
    return {
      config,
      device: null,
      transport: null,
      handle: null,
      msgId: 0,
      epoch: 0,
      pending: new Map(),
      pollTimer: null,
      pollInFlight: false,
      connected: false
    };
  }

  function clearPoll(instance) {
    if (instance.pollTimer !== null) {
      clearTimeout(instance.pollTimer);
      instance.pollTimer = null;
    }
    instance.pollInFlight = false;
  }

  function rejectPending(instance, error) {
    for (const pending of instance.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(error));
    }
    instance.pending.clear();
  }

  function schedulePoll(instance, epoch) {
    if (instance.config.pollMs === 0 || !instance.connected || instance.epoch !== epoch) return;
    instance.pollTimer = setTimeout(() => {
      instance.pollTimer = null;
      if (!instance.connected || instance.epoch !== epoch) return;
      if (!instance.pollInFlight) {
        instance.pollInFlight = true;
        request(instance, "readState", true).catch(() => {}).finally(() => {
          if (instance.epoch === epoch) instance.pollInFlight = false;
        });
      }
      schedulePoll(instance, epoch);
    }, instance.config.pollMs);
  }

  function finishRequest(instance, epoch, message) {
    if (epoch !== instance.epoch || !message || !Number.isInteger(message.refId)) return;
    const pending = instance.pending.get(message.refId);
    if (!pending || pending.epoch !== epoch || pending.settling) return;
    if (message.type !== pending.resultType) {
      instance.pending.delete(message.refId);
      clearTimeout(pending.timer);
      pending.reject(new Error("E64 invalid response"));
      return;
    }
    if (!Object.prototype.hasOwnProperty.call(message, "data")) {
      instance.pending.delete(message.refId);
      clearTimeout(pending.timer);
      pending.reject(new Error("E64 invalid response"));
      return;
    }
    if (pending.publish) {
      if (!message.data || typeof message.data !== "object" || Array.isArray(message.data)) {
        instance.pending.delete(message.refId);
        clearTimeout(pending.timer);
        pending.reject(new Error("E64 invalid state response"));
        return;
      }
      if (pending.epoch !== instance.epoch) return;
      pending.settling = true;
      Promise.resolve(instance.device.publish({state: message.data})).then(
        () => {
          if (instance.pending.get(message.refId) !== pending) return;
          instance.pending.delete(message.refId);
          clearTimeout(pending.timer);
          if (pending.epoch !== instance.epoch) {
            pending.reject(new Error("E64 stale response"));
            return;
          }
          pending.resolve(message.data);
        },
        () => {
          if (instance.pending.get(message.refId) !== pending) return;
          instance.pending.delete(message.refId);
          clearTimeout(pending.timer);
          pending.reject(new Error("E64 state publication failed"));
        }
      );
      return;
    }
    instance.pending.delete(message.refId);
    clearTimeout(pending.timer);
    pending.resolve(message.data);
  }

  function handleEvent(instance, epoch, handle, event) {
    if (epoch !== instance.epoch || handle !== instance.handle) return;
    if (event.type === "error" || event.type === "close") {
      failInstance(instance, epoch);
      return;
    }
    if (event.type !== "data" || event.dataType !== "text" || typeof event.data !== "string") return;
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (_) {
      failInstance(instance, epoch, "E64 invalid response");
      return;
    }
    if (message && typeof message === "object" && message.pong === true) return;
    if (!message || typeof message !== "object" || !Number.isInteger(message.refId)) {
      failInstance(instance, epoch, "E64 invalid response");
      return;
    }
    finishRequest(instance, epoch, message);
  }

  function failInstance(instance, epoch, reason) {
    if (epoch !== instance.epoch) return;
    const transport = instance.transport;
    const handle = instance.handle;
    instance.epoch++;
    instance.connected = false;
    instance.transport = null;
    instance.handle = null;
    clearPoll(instance);
    rejectPending(instance, reason || "E64 connection closed");
    if (instance.device) instance.device.reportDisconnected().catch(() => {});
    if (transport && handle) transport.close(handle).catch(() => {});
  }

  async function connectInstance(instance, transport) {
    const epoch = ++instance.epoch;
    clearPoll(instance);
    rejectPending(instance, "E64 connection replaced");
    instance.connected = false;
    instance.transport = transport;
    instance.handle = null;
    let opened;
    try {
      opened = await transport.open({kind: "websocket", url: urlFor(instance.config)});
    } catch (_) {
      if (epoch === instance.epoch) {
        instance.transport = null;
        instance.connected = false;
      }
      throw new Error("E64 connection failed");
    }
    if (epoch !== instance.epoch) {
      transport.close(opened.handle).catch(() => {});
      return;
    }
    instance.handle = opened.handle;
    instance.connected = true;
    transport.onEvent(opened.handle, (event) => handleEvent(instance, epoch, opened.handle, event));
    schedulePoll(instance, epoch);
  }

  async function disconnectInstance(instance) {
    const transport = instance.transport;
    const handle = instance.handle;
    instance.epoch++;
    instance.connected = false;
    instance.transport = null;
    instance.handle = null;
    clearPoll(instance);
    rejectPending(instance, "E64 disconnected");
    if (transport && handle) {
      try { await transport.close(handle); } catch (_) {}
    }
  }

  function request(instance, commandId, publish) {
    if (!instance.connected || !instance.transport || !instance.handle) {
      return Promise.reject(new Error("E64 is disconnected"));
    }
    const command = commands[commandId];
    const epoch = instance.epoch;
    const id = ++instance.msgId;
    return new Promise((resolve, reject) => {
      if (instance.pending.size >= maxPendingRequests) {
        reject(new Error("E64 request queue is full"));
        return;
      }
      const pending = {
        epoch,
        resultType: command.result,
        publish: !!publish,
        settling: false,
        resolve,
        reject,
        timer: setTimeout(() => {
          if (instance.pending.get(id) !== pending) return;
          instance.pending.delete(id);
          reject(new Error("E64 request timed out"));
        }, requestTimeoutMs)
      };
      instance.pending.set(id, pending);
      instance.transport.send(instance.handle, {
        type: "text",
        data: JSON.stringify({type: command.request, msgId: id})
      }).catch(() => {
        if (instance.pending.get(id) !== pending) return;
        instance.pending.delete(id);
        clearTimeout(pending.timer);
        reject(new Error("E64 request failed"));
      });
    });
  }

  const instances = new Map();

  return {
    id: "e64ws.reaplugin",
    onLoad(settings) {
      const configs = validateConfiguration(settings);
      for (const config of configs) instances.set(config.id, createInstance(config));
      return Promise.all(configs.map((config) => {
        const instance = instances.get(config.id);
        return host.devices.register({
          driverId: "e64ws",
          instanceId: config.id,
          name: config.name,
          vendor: "Mahlkoenig",
          dataChannels: [{key: "state", type: "object"}],
          commands: [
            {id: "readState"},
            {id: "readConfig"},
            {id: "readMachineInfo"},
            {id: "readLogMessages"}
          ]
        }, {
          connect(transport) {
            return connectInstance(instance, transport);
          },
          disconnect() {
            return disconnectInstance(instance);
          },
          execute(command) {
            if (!command || typeof command.commandId !== "string" ||
                !Object.prototype.hasOwnProperty.call(commands, command.commandId)) {
              return Promise.reject(new Error("E64 command is not supported"));
            }
            return request(instance, command.commandId, command.commandId === "readState");
          }
        }).then((device) => {
          instance.device = device;
          return device;
        });
      }));
    },
    onUnload() {
      return Promise.all(Array.from(instances.values()).map(disconnectInstance));
    }
  };
}
