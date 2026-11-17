const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync('assets/plugins/settings.reaplugin/plugin.js', 'utf8');

for (const state of ['authenticated', 'signed out', 'unavailable', 'offline']) {
  test(`settings feedback: ${state}`, async () => {
    const context = vm.createContext({
      fetch: async (url) => {
        if (url.endsWith('/account/decent')) {
          if (state === 'offline') throw new Error('offline');
          return {
            ok: state !== 'unavailable',
            json: async () => ({ loggedIn: state === 'authenticated' }),
          };
        }
        return { ok: false, status: 503 };
      },
    });
    vm.runInContext(source, context);
    const plugin = context.createPlugin({ log() {} });
    const response = await plugin.__httpRequestHandler({ endpoint: 'ui', method: 'GET', query: {} });
    assert.equal(response.status, 200);
    assert.equal(response.body.includes('id="feedbackText"'), state === 'authenticated');
    assert.equal(response.body.includes('>Submit Feedback</button>'), state === 'authenticated');
    if (state === 'authenticated') {
      assert.match(response.body, /Only the support message ID, when available, is added to the public issue/);
      assert.doesNotMatch(response.body, /reference associated with your account/);
    }
    if (state !== 'authenticated') {
      assert.match(response.body, /Sign in under Decent Account/);
    }
  });
}
