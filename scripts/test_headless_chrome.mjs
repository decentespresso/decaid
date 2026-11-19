#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

const wrapper = join(dirname(fileURLToPath(import.meta.url)), 'headless-chrome.sh');

function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'decaid-headless-chrome-test-')));
  const cleanups = [];
  t.after(async () => {
    for (const cleanup of cleanups.reverse()) await cleanup();
    rmSync(root, { recursive: true, force: true });
  });
  const env = { ...process.env, CHROME_BIN: process.execPath, CHROME_RUNTIME_DIR: join(root, 'runtime') };
  delete env.CHROME_PROFILE;
  return { root, env, cleanups };
}

function run(env, code, timeout = 10000, script = wrapper) {
  const result = spawnSync('/bin/bash', [script, 'run', '--', process.execPath, '-e', code], {
    env, encoding: 'utf8', timeout,
  });
  assert.equal(result.error, undefined, result.error?.message);
  return result;
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

async function until(predicate, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for process state');
    await delay(20);
  }
}

async function start(state, code) {
  const child = spawn('/bin/bash', [wrapper, 'run', '--', process.execPath, '-e', code], {
    env: state.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const run = { child, stdout: '', stderr: '', exit: null, ready: null };
  child.stdout.on('data', data => {
    run.stdout += data;
    if (!run.ready && run.stdout.includes('\n')) run.ready = JSON.parse(run.stdout.split('\n')[0]);
  });
  child.stderr.on('data', data => { run.stderr += data; });
  child.on('exit', (code, signal) => { run.exit = { code, signal }; });
  state.cleanups.push(async () => {
    for (const signal of ['SIGTERM', 'SIGKILL']) {
      for (const pid of [run.ready?.pid, child.pid].filter(Number.isInteger)) {
        try { process.kill(pid, signal); } catch {}
        try { process.kill(-pid, signal); } catch {}
      }
      await delay(100);
    }
    child.stdout.destroy();
    child.stderr.destroy();
  });
  await until(() => run.ready || run.exit, 15000);
  assert.ok(run.ready, run.stderr);
  return run;
}

test('standalone path allocation is rejected without creating a managed profile', t => {
  const { env } = fixture(t);
  const result = spawnSync('/bin/bash', [wrapper, 'path'], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 2);
  assert.equal(existsSync(env.CHROME_RUNTIME_DIR), false);
});

test('missing Python fails before launching the probe or allocating a profile', t => {
  const { root, env } = fixture(t);
  const emptyPath = join(root, 'empty-bin');
  mkdirSync(emptyPath);
  const result = run({ ...env, PATH: emptyPath }, 'throw new Error("must not run")');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Python 3 is required/);
  assert.equal(existsSync(env.CHROME_RUNTIME_DIR), false);
});

test('a missing process reader fails before profile allocation', t => {
  const { root, env } = fixture(t);
  const isolated = join(root, 'headless-chrome.sh');
  copyFileSync(wrapper, isolated);
  const result = run(env, 'throw new Error("must not run")', 10000, isolated);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing headless Chrome process reader/);
  assert.equal(existsSync(env.CHROME_RUNTIME_DIR), false);
});

test('a required scan failure retains recovery state and returns failure', t => {
  const { root, env } = fixture(t);
  const isolated = join(root, 'headless-chrome.sh');
  copyFileSync(wrapper, isolated);
  writeFileSync(join(root, 'headless_chrome_processes.py'), 'import sys\nif sys.argv[1:] == ["--check"]: sys.exit(0)\nprint("required scan unavailable", file=sys.stderr)\nsys.exit(1)\n');
  const result = run(env, 'console.log(JSON.stringify({profile:process.env.CHROME_PROFILE}))', 10000, isolated);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /cleanup incomplete; retained/);
  assert.ok(existsSync(JSON.parse(result.stdout).profile));
});

test('run preserves a failing probe exit status', t => {
  const { env } = fixture(t);
  assert.equal(run(env, 'process.exit(7)').status, 7);
});

