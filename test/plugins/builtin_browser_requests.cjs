const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

const cliOptions = parseArgs(process.argv.slice(2));
const cliMode = require.main === module && Boolean(cliOptions.origin);
const registerTest = cliMode ? () => {} : test;

const pluginSourcePath = 'assets/plugins/settings.reaplugin/plugin.js';
const docsViewerPath = 'assets/api/index.html';
const openApiPath = 'assets/api/rest_v1.yml';
const asyncApiPath = 'assets/api/websocket_v1.yml';

function inlineScripts(html) {
  const scripts = [];
  const pattern = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = pattern.exec(html)) !== null) scripts.push(match[1]);
  return scripts;
}

function pluginPageSource() {
  const source = fs.readFileSync(pluginSourcePath, 'utf8');
  const scripts = inlineScripts(source);
  assert.ok(
    scripts.length > 0,
    'the bundled settings page must embed its browser script inline',
  );
  return `<html><body>${scripts
    .map((script) => `<script>${script}</script>`)
    .join('')}</body></html>`;
}

function elementStub() {
  const classes = new Set();
  return {
    id: '',
    textContent: '',
    value: '',
    checked: false,
    className: '',
    innerHTML: '',
    style: {},
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
    },
    setAttribute() {},
    remove() {},
    appendChild() {},
    addEventListener() {},
  };
}

function browserContext(origin, requests, elements) {
  const page = new URL(origin);
  const toasts = [];
  const timers = [];

  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, Object.assign(elementStub(), { id }));
    }
    return elements.get(id);
  };

  const fetchStub = async (input, init = {}) => {
    const url =
      typeof input === 'string'
        ? input
        : input && typeof input.href === 'string'
          ? input.href
          : String(input);
    requests.push({
      url,
      absoluteUrl: new URL(url, origin).href,
      method: String(init.method || 'GET').toUpperCase(),
      headers: init.headers || {},
      body: init.body === undefined ? null : init.body,
      credentials: init.credentials === undefined ? 'same-origin' : init.credentials,
      mode: init.mode === undefined ? 'cors' : init.mode,
    });
    return {
      ok: true,
      status: 200,
      headers: { get: () => null },
      json: async () => ({ message: 'recorded', results: [] }),
      text: async () => '{"message":"recorded","results":[]}',
    };
  };

  const context = vm.createContext({
    URL,
    console,
    fetch: fetchStub,
    window: {
      location: {
        protocol: page.protocol,
        host: page.host,
        hostname: page.hostname,
        origin,
        href: `${origin}/`,
      },
    },
    location: {
      reload: () => timers.push({ reloads: true }),
      href: `${origin}/`,
    },
    document: {
      body: {
        appendChild: (node) =>
          toasts.push({
            message: node.textContent,
            isError: node.className === 'error-toast',
          }),
      },
      createElement: elementStub,
      getElementById: element,
      querySelector: () => null,
      addEventListener: () => {},
    },
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms });
      return 0;
    },
    clearTimeout: () => {},
    setInterval: () => 0,
    clearInterval: () => {},
    confirm: () => false,
    alert: () => {},
    localStorage: { getItem: () => null, setItem: () => {} },
    navigator: { clipboard: { writeText: async () => {} } },
  });

  return { context, toasts, timers };
}

async function collectPageRequests(html, { origin }) {
  const requests = [];
  const elements = new Map();
  const { context, toasts, timers } = browserContext(origin, requests, elements);
  const scripts = inlineScripts(html);
  assert.ok(scripts.length > 0, 'the delivered page must embed inline script');

  for (const script of scripts) {
    vm.runInContext(script, context, { filename: 'settings-page-inline.js' });
  }

  const captured = [];
  const mark = () => {
    const start = requests.length;
    return () => requests.slice(start);
  };

  let marker = mark();
  await context.checkSkinUpdates();
  captured.push({ action: 'checkSkinUpdates', requests: marker() });

  marker = mark();
  await context.updateReaSetting('automaticUpdateCheck', false);
  captured.push({
    action: "updateReaSetting('automaticUpdateCheck', false)",
    requests: marker(),
  });

  return {
    pageOrigin: origin,
    actions: captured,
    requests,
    toasts,
    timerCount: timers.length,
  };
}

