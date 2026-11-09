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

function replaySynthetic(profile, sampleCount = null) {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  const temperatures = temperaturesFor(profile);
  replay(
    plugin,
    now,
    sampleCount === null ? temperatures : temperatures.slice(0, sampleCount),
    profile.cadenceSeconds * 1000,
    profile.target,
  );
  return estimates(emitted);
}

test('synthetic cold starts publish stable estimates with the retained slow-ramp cap', () => {
  assert.equal(
    profilesFixture.header,
    "assumption: synthetic stress profile, not recorded data; grounded only in the issue's faster-ramp/denser-cadence Bengle premise",
  );

  for (const profile of profilesFixture.profiles) {
    const values = replaySynthetic(profile);
    const reachedIndex = values.findIndex((value) => value.status === 'reached');
    const firstNumber = values.findIndex((value) => value.remainingTimeMs !== null);

    assert.ok(reachedIndex >= 0, `${profile.name} never reached the target`);
    assert.ok(firstNumber >= 7, `${profile.name} published before eight samples`);
    assert.ok(values[firstNumber].timestamp >= 5000, `${profile.name} published before five seconds`);
    assert.ok(values.slice(0, firstNumber).every((value) => value.status === 'insufficient_data'));
    assert.ok(
      Math.abs(values[firstNumber].heatingRate - profile.ramp) / profile.ramp <= 0.1,
      `${profile.name} first slope was not within 10% of the synthetic rate`,
    );

    const heatingValues = values.slice(firstNumber, reachedIndex);
    assert.ok(heatingValues.length > 0, `${profile.name} had no heating estimate before reached`);
    assert.ok(heatingValues.every((value) => value.remainingTimeMs !== null));
    assert.ok(heatingValues.every((value) => value.status === 'heating'));
    for (let index = 1; index < heatingValues.length; index++) {
      assert.ok(
        heatingValues[index].remainingTimeMs - heatingValues[index - 1].remainingTimeMs <= 3000,
        `${profile.name} had an upward correction larger than three seconds`,
      );
    }
    assert.equal(values[reachedIndex].remainingTimeMs, 0);
    assert.equal(values[reachedIndex].status, 'reached');

    if (profile.name.startsWith('DE1-like slow')) {
      let sawCappedEstimate = false;
      let sawAccurateEstimateBelowCap = false;
      for (const value of heatingValues) {
        const trueRemainingTimeMs = (profile.target - value.currentTemp) / profile.ramp * 1000;
        if (trueRemainingTimeMs >= 300000) {
          sawCappedEstimate = true;
          assert.equal(value.remainingTimeMs, 300000);
        } else {
          sawAccurateEstimateBelowCap = true;
          assert.ok(
            Math.abs(value.remainingTimeMs - trueRemainingTimeMs) / trueRemainingTimeMs <= 0.1,
            `slow DE1 estimate was not accurate below the cap: ${value.remainingTimeMs} vs ${trueRemainingTimeMs}`,
          );
        }
      }
      assert.ok(sawCappedEstimate, 'slow DE1 fixture did not exercise the display cap');
      assert.ok(sawAccurateEstimateBelowCap, 'slow DE1 fixture did not exercise below-cap accuracy');
    } else {
      for (const value of heatingValues) {
        const trueRemainingTimeMs = (profile.target - value.currentTemp) / profile.ramp * 1000;
        assert.ok(
          Math.abs(value.remainingTimeMs - trueRemainingTimeMs) / trueRemainingTimeMs <= 0.1,
          `${profile.name} estimate was not accurate: ${value.remainingTimeMs} vs ${trueRemainingTimeMs}`,
        );
      }
    }
  }
});

test('a noisy positive startup stays indeterminate until its trend is stable', () => {
  const scenario = edgeCasesFixture.scenarios.noisyStartup;
  const values = replaySynthetic(scenario);
  const firstNumber = values.findIndex((value) => value.remainingTimeMs !== null);

  assert.ok(firstNumber > scenario.startupJitter.length - 1);
  assert.equal(values[firstNumber].status, 'heating');
  assert.ok(values.slice(0, scenario.startupJitter.length).every(
    (value) => value.status === 'insufficient_data',
  ));
  assert.ok(firstNumber >= 7);
  assert.ok(values[firstNumber].timestamp >= 5000);
});

test('persistent alternating noise cannot pass the positive-trend gate', () => {
  const scenario = edgeCasesFixture.scenarios.alternatingNoise;
  const values = replaySynthetic(scenario, 40);

  assert.equal(values.length, 40);
  assert.ok(values.every((value) => value.status === 'insufficient_data'));
});

