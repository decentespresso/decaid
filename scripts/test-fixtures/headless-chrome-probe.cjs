const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.HEADLESS_CHROME_PLAYWRIGHT_MODULE);

function descendants() {
  const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,pgid='], { encoding: 'utf8' })
    .trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const pids = new Set([process.pid]);
  let added;
  do {
    added = false;
    for (const [pid, parent] of rows) {
      if (pids.has(parent) && !pids.has(pid)) {
        pids.add(pid);
        added = true;
      }
    }
  } while (added);
  return {
    pids: [...pids],
    groups: [...new Set(rows.filter(([pid]) => pids.has(pid)).map(([, , group]) => group))],
  };
}

(async () => {
  const context = await chromium.launchPersistentContext(process.env.CHROME_PROFILE, {
    executablePath: process.env.CHROME_BIN,
    headless: true,
  });
  const browser = context.browser();
  try {
    const page = context.pages()[0];
    await page.setContent('<title>Wrapper probe</title><h1>Browser ready</h1>');
    assert.equal(await page.locator('h1').textContent(), 'Browser ready');
    console.log(JSON.stringify({ pid: process.pid, profile: process.env.CHROME_PROFILE, ...descendants() }));
    if (process.env.HEADLESS_CHROME_PROBE_MODE === 'hold') await new Promise(() => {});
    if (process.env.HEADLESS_CHROME_PROBE_MODE === 'fail') throw new Error('intentional probe failure');
  } finally {
    await context.close();
    if (browser) await browser.close();
  }
})().catch(error => {
  console.error(error.message);
  process.exitCode = 7;
});