function serversBlock(yamlText) {
  const entries = [];
  for (const line of yamlText.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;
    entries.push({ indent: line.length - line.trimStart().length, text: trimmed });
  }
  const start = entries.findIndex(
    (entry) => entry.indent === 0 && /^servers:\s*$/.test(entry.text),
  );
  if (start < 0) return {};
  const childIndent = nextIndent(entries, start + 1, 0);
  if (childIndent === null) return { servers: null };
  const [servers] = parseNode(entries, start + 1, childIndent);
  return { servers };
}

function nextIndent(entries, from, indent) {
  for (let index = from; index < entries.length; index += 1) {
    if (entries[index].indent > indent) return entries[index].indent;
  }
  return null;
}

function parseNode(entries, index, indent) {
  const isSequence =
    entries[index].text === '-' || entries[index].text.startsWith('- ');
  return isSequence
    ? parseSequence(entries, index, indent)
    : parseMapping(entries, index, indent);
}

function parseSequence(entries, index, indent) {
  const items = [];
  while (index < entries.length) {
    const entry = entries[index];
    if (entry.indent !== indent) break;
    if (!(entry.text === '-' || entry.text.startsWith('- '))) break;
    const rest = entry.text.replace(/^-\s?/, '');
    if (rest === '') {
      const childIndent = nextIndent(entries, index + 1, indent);
      if (childIndent === null) break;
      const [child, next] = parseNode(entries, index + 1, childIndent);
      items.push(child);
      index = next;
    } else if (/^[^:]+:(\s|$)/.test(rest)) {
      const itemIndent = indent + 2;
      const itemEntries = [{ indent: itemIndent, text: rest }];
      let next = index + 1;
      while (next < entries.length && entries[next].indent >= itemIndent) {
        itemEntries.push(entries[next]);
        next += 1;
      }
      const [item] = parseNode(itemEntries, 0, itemIndent);
      items.push(item);
      index = next;
    } else {
      items.push(scalar(rest));
      index += 1;
    }
  }
  return [items, index];
}

function parseMapping(entries, index, indent) {
  const map = {};
  while (index < entries.length) {
    const entry = entries[index];
    if (entry.indent !== indent) break;
    const match = /^([^:#]+):(?:[ \t]+(.*))?$/.exec(entry.text);
    if (!match) break;
    const key = match[1].trim();
    const valueText = (match[2] || '').trim();
    index += 1;
    if (valueText === '' || /^[>|][+-]?$/.test(valueText)) {
      const childIndent = nextIndent(entries, index, indent);
      if (/^[>|][+-]?$/.test(valueText)) {
        while (index < entries.length && entries[index].indent > indent) {
          index += 1;
        }
        map[key] = '';
        continue;
      }
      if (childIndent === null) {
        map[key] = null;
        continue;
      }
      const [child, next] = parseNode(entries, index, childIndent);
      map[key] = child;
      index = next;
    } else {
      map[key] = scalar(valueText);
    }
  }
  return [map, index];
}

function scalar(text) {
  const quoted = /^(['"])(.*)\1$/.exec(text);
  return quoted ? quoted[2] : text;
}

function serverTargets(servers) {
  if (!servers) return [];
  const entries = Array.isArray(servers) ? servers : Object.values(servers);
  return entries.map((server) => {
    const variables = {};
    for (const [name, variable] of Object.entries((server && server.variables) || {})) {
      if (variable && typeof variable === 'object' && typeof variable.default === 'string') {
        variables[name] = variable.default;
      }
    }
    const template = String((server && (server.url || server.host)) || '');
    return { template, variables, resolved: resolveTemplate(template, variables) };
  });
}

function resolveTemplate(template, variables) {
  return template.replace(
    /\{([^}]+)\}/g,
    (match, name) => (name in variables ? variables[name] : match),
  );
}

async function collectViewerConfiguration(html, { origin, restText, wsText }) {
  const page = new URL(origin);
  const texts = { 'rest_v1.yml': restText, 'websocket_v1.yml': wsText };
  const requests = [];
  const swaggerConfigs = [];
  const renderedSchemas = [];
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, Object.assign(elementStub(), { id }));
    }
    return elements.get(id);
  };

  const fetchStub = async (input) => {
    const url =
      typeof input === 'string'
        ? input
        : input && typeof input.href === 'string'
          ? input.href
          : String(input);
    requests.push(url);
    const text = texts[url];
    if (text === undefined) throw new Error(`unexpected docs fetch: ${url}`);
    return {
      ok: true,
      status: 200,
      text: async () => text,
      json: async () => JSON.parse(text),
    };
  };

  const swagger = (config) => {
    swaggerConfigs.push(config);
    return {};
  };
  swagger.presets = { apis: {} };

  const context = vm.createContext({
    URL,
    console,
    fetch: fetchStub,
    jsyaml: { load: serversBlock },
    SwaggerUIBundle: swagger,
    SwaggerUIStandalonePreset: {},
    window: {
      location: {
        protocol: page.protocol,
        host: page.host,
        hostname: page.hostname,
        origin,
        href: `${origin}/`,
      },
      onload: null,
      AsyncApiStandalone: {
        render: (config) => {
          renderedSchemas.push(config.schema);
        },
      },
    },
    document: {
      getElementById: element,
      addEventListener: () => {},
    },
  });

  const scripts = inlineScripts(html);
  assert.ok(scripts.length > 0, 'the delivered docs viewer must embed inline script');
  for (const script of scripts) {
    vm.runInContext(script, context, { filename: 'docs-viewer-inline.js' });
  }
  assert.equal(
    typeof context.window.onload,
    'function',
    'the delivered docs viewer must install an onload handler',
  );
  await context.window.onload();

  assert.equal(swaggerConfigs.length, 1, 'the viewer must configure Swagger UI once');
  const restConfig = swaggerConfigs[0];
  return {
    pageOrigin: origin,
    requestedSpecs: requests,
    rest: {
      specProvided: Boolean(restConfig.spec),
      fetchedUrl: typeof restConfig.url === 'string' ? restConfig.url : null,
      servers: serverTargets(restConfig.spec && restConfig.spec.servers),
      shippedServers: serverTargets(serversBlock(restText).servers),
    },
    asyncApi: {
      rendered: renderedSchemas.length === 1,
      servers: serverTargets(renderedSchemas[0] && renderedSchemas[0].servers),
    },
  };
}

