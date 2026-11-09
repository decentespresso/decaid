const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const fixtureDirectory = path.join(__dirname, 'fixtures');
const profilesFixture = JSON.parse(fs.readFileSync(
  path.join(fixtureDirectory, 'time_to_ready_synthetic_profiles.json'),
  'utf8',
));
const edgeCasesFixture = JSON.parse(fs.readFileSync(
  path.join(fixtureDirectory, 'time_to_ready_synthetic_edge_cases.json'),
  'utf8',
));

function loadPlugin(now, emitted) {
  const source = fs.readFileSync(
    path.join(__dirname, '../../assets/plugins/time-to-ready.reaplugin/plugin.js'),
    'utf8',
  );
  const context = {
    Date: { now: () => now.value },
    console,
    createPlugin: undefined,
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  return context.createPlugin({
    log() {},
    emit(name, payload) {
      emitted.push({ name, payload });
    },
    storage() {},
  });
}

function payload(temperature, target = 70, machineState = 'heating') {
  return {
    state: { state: machineState },
    groupTemperature: temperature,
    targetGroupTemperature: target,
  };
}

function ready(plugin, temperature, target = 70) {
  plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature, target, 'ready') });
}

function replay(plugin, now, temperatures, cadenceMs, target = 70) {
  for (const temperature of temperatures) {
    plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature, target) });
    now.value += cadenceMs;
  }
}

function estimates(emitted) {
  return emitted.filter((event) => event.name === 'timeToReady').map((event) => event.payload);
}

function temperaturesFor(profile) {
  const temperatures = [];
  const startupJitter = profile.startupJitter || [];
  const ongoingJitter = profile.ongoingJitter || [];
  for (let index = 0; ; index++) {
    const base = profile.initial + profile.ramp * index * profile.cadenceSeconds;
    if (base >= profile.target) {
      temperatures.push(profile.target);
      return temperatures;
    }
    const jitter = index < startupJitter.length
      ? startupJitter[index]
      : ongoingJitter[(index - startupJitter.length) % ongoingJitter.length];
    temperatures.push(base + jitter);
  }
}

function replaySynthetic(profile) {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  ready(plugin, profile.initial, profile.target);
  replay(plugin, now, temperaturesFor(profile), profile.cadenceSeconds * 1000, profile.target);
  return estimates(emitted);
}

function canonicalSeconds(startTime, startTemp, value) {
  if (value.currentTemp >= value.targetTemp) return 0;
  const elapsed = Math.max(1, (value.timestamp - startTime) / 1000);
  const warmed = Math.max(1, value.currentTemp - startTemp);
  const togo = Math.min(Math.max((value.targetTemp - 10) - value.currentTemp, 1), 100);
  const progress = warmed / togo;
  return Math.min(Math.max(Math.round(Math.trunc(elapsed / progress) / 10) * 10, 5), 300);
}

function assertNonIncreasing(values, message) {
  for (let index = 1; index < values.length; index++) {
    assert.ok(
      values[index].remainingTimeMs <= values[index - 1].remainingTimeMs,
      message + ' at index ' + index + ': ' + values[index - 1].remainingTimeMs +
        ' -> ' + values[index].remainingTimeMs,
    );
  }
}

test('canonical formula reproduces each synthetic trace within one round-to-tens step', () => {
  assert.equal(
    profilesFixture.header,
    "assumption: synthetic stress profile, not recorded data; grounded only in the issue's faster-ramp/denser-cadence Bengle premise",
  );

  for (const profile of profilesFixture.profiles) {
    const values = replaySynthetic(profile);
    const heatingValues = values.filter((value) => value.status === 'heating');
    let ceiling = null;
    for (const value of heatingValues) {
      const canonical = canonicalSeconds(0, profile.initial, value);
      ceiling = ceiling === null ? canonical : Math.min(ceiling, canonical);
      assert.ok(
        Math.abs(value.remainingTimeMs - ceiling * 1000) <= 10000,
        profile.name + ' exceeded one round-to-tens step',
      );
      assert.ok(
        value.heatingRate > 0,
        profile.name + ' reports a positive average heating rate',
      );
    }
    assert.ok(heatingValues.length > 0, profile.name + ' had no heating estimate');
    assert.equal(values.at(-1).status, 'reached');
  }
});

test('a full synthetic ramp never increases its published countdown', () => {
  for (const profile of profilesFixture.profiles) {
    const heatingValues = replaySynthetic(profile).filter((value) => value.status === 'heating');
    assertNonIncreasing(heatingValues, profile.name);
  }
});

test('a target change resets the reference and the new session has its own ceiling', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  ready(plugin, 20, 70);
  replay(plugin, now, [20.2, 20.4, 20.6, 20.8, 21, 21.2, 21.4], 1000);
  const oldSession = estimates(emitted).filter((value) => value.status === 'heating');
  assert.ok(oldSession.length > 0);

  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.4, 71) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
  ready(plugin, 21.4, 71);
  now.value += 1000;
  replay(plugin, now, [21.6, 21.8, 22, 22.2, 22.4, 22.6, 22.8], 1000, 71);

  const newSession = estimates(emitted).filter((value) => value.status === 'heating').slice(oldSession.length);
  assert.ok(newSession.length > 1);
  assertNonIncreasing(newSession, 'target-reset session increased');
});

test('the estimator clamps countdowns to five and three hundred seconds', () => {
  const lowNow = { value: 0 };
  const lowEmitted = [];
  const lowPlugin = loadPlugin(lowNow, lowEmitted);
  ready(lowPlugin, 20);
  lowNow.value = 10000;
  lowPlugin.onEvent({ name: 'stateUpdate', payload: payload(20.1) });
  assert.equal(estimates(lowEmitted).at(-1).remainingTimeMs, 300000);

  const highNow = { value: 0 };
  const highEmitted = [];
  const highPlugin = loadPlugin(highNow, highEmitted);
  ready(highPlugin, 20);
  highPlugin.onEvent({ name: 'stateUpdate', payload: payload(69.9) });
  assert.equal(estimates(highEmitted).at(-1).remainingTimeMs, 5000);
});

test('a noisy synthetic trace remains non-increasing', () => {
  const values = replaySynthetic(edgeCasesFixture.scenarios.noisyStartup);
  const heatingValues = values.filter((value) => value.status === 'heating');
  assert.ok(heatingValues.length > 1);
  assertNonIncreasing(heatingValues, 'noisy trace increased');
});

test('the pre-change slope path is distinguished by a strict no-upward-jump trace', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  ready(plugin, 20);
  const temperatures = [];
  for (let index = 0; index < 20; index++) temperatures.push(20 + index * 0.2);
  for (let index = 1; index <= 40; index++) temperatures.push(23.8 + index * 0.18);
  replay(plugin, now, temperatures, 1000);

  const heatingValues = estimates(emitted).filter((value) => value.status === 'heating');
  assertNonIncreasing(heatingValues, 'slowdown trace increased');
});

test('cooling, sleeping, and missing state remain insufficient and sleeping resets the reference', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  ready(plugin, 20);
  now.value = 1000;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(20.2, 70, 'cooling') });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
  plugin.onEvent({ name: 'stateUpdate', payload: payload(20.2, 70, 'sleeping') });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
  now.value = 2000;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(20.4) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
});

test('reached state publishes zero remaining time', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  plugin.onEvent({ name: 'stateUpdate', payload: payload(70) });
  const value = estimates(emitted).at(-1);

  assert.equal(value.remainingTimeMs, 0);
  assert.equal(value.heatingRate, 0);
  assert.equal(value.status, 'reached');
});
