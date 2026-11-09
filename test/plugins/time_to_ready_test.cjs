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

function loadPlugin(now, emitted, options = {}) {
  const source = fs.readFileSync(
    path.join(__dirname, '../../assets/plugins/time-to-ready.reaplugin/plugin.js'),
    'utf8',
  );
  const context = {
    Date: { now: () => now.value },
    console,
    createPlugin: undefined,
    setTimeout: () => 0,
    fetch: options.fetchAvailable === false
      ? undefined
      : () => Promise.resolve({
        json: () => Promise.resolve({ model: options.model ?? null }),
      }),
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

function temperatures(start, step, count) {
  return Array.from({ length: count }, (_, index) => start + index * step);
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

function assertNonIncreasing(values, message) {
  for (let index = 1; index < values.length; index++) {
    assert.ok(
      values[index].remainingTimeMs <= values[index - 1].remainingTimeMs,
      message + ' at index ' + index + ': ' + values[index - 1].remainingTimeMs +
        ' -> ' + values[index].remainingTimeMs,
    );
  }
}

test('slow and fast profiles track recent heating rates', () => {
  assert.equal(
    profilesFixture.header,
    "assumption: synthetic stress profile, not recorded data; grounded only in the issue's faster-ramp/denser-cadence Bengle premise",
  );

  const profiles = [profilesFixture.profiles[0], profilesFixture.profiles[3]];
  for (const profile of profiles) {
    const values = replaySynthetic(profile);
    const heatingValues = values.filter((value) => value.status === 'heating');
    const firstHeatingIndex = values.findIndex((value) => value.status === 'heating');
    assert.ok(
      firstHeatingIndex >= 7,
      profile.name + ' published before the rate window was established',
    );
    assert.ok(
      values.slice(0, firstHeatingIndex).every((value) => value.status === 'insufficient_data'),
      profile.name + ' did not report insufficient_data while rate was unestablished',
    );
    assert.ok(heatingValues.length > 0, profile.name + ' had no heating estimate');
    assert.ok(
      heatingValues.every((value) => value.heatingRate > 0),
      profile.name + ' reports a positive recent heating rate',
    );

    const finalHeating = heatingValues.at(-1);
    const finalRemainingSeconds =
      (profile.target - finalHeating.currentTemp) / profile.ramp;
    assert.ok(
      Math.abs(finalHeating.remainingTimeMs / 1000 - finalRemainingSeconds) <= 10000 / 1000,
      profile.name + ' final estimate missed the true remaining time by more than one ten-second step',
    );

    const midpoint = heatingValues.find(
      (value) => value.currentTemp >= profile.initial + (profile.target - profile.initial) / 2,
    );
    const midpointRemainingSeconds = (profile.target - midpoint.currentTemp) / profile.ramp;
    assert.ok(
      Math.abs(midpoint.remainingTimeMs / 1000 - midpointRemainingSeconds) <= 20000 / 1000,
      profile.name + ' midpoint estimate missed the true remaining time by more than two ten-second steps',
    );

    const floorCandidates = heatingValues.filter(
      (value) => profile.target - value.currentTemp > (profile === profiles[0] ? 5 : 10),
    );
    assert.ok(
      floorCandidates.every((value) => value.remainingTimeMs >= 10000),
      profile.name + ' collapsed below the ten-second rounded floor too early',
    );
    console.log(
      `${profile.name}: midpoint=${midpoint.remainingTimeMs / 1000}s, final=${finalHeating.remainingTimeMs / 1000}s, finalRate=${finalHeating.heatingRate.toFixed(3)} K/s`,
    );
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
  replay(plugin, now, temperatures(20.5, 0.5, 20), 1000);
  const oldSession = estimates(emitted).filter((value) => value.status === 'heating');
  assert.ok(oldSession.length > 0);

  plugin.onEvent({ name: 'stateUpdate', payload: payload(30, 71) });
  assert.equal(estimates(emitted).at(-1).status, 'insufficient_data');
  now.value += 1000;
  replay(plugin, now, temperatures(30.5, 0.5, 20), 1000, 71);

  const newSession = estimates(emitted).filter((value) => value.status === 'heating').slice(oldSession.length);
  assert.ok(newSession.length > 1);
  assertNonIncreasing(newSession, 'target-reset session increased');
});

test('the estimator clamps countdowns to five and three hundred seconds', () => {
  const slowNow = { value: 0 };
  const slowEmitted = [];
  const slowPlugin = loadPlugin(slowNow, slowEmitted);
  ready(slowPlugin, 20);
  for (let index = 1; index <= 80; index++) {
    slowPlugin.onEvent({
      name: 'stateUpdate',
      payload: payload(20 + index * 0.1),
    });
    slowNow.value += 1000;
  }
  expectClamped(slowEmitted, 300000, 'slow ramp');

  const fastNow = { value: 0 };
  const fastEmitted = [];
  const fastPlugin = loadPlugin(fastNow, fastEmitted);
  ready(fastPlugin, 20);
  for (let index = 1; index <= 99; index++) {
    fastPlugin.onEvent({
      name: 'stateUpdate',
      payload: payload(20 + index * 0.5),
    });
    fastNow.value += 500;
  }
  expectClamped(fastEmitted, 5000, 'fast ramp');
});

function expectClamped(emitted, bound, label) {
  const heating = estimates(emitted).filter((value) => value.status === 'heating');
  assert.ok(heating.length > 0, label + ' published no estimate');
  assert.equal(heating.at(-1).remainingTimeMs, bound, label + ' did not clamp');
  for (const value of heating) {
    assert.ok(
      value.remainingTimeMs >= 5000 && value.remainingTimeMs <= 300000,
      label + ' published outside the clamp band',
    );
  }
}

test('a noisy synthetic trace remains non-increasing', () => {
  const values = replaySynthetic(edgeCasesFixture.scenarios.noisyStartup);
  const heatingValues = values.filter((value) => value.status === 'heating');
  assert.ok(heatingValues.length > 1);
  assertNonIncreasing(heatingValues, 'noisy trace increased');
});

test('a machine slowdown cannot raise the session ceiling', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  ready(plugin, 20);
  const temperatures = [];
  for (let index = 0; index < 20; index++) temperatures.push(20 + index * 0.2);
  for (let index = 1; index <= 40; index++) temperatures.push(23.8 + index * 0.05);
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

test('heating is detected from temperature alone, not from a heating state', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  const idle = (temperature, target) => ({
    state: { state: 'idle', substate: 'preparingForShot' },
    groupTemperature: temperature,
    targetGroupTemperature: target,
  });

  for (const temperature of temperatures(44, 2, 20)) {
    plugin.onEvent({ name: 'stateUpdate', payload: idle(temperature, 92) });
    now.value += 1000;
  }

  const heating = estimates(emitted).filter((value) => value.status === 'heating');
  assert.ok(
    heating.length > 0,
    'a machine reporting idle/preparingForShot while heating must still publish a countdown',
  );
  assertNonIncreasing(heating, 'idle-state heating increased');
});

test('a cold start without a prior ready still publishes an estimate', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  for (const temperature of [23, 25, 27, 29, 31, 33, 35, 37]) {
    plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature, 92, 'idle') });
    now.value += 1000;
  }
  const value = estimates(emitted).at(-1);
  assert.equal(value.status, 'heating');
  assert.ok(value.remainingTimeMs > 0);
});

