const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync('assets/plugins/settings.reaplugin/plugin.js', 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];

function runCheck(fetchImpl) {
  const toasts = [];
  const reloads = [];
  const timers = [];
  const context = vm.createContext({
    window: { location: { protocol: 'http:', host: 'localhost' } },
    location: { reload: () => reloads.push(1) },
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return 0; },
    document: {
      body: {
        appendChild: (el) => {
          toasts.push({
            message: el.textContent,
            isError: el.className === 'error-toast',
          });
        },
      },
      createElement: () => ({
        className: '',
        textContent: '',
        role: '',
        style: {},
        setAttribute() {},
        remove() {},
        checked: false,
      }),
      getElementById: () => ({
        textContent: '',
        value: '',
        style: {},
        checked: false,
      }),
      addEventListener: () => {},
    },
    confirm: () => true,
    fetch: fetchImpl,
  });
  vm.runInContext(script, context);
  return { context, toasts, reloads, timers };
}

test('checkSkinUpdates: no failures and nothing updated does not reload', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      message: 'checked',
      results: [
        { item: 'repo/one', status: 'alreadyCurrent' },
        { item: 'repo/two', status: 'alreadyCurrent' },
      ],
    }),
  }));
  await context.checkSkinUpdates();
  assert.equal(toasts[0].message, 'Checking for skin updates...');
  assert.equal(toasts[toasts.length - 1].message, 'Skin update check completed');
  assert.equal(toasts[toasts.length - 1].isError, false);
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 0);
});

test('checkSkinUpdates: an updated item schedules a reload', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      message: 'checked',
      results: [
        { item: 'repo/one', status: 'updated' },
        { item: 'repo/two', status: 'alreadyCurrent' },
      ],
    }),
  }));
  await context.checkSkinUpdates();
  assert.equal(toasts[toasts.length - 1].message, 'Skin update check completed');
  assert.equal(toasts[toasts.length - 1].isError, false);
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 1);
});

test('checkSkinUpdates: partial failure reports errors and does not reload', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      message: 'checked',
      results: [
        { item: 'repo/one', status: 'updated' },
        {
          item: 'repo/two',
          status: 'failed',
          error: 'The service could not complete the request. Try again later.',
        },
      ],
    }),
  }));
  await context.checkSkinUpdates();
  const final = toasts[toasts.length - 1];
  assert.ok(final.message.includes('Skin update check completed with errors: '));
  assert.ok(final.message.includes('repo/two'));
  assert.ok(
    final.message.includes(
      'The service could not complete the request. Try again later.',
    ),
  );
  assert.ok(
    final.message.includes('- reload to see the updates'),
    'partial failure must tell the user to reload manually',
  );
  assert.equal(final.isError, true);
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 0);
});

test('checkSkinUpdates: an unexpected success payload is not reported as success', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ message: 'checked' }),
  }));
  await context.checkSkinUpdates();
  const final = toasts[toasts.length - 1];
  assert.equal(final.isError, true);
  assert.ok(final.message.includes('unexpected response'));
  assert.ok(!final.message.includes('completed'));
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 0);
});

test('checkSkinUpdates: a non-array results field is not reported as success', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ results: 'not-an-array' }),
  }));
  await context.checkSkinUpdates();
  const final = toasts[toasts.length - 1];
  assert.equal(final.isError, true);
  assert.ok(final.message.includes('unexpected response'));
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 0);
});

test('checkSkinUpdates: all failed reports failure and does not reload', async () => {
  const { context, toasts, reloads, timers } = runCheck(async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      message: 'checked',
      results: [
        { item: 'repo/one', status: 'failed', error: 'offline' },
        { item: 'repo/two', status: 'failed', error: 'rate limited' },
      ],
    }),
  }));
  await context.checkSkinUpdates();
  const final = toasts[toasts.length - 1];
  assert.ok(final.message.startsWith('Skin update check failed: '));
  assert.ok(final.message.includes('repo/one'));
  assert.ok(final.message.includes('offline'));
  assert.ok(final.message.includes('repo/two'));
  assert.ok(final.message.includes('rate limited'));
  assert.equal(final.isError, true);
  for (const t of timers) t.fn();
  assert.equal(reloads.length, 0);
});