test('flat and cooling trends remain indeterminate', () => {
  for (const temperatures of [
    [20, 20.2, 20.1, 20.15, 20.1, 20.05, 20.1, 20.05, 20, 20.05],
    [30, 29.8, 29.6, 29.4, 29.2, 29, 28.8, 28.6, 28.4, 28.2],
  ]) {
    const now = { value: 0 };
    const emitted = [];
    const plugin = loadPlugin(now, emitted);
    replay(plugin, now, temperatures, 1000);
    assert.equal(estimates(emitted).length, temperatures.length);
    assert.ok(estimates(emitted).every((value) => value.status === 'insufficient_data'));
  }
});

test('eight samples in under five seconds remain insufficient', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2, 21.4], 500);

  const values = estimates(emitted);
  assert.equal(values.length, 8);
  assert.ok(values.every((value) => value.status === 'insufficient_data'));
});

test('seven samples spanning over five seconds remain insufficient', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2], 1000);

  const values = estimates(emitted);
  assert.equal(values.length, 7);
  assert.equal(values.at(-1).timestamp, 6000);
  assert.equal(values.at(-1).status, 'insufficient_data');
});

test('duplicate timestamps do not increase sample count', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2], 1000);

  now.value -= 1000;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.2) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');

  now.value += 1000;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.4) });
  assert.equal(estimates(emitted).at(-1).status, 'heating');
});

test('irregular timestamps regress the actual elapsed-time slope', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  for (const [timestamp, temperature] of [
    [0, 20],
    [500, 20.1],
    [1700, 20.34],
    [2600, 20.52],
    [5200, 21.04],
    [7000, 21.4],
    [9100, 21.82],
    [12000, 22.4],
  ]) {
    now.value = timestamp;
    plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature) });
  }

  const value = estimates(emitted).at(-1);
  assert.equal(value.status, 'heating');
  assert.ok(Math.abs(value.heatingRate - 0.2) < 1e-12);
  assert.equal(value.remainingTimeMs, 238000);
});

test('clock rollback resets the trend', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2, 21.4], 1000);
  assert.equal(estimates(emitted).at(-1).status, 'heating');

  now.value -= 1500;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.5) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
});

test('target changes and new heating sessions discard prior confidence', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2, 21.4], 1000);
  assert.equal(estimates(emitted).at(-1).status, 'heating');

  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.5, 71) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
  replay(plugin, now, [21.7, 21.9, 22.1, 22.3, 22.5, 22.7, 22.9, 23.1, 23.3, 23.5], 1000, 71);
  assert.equal(estimates(emitted).at(-1).status, 'heating');

  plugin.onEvent({ name: 'stateUpdate', payload: payload(23, 71, 'sleeping') });
  const beforeNewSession = estimates(emitted).length;
  replay(plugin, now, [23, 23.2, 23.4, 23.6, 23.8, 24, 24.2, 24.4], 1000, 71);
  const newSession = estimates(emitted).slice(beforeNewSession);
  assert.ok(newSession.slice(0, 7).every((value) => value.status === 'insufficient_data'));
  assert.equal(newSession.at(-1).status, 'heating');
});

test('a confident slowdown may raise the estimate within the correction band', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  const temperatures = [];
  for (let index = 0; index < 20; index++) {
    temperatures.push(20 + index * 0.2);
  }
  for (let index = 1; index <= 40; index++) {
    temperatures.push(23.8 + index * 0.18);
  }
  replay(plugin, now, temperatures, 1000);

  const values = estimates(emitted);
  const firstNumber = values.findIndex((value) => value.remainingTimeMs !== null);
  const heatingValues = values.slice(firstNumber).filter((value) => value.status === 'heating');
  const risingCorrections = [];
  for (let index = 1; index < heatingValues.length; index++) {
    const correction = heatingValues[index].remainingTimeMs - heatingValues[index - 1].remainingTimeMs;
    if (correction > 0) risingCorrections.push(correction);
  }

  assert.ok(firstNumber >= 0);
  assert.ok(risingCorrections.length > 0);
  assert.ok(risingCorrections.every((correction) => correction <= 3000));
});

test('stale observations reset the trend instead of borrowing confidence', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  replay(plugin, now, [20, 20.2, 20.4, 20.6, 20.8, 21, 21.2, 21.4], 1000);
  assert.equal(estimates(emitted).at(-1).status, 'heating');

  now.value += 20000;
  plugin.onEvent({ name: 'stateUpdate', payload: payload(21.6) });
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