test('a fast machine ticking at 15 Hz publishes through a cold-start plateau', () => {
  const now = { value: 0 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted);
  const target = 93;
  const tick = 67;
  let temperature = 54.7;

  for (let index = 0; index < 300; index++) {
    plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature, target, 'idle') });
    now.value += tick;
  }
  const rampStart = now.value;
  for (let index = 0; index < 4000 && temperature < target; index++) {
    temperature = Math.min(target, temperature + 0.5 * (tick / 1000));
    plugin.onEvent({ name: 'stateUpdate', payload: payload(temperature, target, 'idle') });
    now.value += tick;
  }

  const values = estimates(emitted);
  const heating = values.filter((value) => value.status === 'heating');
  assert.ok(heating.length > 0, 'a 15 Hz ramp published no estimate');
  const first = values.find((value) => value.status === 'heating');
  const firstSecondsAfterRamp = (first.timestamp - rampStart) / 1000;
  assert.ok(
    firstSecondsAfterRamp < 20,
    'first estimate took ' + firstSecondsAfterRamp.toFixed(1) + ' s to appear',
  );
  const trueRemaining = (target - first.currentTemp) / 0.5;
  assert.ok(
    Math.abs(first.remainingTimeMs / 1000 - trueRemaining) <= 20,
    'first estimate ' + first.remainingTimeMs / 1000 +
      ' s missed the true ' + trueRemaining.toFixed(0) + ' s by more than two steps',
  );
  assertNonIncreasing(heating, '15 Hz ramp increased');
});

const recordedDirectory = path.join(fixtureDirectory, 'recorded');
const recordedFixtures = ['bengle_cold_start.json', 'de1_cold_start.json', 'de1_reheat_tail.json']
  .map((name) => ({
    name,
    data: JSON.parse(fs.readFileSync(path.join(recordedDirectory, name), 'utf8')),
  }));

