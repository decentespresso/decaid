const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync('assets/plugins/settings.reaplugin/plugin.js', 'utf8');

function renderUi(calibrationResponse) {
  const calls = [];
  const context = vm.createContext({
    fetch: async (url, init) => {
      calls.push({ url, method: (init && init.method) || 'GET' });
      if (url.endsWith('/api/v1/machine/calibration')) {
        return calibrationResponse();
      }
      return { ok: false, status: 503 };
    },
  });
  vm.runInContext(source, context);
  const plugin = context.createPlugin({ log() {} });
  return { plugin, calls };
}

async function renderSettingsPage(calibrationResponse) {
  const { plugin, calls } = renderUi(calibrationResponse);
  const response = await plugin.__httpRequestHandler({
    endpoint: 'ui',
    method: 'GET',
    query: {},
  });
  assert.equal(response.status, 200);
  return { body: response.body, calls };
}

test('settings page shows the machine reported flow multiplier', async () => {
  const { body, calls } = await renderSettingsPage(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ flowMultiplier: 0.8 }),
  }));

  assert.match(body, /id="flowMultiplier" value="0\.8"/);
  assert.match(body, /Save flow estimation multiplier/);
  assert.deepEqual(
    calls.filter((call) => call.method !== 'GET').map((call) => call.method),
    [],
  );
  assert.equal(
    calls.filter((call) => call.method === 'POST').length,
    0,
    'loading the settings page must never write a calibration value',
  );
});

test('settings page does not invent 1.0 when the read fails', async () => {
  const { body, calls } = await renderSettingsPage(async () => ({
    ok: false,
    status: 503,
  }));

  assert.doesNotMatch(body, /id="flowMultiplier"/);
  assert.doesNotMatch(body, /Save flow estimation multiplier/);
  assert.match(body, /Failed to load calibration settings/);
  assert.equal(calls.filter((call) => call.method === 'POST').length, 0);
});

test('settings page reports unavailable when the machine sends no value', async () => {
  const { body } = await renderSettingsPage(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ flowMultiplier: null }),
  }));

  assert.doesNotMatch(body, /id="flowMultiplier"/);
  assert.doesNotMatch(body, /Save flow estimation multiplier/);
  assert.match(body, /Flow estimation multiplier unavailable/);
});

test('settings page rejects a non-numeric multiplier instead of showing one', async () => {
  const { body, calls } = await renderSettingsPage(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ flowMultiplier: 'not-a-number' }),
  }));

  assert.doesNotMatch(body, /id="flowMultiplier"/);
  assert.doesNotMatch(body, /Save flow estimation multiplier/);
  assert.match(body, /Flow estimation multiplier unavailable/);
  assert.equal(calls.filter((call) => call.method === 'POST').length, 0);
});

test('settings page rejects every unusable multiplier value', async () => {
  const cases = [
    ['missing key', {}],
    ['zero', { flowMultiplier: 0 }],
    ['negative', { flowMultiplier: -1 }],
    ['above the maximum', { flowMultiplier: 2.1 }],
    ['NaN', { flowMultiplier: Number.NaN }],
    ['a numeric string', { flowMultiplier: '0.8' }],
    ['null', { flowMultiplier: null }],
  ];

  for (const [label, payload] of cases) {
    const { body, calls } = await renderSettingsPage(async () => ({
      ok: true,
      status: 200,
      json: async () => payload,
    }));

    assert.doesNotMatch(
      body,
      /id="flowMultiplier"/,
      `${label} must not show the multiplier input`,
    );
    assert.doesNotMatch(
      body,
      /Save flow estimation multiplier/,
      `${label} must not offer the Save action`,
    );
    assert.match(body, /Flow estimation multiplier unavailable/, label);
    assert.equal(calls.filter((call) => call.method === 'POST').length, 0, label);
  }
});

test('settings page accepts the inclusive range endpoints', async () => {
  for (const flowMultiplier of [0.13, 2.0]) {
    const { body } = await renderSettingsPage(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ flowMultiplier }),
    }));

    assert.ok(
      body.includes(`id="flowMultiplier" value="${flowMultiplier}"`),
      `${flowMultiplier} must be shown as the current multiplier`,
    );
    assert.match(body, /Save flow estimation multiplier/);
  }
});

test('settings page save action rejects an out of range input', async () => {
  const { body } = await renderSettingsPage(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ flowMultiplier: 0.8 }),
  }));

  assert.match(
    body,
    /value >= 0\.13 && value <= 2\.0/,
    'the page Save action must range guard the posted multiplier',
  );
});