function parseArgs(argv) {
  const options = { origin: null, html: null, docs: false, rest: null, ws: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--origin') options.origin = argv[++index];
    else if (arg === '--html') options.html = argv[++index];
    else if (arg === '--docs') options.docs = true;
    else if (arg === '--rest') options.rest = argv[++index];
    else if (arg === '--ws') options.ws = argv[++index];
    else if (!options.html) options.html = arg;
  }
  return options;
}

const realPage = () => pluginPageSource();

registerTest('the real settings page posts the skin update check to its own origin', async () => {
  const html = realPage();
  const origin = 'http://de1tablet.home:8080';
  const recorded = await collectPageRequests(html, { origin });
  const action = recorded.actions.find((entry) => entry.action === 'checkSkinUpdates');
  assert.equal(action.requests.length, 1);
  const [request] = action.requests;
  assert.equal(request.absoluteUrl, `${origin}/api/v1/webui/skins/update`);
  assert.equal(request.method, 'POST');
});

registerTest('the real settings page posts automaticUpdateCheck to its own origin', async () => {
  const html = realPage();
  const origin = 'http://127.0.0.1:8080';
  const recorded = await collectPageRequests(html, { origin });
  const action = recorded.actions.find((entry) =>
    entry.action.startsWith('updateReaSetting'),
  );
  assert.equal(action.requests.length, 1);
  const [request] = action.requests;
  assert.equal(request.absoluteUrl, `${origin}/api/v1/settings`);
  assert.equal(request.method, 'POST');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(request.body), { automaticUpdateCheck: false });
});

registerTest('the page origin, not the API listener, decides the request URLs', async () => {
  const html = realPage();
  const aliased = await collectPageRequests(html, {
    origin: 'http://de1tablet.home:4001',
  });
  assert.equal(
    aliased.requests[0].absoluteUrl,
    'http://de1tablet.home:4001/api/v1/webui/skins/update',
  );
  assert.equal(
    aliased.requests[1].absoluteUrl,
    'http://de1tablet.home:4001/api/v1/settings',
  );
});

registerTest('the page script recorded by this harness is the bundled inline script', () => {
  const scripts = inlineScripts(fs.readFileSync(pluginSourcePath, 'utf8'));
  assert.ok(scripts.length > 0);
  assert.ok(scripts.some((script) => script.includes('async function checkSkinUpdates')));
  assert.ok(
    scripts.some((script) => script.includes('async function updateReaSetting')),
  );
});

