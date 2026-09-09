const pluginBleBridgeJs = r'''
const __bindBleDriver = (driverId, factory) => {
  if (!factory || typeof factory.create !== 'function') {
    return Promise.reject(new Error('bindDriver requires create(device)'));
  }
  const factoryHandle = 'factory_' + pluginGeneration + '_' + __deviceNonce + '_' + (++__deviceSeq);
  const create = payload => {
    const metadata = payload.device;
    if (metadata.advertisement.serviceUuids) Object.freeze(metadata.advertisement.serviceUuids);
    Object.freeze(metadata.advertisement);
    Object.freeze(metadata);
    const handlers = factory.create(metadata);
    if (!handlers || typeof handlers !== 'object' || typeof handlers.then === 'function') {
      throw new Error('BLE create must return handlers synchronously, without hardware initialization');
    }
    if (typeof handlers.connect !== 'function' || typeof handlers.disconnect !== 'function') {
      throw new Error('BLE connect and disconnect handlers are required');
    }
    const handle = payload.registrationHandle;
    const sessions = new Map();
    const cleanups = new Set();
    const recoverableSampleErrors = new WeakMap();
    const stale = () => Object.assign(new Error('BLE session retired'), {code: 'stale_session'});
    const context = (payload, cleanup) => {
      const authority = payload.gattSession;
      const callbacks = new Map();
      const record = {
        callbacks,
        disconnected: false,
        delivered: false,
        onDisconnect: null,
        callbackEpoch: 0,
        activeCallbackEpoch: 0
      };
      if (!cleanup) sessions.set(authority, record);
      else cleanups.add(record);
      const call = (operation, args = {}) => record.disconnected
        ? Promise.reject(stale()) : __deviceCall('gatt', {
        registrationHandle: handle, authority, operation, args
      }).then(result => result.value);
      const gatt = Object.freeze({
        discoverServices: () => call('discoverServices'),
        read: (service, characteristic) => call('read', {service, characteristic}),
        writeWithResponse: (service, characteristic, data) =>
          call('write', {service, characteristic, data, withResponse: true}),
        writeWithoutResponse: (service, characteristic, data) =>
          call('write', {service, characteristic, data, withResponse: false}),
        async subscribe(service, characteristic, callback) {
          if (typeof callback !== 'function') throw new Error('subscribe requires a callback');
          const listener = 'listener_' + (++__deviceSeq);
          callbacks.set(listener, callback);
          try {
            const result = await call('subscribe', {service, characteristic, listener});
            if (result.replacedListener) callbacks.delete(result.replacedListener);
            return Object.freeze({
              async unsubscribe() {
                await call('unsubscribe', {subscription: result.subscription});
                callbacks.delete(listener);
              }
            });
          } catch (error) {
            callbacks.delete(listener);
            throw error;
          }
        },
        onDisconnect(callback) {
          if (cleanup || typeof callback !== 'function') throw new Error('Invalid disconnect listener');
          if (record.disconnected) {
            if (!record.delivered) { record.delivered = true; callback(); }
            return;
          }
          record.onDisconnect = callback;
        }
      });
      if (cleanup) return Object.freeze({gatt});
      return Object.freeze({
        gatt,
        publish: (snapshot, sample) => record.disconnected ? Promise.reject(stale()) : __deviceCall('blePublish', {
          registrationHandle: handle, session: payload.session, snapshot, sample
        }).catch(error => {
          if (sample != null && error && error.code === 'stale_sample' &&
              (typeof error === 'object' || typeof error === 'function') &&
              record.activeCallbackEpoch !== 0) {
            recoverableSampleErrors.set(error, {
              record,
              epoch: record.activeCallbackEpoch
            });
          }
          throw error;
        }),
        reportDisconnected: () => record.disconnected ? Promise.reject(stale()) : __deviceCall('bleDisconnected', {
          registrationHandle: handle, session: payload.session
        })
      });
    };
    const boundHandlers = {...handlers};
    boundHandlers.disconnect = payload => handlers.disconnect(context(payload, true));
    boundHandlers.bleEvent = async event => {
      const record = sessions.get(event.session);
      if (!record) return;
      if (event.type === 'disconnect') {
        if (record.disconnected) return;
        record.disconnected = true;
        record.callbacks.clear();
        for (const cleanup of cleanups) cleanup.disconnected = true;
        cleanups.clear();
        sessions.delete(event.session);
        const callback = record.onDisconnect;
        record.onDisconnect = null;
        if (callback) { record.delivered = true; await callback(); }
        return;
      }
      const callback = record.callbacks.get(event.listener);
      if (callback && !record.disconnected) {
        const epoch = ++record.callbackEpoch;
        record.activeCallbackEpoch = epoch;
        try {
          await callback(event.data, event.sample);
        } catch (error) {
          const provenance = error &&
            (typeof error === 'object' || typeof error === 'function')
              ? recoverableSampleErrors.get(error) : null;
          if (!provenance || provenance.record !== record || provenance.epoch !== epoch) {
            throw error;
          }
          recoverableSampleErrors.delete(error);
        } finally {
          if (record.activeCallbackEpoch === epoch) record.activeCallbackEpoch = 0;
        }
      }
    };
    __deviceSetHandlers(handle, {
      pluginId, generation: pluginGeneration, bridgeToken: pluginBridgeToken,
      handlers: boundHandlers,
      connectTransport: (_, payload) => context(payload, false),
      dispose: () => {
        for (const record of sessions.values()) {
          record.disconnected = true;
          record.callbacks.clear();
          record.onDisconnect = null;
        }
        for (const cleanup of cleanups) cleanup.disconnected = true;
        cleanups.clear();
        sessions.clear();
      }
    });
    return {vendor: handlers.vendor, dataChannels: handlers.dataChannels, commands: handlers.commands};
  };
  __deviceSetHandlers(factoryHandle, {
    pluginId, generation: pluginGeneration, bridgeToken: pluginBridgeToken,
    handlers: {create}
  });
  return __deviceCall('bindDriver', {registrationHandle: factoryHandle, driverId}).then(
    () => undefined,
    error => { __deviceRemoveHandlers(factoryHandle); throw error; }
  );
};
''';
