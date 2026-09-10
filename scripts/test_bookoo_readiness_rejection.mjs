#!/usr/bin/env node
// Readiness-rejection lifecycle check for the Bookoo reference plugin.
//
// The Decaid plugin runtime does not expose unhandled-promise tracking, so this
// script drives the real plugin source through the scenarios that matter and
// reports unhandled rejections itself. It supplements the Dart runtime tests;
// it is not a substitute for them.
//
// Run: node scripts/test_bookoo_readiness_rejection.mjs

import { readFileSync } from 'node:fs';

const pluginPath = new URL(
  '../examples/plugins/bookoo-mini.reaplugin/plugin.js',
  import.meta.url,
);

const source = readFileSync(pluginPath, 'utf8');
const createPlugin = new Function('host', `${source}\nreturn createPlugin(host);`);

const failures = [];
const unhandled = [];

process.on('unhandledRejection', (reason) => {
  unhandled.push(reason);
});

/// One event-loop turn, so anything scheduled by the plugin (microtasks and
/// immediate callbacks) has run before a result is inspected. No timed waits:
/// the scenarios advance on observed plugin activity instead.
const turn = () => new Promise((resolve) => setImmediate(resolve));

function check(name, condition, detail) {
  if (!condition) failures.push(`${name}: ${detail}`);
}

function loadDriver() {
  let binding;
  const host = {
    log() {},
    devices: {
      bindDriver(id, implementation) {
        binding = implementation;
      },
    },
  };
  const plugin = createPlugin(host);
  plugin.onLoad();
  return binding;
}

function bookooPacket(grams, battery = 50) {
  const magnitude = Math.round(Math.abs(grams) * 100);
  const packet = new Array(20).fill(0);
  packet[0] = 0x03;
  packet[1] = 0x0b;
  packet[6] = grams < 0 ? 0x2d : 0x2b;
  packet[7] = (magnitude >> 16) & 0xff;
  packet[8] = (magnitude >> 8) & 0xff;
  packet[9] = magnitude & 0xff;
  packet[13] = battery;
  packet[19] = packet.slice(0, 19).reduce((sum, byte) => sum ^ byte, 0);
  return Buffer.from(packet).toString('base64');
}

function makeSession({ subscribeError } = {}) {
  let subscriber;
  let onDisconnect;
  const published = [];
  const publishWaiters = [];
  let markSubscribed;
  const subscribed = new Promise((resolve) => {
    markSubscribed = resolve;
  });
  return {
    published,
    subscribed: () => subscribed,
    async waitForPublishes(count) {
      while (published.length < count) {
        await new Promise((resolve) => publishWaiters.push(resolve));
      }
    },
    gatt: {
      async discoverServices() {
        return ['00000ffe-0000-1000-8000-00805f9b34fb'];
      },
      async subscribe(service, characteristic, callback) {
        if (subscribeError) throw subscribeError;
        subscriber = callback;
        markSubscribed();
      },
      onDisconnect(callback) {
        onDisconnect = callback;
      },
    },
    async publish(snapshot) {
      published.push(snapshot);
      publishWaiters.splice(0).forEach((resolve) => resolve());
    },
    async reportDisconnected() {},
    emit(packet) {
      subscriber?.(packet, undefined);
    },
    disconnect() {
      onDisconnect?.();
    },
  };
}

async function scenarioSubscribeFailureThenDisconnect() {
  // Each scenario reports only its own rejections.
  unhandled.length = 0;

  const driver = loadDriver();
  const instance = driver.create({});
  const subscribeError = new Error('Bookoo subscription failed');
  const session = makeSession({ subscribeError });

  let connectError;
  try {
    await instance.connect(session);
  } catch (error) {
    connectError = error;
  }
  check(
    'subscribe failure is preserved',
    connectError === subscribeError,
    `connect rejected with ${connectError}`,
  );

  session.disconnect();
  await turn();

  check(
    'subscribe failure followed by disconnect leaves no unhandled rejection',
    unhandled.length === 0,
    `${unhandled.length} unhandled rejection(s): ${unhandled[0]}`,
  );
}

async function scenarioDisconnectBeforeFirstPacket() {
  // Each scenario reports only its own rejections.
  unhandled.length = 0;

  const driver = loadDriver();
  const instance = driver.create({});
  const session = makeSession();

  // Observe the outcome from the start: the rejection arrives while readiness
  // is still awaited, and an unobserved rejection would be reported as unhandled.
  const connecting = instance.connect(session).then(
    () => undefined,
    (error) => error,
  );
  await session.subscribed();
  session.disconnect();
  await turn();

  const connectError = await connecting;
  check(
    'disconnect before readiness is reported',
    connectError instanceof Error &&
      /disconnected before readiness/.test(connectError.message),
    `connect rejected with ${connectError}`,
  );
  check(
    'disconnect before readiness leaves no unhandled rejection',
    unhandled.length === 0,
    `${unhandled.length} unhandled rejection(s): ${unhandled[0]}`,
  );
}

async function scenarioSuccessfulFirstPacket() {
  // Each scenario reports only its own rejections.
  unhandled.length = 0;

  const driver = loadDriver();
  const instance = driver.create({});
  const session = makeSession();

  const connecting = instance.connect(session);
  await session.subscribed();
  session.emit(bookooPacket(12.34));
  await connecting;
  await session.waitForPublishes(1);

  check(
    'first packet publishes weight',
    session.published.length === 1 && session.published[0].weight === 12.34,
    JSON.stringify(session.published),
  );

  session.emit(bookooPacket(20));
  await session.waitForPublishes(2);
  check(
    'processing continues after readiness',
    session.published.length === 2 && session.published[1].weight === 20,
    JSON.stringify(session.published),
  );
  check(
    'successful startup leaves no unhandled rejection',
    unhandled.length === 0,
    `${unhandled.length} unhandled rejection(s): ${unhandled[0]}`,
  );
}

const scenarios = {
  subscribe: scenarioSubscribeFailureThenDisconnect,
  disconnect: scenarioDisconnectBeforeFirstPacket,
  ready: scenarioSuccessfulFirstPacket,
};
const selected = process.argv[2] ? [process.argv[2]] : Object.keys(scenarios);
for (const name of selected) {
  await scenarios[name]();
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  process.exit(1);
}
console.log('Bookoo readiness rejection lifecycle: OK');