async function replayRecorded(series, options = {}) {
  const now = { value: series.series[0].t * 1000 };
  const emitted = [];
  const plugin = loadPlugin(now, emitted, {
    model: options.model,
    fetchAvailable: options.fetchAvailable ?? true,
  });
  plugin.onLoad({});
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  for (const sample of series.series) {
    now.value = sample.t * 1000;
    plugin.onEvent({
      name: 'stateUpdate',
      payload: {
        state: { state: 'idle' },
        groupTemperature: sample.temp,
        targetGroupTemperature: sample.target,
      },
    });
  }
  const last = series.series.at(-1);
  now.value = (last.t + 0.5) * 1000;
  plugin.onEvent({
    name: 'stateUpdate',
    payload: {
      state: { state: 'idle' },
      groupTemperature: series.target,
      targetGroupTemperature: series.target,
    },
  });
  return {
    values: estimates(emitted),
    endTime: last.t * 1000,
    target: series.target,
  };
}

test('recorded device ramps replay without an upward countdown', async () => {
  for (const fixture of recordedFixtures) {
    assert.equal(fixture.data.recorded, true, fixture.name + ' is not marked as recorded');
    const { values } = await replayRecorded(fixture.data);
    const heating = values.filter((value) => value.status === 'heating');
    assert.ok(heating.length > 0, fixture.name + ' published no countdown');
    assertNonIncreasing(heating, fixture.name);
    assert.equal(values.at(-1).status, 'reached', fixture.name + ' never reported reached');
  }
});

test('a recorded Bengle ramp tracks the real remaining time', async () => {
  const fixture = recordedFixtures.find((entry) => entry.name === 'bengle_cold_start.json');
  const { values, endTime } = await replayRecorded(fixture.data, { model: 'Bengle' });
  const heating = values.filter((value) => value.status === 'heating');

  const first = heating[0];
  const firstError = first.remainingTimeMs / 1000 - (endTime - first.timestamp) / 1000;
  assert.ok(
    Math.abs(firstError) <= 30,
    'first estimate was ' + firstError.toFixed(0) + ' s off the recorded ramp',
  );

  const mid = heating[Math.floor(heating.length * 0.5)];
  const midError = mid.remainingTimeMs / 1000 - (endTime - mid.timestamp) / 1000;
  assert.ok(
    Math.abs(midError) <= 15,
    'midpoint estimate was ' + midError.toFixed(0) + ' s off',
  );

  const floorWithWorkLeft = heating.filter(
    (value) => fixture.data.target - value.currentTemp > 20 &&
      value.remainingTimeMs <= 10000,
  );
  assert.equal(
    floorWithWorkLeft.length,
    0,
    'the countdown sat on the ten second floor with more than 20 K remaining',
  );

  console.log(
    'bengle_cold_start.json: samples=' + fixture.data.series.length +
      ' heating=' + heating.length +
      ' first=' + first.remainingTimeMs / 1000 +
      's mid=' + mid.remainingTimeMs / 1000 + 's',
  );
});

test('a recorded DE1 ramp uses the deceleration allowance', async () => {
  const fixture = recordedFixtures.find((entry) => entry.name === 'de1_cold_start.json');
  const series = fixture.data.series;
  const target = fixture.data.target;
  const reached = series.find((sample) => sample.temp >= target - 0.5);
  const reachedAt = (reached ? reached.t : series.at(-1).t) * 1000;

  const { values } = await replayRecorded(fixture.data, { model: 'DE1Pro' });
  const heating = values.filter(
    (value) => value.status === 'heating' && value.timestamp <= reachedAt,
  );
  assert.ok(heating.length > 0, 'the DE1 recording published no countdown');

  for (const fraction of [0.25, 0.5, 0.75]) {
    const estimate = heating[Math.floor((heating.length - 1) * fraction)];
    const trueRemaining = Math.max(0, (reachedAt - estimate.timestamp) / 1000);
    const error = estimate.remainingTimeMs / 1000 - trueRemaining;
    assert.ok(
      Math.abs(error) <= 20,
      'DE1 estimate at ' + fraction * 100 + '% was ' + error.toFixed(0) + ' s off',
    );
  }

  const rises = heating.filter(
    (value, index) => index > 0 &&
      value.remainingTimeMs > heating[index - 1].remainingTimeMs,
  );
  assert.ok(
    rises.length < heating.length * 0.05,
    'the deceleration allowance raised the countdown too often: ' + rises.length,
  );
});

test('a Bengle never receives the deceleration allowance', async () => {
  const fixture = recordedFixtures.find((entry) => entry.name === 'bengle_cold_start.json');
  const { values } = await replayRecorded(fixture.data, { model: 'Bengle' });
  const heating = values.filter((value) => value.status === 'heating');
  assertNonIncreasing(heating, 'Bengle received an upward correction');
});

test('without machine info the estimator stays on the conservative path', async () => {
  const fixture = recordedFixtures.find((entry) => entry.name === 'de1_cold_start.json');
  const { values } = await replayRecorded(fixture.data, { fetchAvailable: false });
  const heating = values.filter((value) => value.status === 'heating');
  assert.ok(heating.length > 0, 'no estimate without machine info');
  assertNonIncreasing(heating, 'unknown model received an upward correction');
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