test('run owns a fresh profile and preserves an inherited caller directory', t => {
  const { root, env } = fixture(t);
  const caller = join(root, 'caller-owned');
  mkdirSync(caller);
  const sentinel = join(caller, 'important-data');
  writeFileSync(sentinel, 'caller-owned fixture');
  const result = run({ ...env, CHROME_PROFILE: caller }, 'console.log(JSON.stringify({profile:process.env.CHROME_PROFILE}))');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(existsSync(sentinel), 'caller data must survive wrapper cleanup');
  const { profile } = JSON.parse(result.stdout);
  assert.notEqual(profile, caller);
  assert.ok(profile.startsWith(`${env.CHROME_RUNTIME_DIR}/run-`));
  assert.equal(existsSync(profile), false, 'owned disposable profile must be removed');
});

function sweep(env) {
  const result = spawnSync('/bin/bash', [wrapper, 'sweep'], { env, encoding: 'utf8', timeout: 15000 });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr);
  return result;
}

test('sweep preserves unmanaged directories under the runtime root', t => {
  const state = fixture(t);
  const caller = join(state.env.CHROME_RUNTIME_DIR, 'run-99999999-caller');
  mkdirSync(caller, { recursive: true });
  const sentinel = join(caller, 'important-data');
  writeFileSync(sentinel, 'unmanaged fixture');
  sweep(state.env);
  assert.ok(existsSync(sentinel), 'a run-like name is not proof of ownership');
});

test('sweep preserves a live run', async t => {
  const state = fixture(t);
  const run = await start(state, 'console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)');
  sweep(state.env);
  assert.ok(alive(run.ready.pid));
  assert.ok(existsSync(run.ready.profile));
});

test('sweep reaps an orphan while preserving another live run in the same runtime', async t => {
  const state = fixture(t);
  const code = 'console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)';
  const orphan = await start(state, code);
  const live = await start(state, code);
  orphan.child.kill('SIGKILL');
  await until(() => orphan.exit);
  sweep(state.env);
  await until(() => !alive(orphan.ready.pid));
  assert.equal(existsSync(orphan.ready.profile), false);
  assert.ok(alive(live.ready.pid));
  assert.ok(existsSync(live.ready.profile));
});

test('sweep stops the live probe after only its wrapper is SIGKILLed', async t => {
  const state = fixture(t);
  const run = await start(state, 'console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)');
  run.child.kill('SIGKILL');
  await until(() => run.exit);
  sweep(state.env);
  await until(() => !alive(run.ready.pid));
  assert.equal(existsSync(run.ready.profile), false);
});

for (const suffix of ['-other', ' other']) {
 test(`cleanup preserves a neighboring profile ending in ${JSON.stringify(suffix)}`, async t => {
  const state = fixture(t);
  const run = await start(state, 'process.on("SIGUSR1",()=>process.exit(0));console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)');
  const neighbor = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)', '--', `--user-data-dir=${run.ready.profile}${suffix}`], { detached: true, stdio: 'ignore' });
  state.cleanups.push(async () => {
    try { process.kill(-neighbor.pid, 'SIGKILL'); } catch {}
  });
  await delay(100);
  assert.ok(alive(neighbor.pid));
  process.kill(run.ready.pid, 'SIGUSR1');
  await until(() => run.exit);
  assert.ok(alive(neighbor.pid), 'the neighboring profile belongs to another process');
 });
}

test('a token-looking command argument does not grant process ownership', async t => {
  const state = fixture(t);
  const run = await start(state, 'process.on("SIGUSR1",()=>process.exit(0));console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)');
  const tag = `DECAID_CHROME_RUN_TOKEN=${run.ready.profile.split('/').at(-1)}`;
  const neighbor = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)', '--', tag], { detached: true, stdio: 'ignore' });
  state.cleanups.push(async () => { try { process.kill(-neighbor.pid, 'SIGKILL'); } catch {} });
  await delay(100);
  assert.ok(alive(neighbor.pid));
  process.kill(run.ready.pid, 'SIGUSR1');
  await until(() => run.exit);
  assert.ok(alive(neighbor.pid), 'an argv string is not an inherited environment marker');
});

test('a failed probe also stops an unflagged child that ignores TERM', async t => {
  const state = fixture(t);
  const code = 'const {spawn}=require("node:child_process");const child=spawn(process.execPath,["-e","process.on(\\\"SIGTERM\\\",()=>{});setInterval(()=>{},1000)"],{stdio:"ignore"});setTimeout(()=>{console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE,helper:child.pid}));process.exit(9)},100)';
  const result = run(state.env, code);
  const ready = JSON.parse(result.stdout.split('\n')[0]);
  state.cleanups.push(async () => { try { process.kill(ready.helper, 'SIGKILL'); } catch {} });
  assert.equal(result.status, 9, result.stderr);
  await until(() => !alive(ready.helper));
  assert.equal(existsSync(ready.profile), false);
});