registerTest('the shipped OpenAPI servers block reads as the viewer expects', () => {
  const parsed = serversBlock(fs.readFileSync(openApiPath, 'utf8'));
  assert.deepEqual(parsed, {
    servers: [
      {
        url: 'http://{tablet-ip}:8080',
        variables: { 'tablet-ip': { default: 'localhost' } },
      },
    ],
  });
  assert.deepEqual(serverTargets(parsed.servers), [
    {
      template: 'http://{tablet-ip}:8080',
      variables: { 'tablet-ip': 'localhost' },
      resolved: 'http://localhost:8080',
    },
  ]);
});

registerTest('the shipped AsyncAPI servers block reads as the viewer expects', () => {
  const parsed = serversBlock(fs.readFileSync(asyncApiPath, 'utf8'));
  const production = parsed.servers.production;
  assert.equal(production.host, '{tablet-ip}:8080');
  assert.equal(production.protocol, 'ws');
  assert.deepEqual(production.variables, { 'tablet-ip': { default: 'localhost' } });
});

registerTest('the docs viewer targets the numeric page host, not the shipped localhost default', async () => {
  const html = fs.readFileSync(docsViewerPath, 'utf8');
  const recorded = await collectViewerConfiguration(html, {
    origin: 'http://203.0.113.9:4001',
    restText: fs.readFileSync(openApiPath, 'utf8'),
    wsText: fs.readFileSync(asyncApiPath, 'utf8'),
  });
  assert.deepEqual(recorded.requestedSpecs, ['rest_v1.yml', 'websocket_v1.yml']);
  assert.equal(recorded.rest.specProvided, true);
  assert.deepEqual(recorded.rest.shippedServers.map((server) => server.resolved), [
    'http://localhost:8080',
  ]);
  assert.deepEqual(recorded.rest.servers.map((server) => server.resolved), [
    'http://203.0.113.9:8080',
  ]);
  assert.deepEqual(recorded.asyncApi.servers.map((server) => server.resolved), [
    '203.0.113.9:8080',
  ]);
});

registerTest('the docs viewer rewrites only the tablet-ip variable', async () => {
  const html = fs.readFileSync(docsViewerPath, 'utf8');
  const restText = [
    'servers:',
    '  - url: http://{tablet-ip}:8080/{version}',
    '    variables:',
    '      tablet-ip:',
    '        default: localhost',
    '      version:',
    '        default: v1',
    '',
  ].join('\n');
  const wsText = [
    'servers:',
    '  production:',
    "    host: '{tablet-ip}:8080/{version}'",
    '    protocol: ws',
    '    variables:',
    '      tablet-ip:',
    '        default: localhost',
    '      version:',
    '        default: v1',
    '',
  ].join('\n');
  const recorded = await collectViewerConfiguration(html, {
    origin: 'http://203.0.113.9:4001',
    restText,
    wsText,
  });
  assert.deepEqual(recorded.rest.shippedServers[0].variables, {
    'tablet-ip': 'localhost',
    version: 'v1',
  });
  assert.deepEqual(recorded.rest.servers[0].variables, {
    'tablet-ip': '203.0.113.9',
    version: 'v1',
  });
  assert.deepEqual(recorded.rest.servers.map((server) => server.resolved), [
    'http://203.0.113.9:8080/v1',
  ]);
  assert.deepEqual(recorded.asyncApi.servers.map((server) => server.resolved), [
    '203.0.113.9:8080/v1',
  ]);
});

module.exports = {
  collectPageRequests,
  collectViewerConfiguration,
  inlineScripts,
  serversBlock,
};

if (cliMode) {
  const html = cliOptions.html
    ? fs.readFileSync(cliOptions.html, 'utf8')
    : realPage();
  const recorded = cliOptions.docs
    ? collectViewerConfiguration(html, {
        origin: cliOptions.origin,
        restText: fs.readFileSync(cliOptions.rest, 'utf8'),
        wsText: fs.readFileSync(cliOptions.ws, 'utf8'),
      })
    : collectPageRequests(html, { origin: cliOptions.origin });
  recorded.then(
    (result) => {
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    },
    (error) => {
      console.error(error && error.stack ? error.stack : String(error));
      process.exit(1);
    },
  );
}