test('a failed probe also stops a detached unflagged child', async t => {
  const state = fixture(t);
  const code = 'const {spawn}=require("node:child_process");const child=spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{detached:true,stdio:"ignore"});console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE,helper:child.pid}));process.exit(9)';
  const result = run(state.env, code);
  const ready = JSON.parse(result.stdout.split('\n')[0]);
  state.cleanups.push(async () => { try { process.kill(-ready.helper, 'SIGKILL'); } catch {} });
  assert.equal(result.status, 9, result.stderr);
  await until(() => !alive(ready.helper));
});

const playwrightModule = process.env.HEADLESS_CHROME_PLAYWRIGHT_MODULE;
const realChrome = process.env.CHROME_BIN;
const probe = join(dirname(wrapper), 'test-fixtures', 'headless-chrome-probe.cjs');
const realOptions = { skip: !playwrightModule || !realChrome, timeout: 45000 };

function realFixture(t, mode) {
  const state = fixture(t);
  Object.assign(state.env, { CHROME_BIN: realChrome, HEADLESS_CHROME_PLAYWRIGHT_MODULE: playwrightModule, HEADLESS_CHROME_PROBE_MODE: mode });
  return state;
}

async function noBrowserProcesses(ready) {
  await until(() => ready.pids.every(pid => !alive(pid)), 5000);
  const rows = execFileSync('ps', ['-axo', 'pid=,pgid=,stat='], { encoding: 'utf8' }).trim().split('\n');
  const survivors = rows.filter(line => {
    const [, group, state] = line.trim().split(/\s+/);
    return ready.groups.includes(Number(group)) && !state.startsWith('Z');
  });
  assert.deepEqual(survivors, [], 'no probe/browser process-group survivors');
  assert.equal(existsSync(ready.profile), false);
}

test('real Playwright supports a runtime directory containing spaces', realOptions, async t => {
  const state = realFixture(t, 'close');
  state.env.CHROME_RUNTIME_DIR = join(state.root, 'runtime with spaces');
  const result = run(state.env, `require(${JSON.stringify(probe)})`, 30000);
  assert.equal(result.status, 0, result.stderr);
  await noBrowserProcesses(JSON.parse(result.stdout.split('\n')[0]));
});

for (const [mode, status] of [['close', 0], ['fail', 7]]) {
  test(`real Playwright ${mode} exits naturally with finally cleanup`, realOptions, async t => {
    const state = realFixture(t, mode);
    const result = run(state.env, `require(${JSON.stringify(probe)})`, 30000);
    assert.equal(result.status, status, result.stderr);
    const ready = JSON.parse(result.stdout.split('\n')[0]);
    await noBrowserProcesses(ready);
  });
}

for (const [signal, status] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGKILL', null]]) {
  test(`real Playwright recovers from wrapper-only ${signal}`, realOptions, async t => {
    const state = realFixture(t, 'hold');
    const run = await start(state, `require(${JSON.stringify(probe)})`);
    run.child.kill(signal);
    await until(() => run.exit, 10000);
    if (signal === 'SIGKILL') {
      assert.equal(run.exit.signal, 'SIGKILL');
      sweep(state.env);
    } else {
      assert.deepEqual(run.exit, { code: status, signal: null });
    }
    await noBrowserProcesses(run.ready);
  });
}

for (const [signal, status] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  test(`${signal} sent only to the wrapper stops its live probe and removes the profile`, async t => {
    const state = fixture(t);
    const run = await start(state, 'console.log(JSON.stringify({pid:process.pid,profile:process.env.CHROME_PROFILE}));setInterval(()=>{},1000)');
    run.child.kill(signal);
    await delay(1500);
    assert.deepEqual(run.exit, { code: status, signal: null }, 'wrapper must handle its own signal while the probe remains alive');
    await until(() => !alive(run.ready.pid));
    assert.equal(existsSync(run.ready.profile), false);
  });
}
