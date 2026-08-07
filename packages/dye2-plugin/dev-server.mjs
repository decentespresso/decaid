#!/usr/bin/env node

/**
 * DYE2 Plugin Dev Server
 *
 * Loads the built plugin.js in a Node.js VM, serves its pages via HTTP,
 * and proxies /api/v1/* requests to a running Decent instance.
 *
 * Usage:
 *   npm run serve                          # defaults: port 3000, bridge at localhost:8080
 *   PORT=4000 BRIDGE_URL=http://192.168.1.5:8080 npm run serve
 *
 * Pair with `npm run dev` in another terminal for watch builds — the server
 * auto-reloads plugin.js when it changes on disk.
 */

import { createServer, request as httpRequest } from "node:http";
import { readFileSync, watch } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import vm from "node:vm";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_PATH = resolve(
  __dirname,
  "../../assets/plugins/dye2.reaplugin/plugin.js"
);

const PORT = parseInt(process.env.PORT || "4444", 10);
const BRIDGE_URL = process.env.BRIDGE_URL || "http://localhost:8080";
const bridgeUrl = new URL(BRIDGE_URL);

// ── Plugin loading ──────────────────────────────────────────────────

let plugin = null;

function loadPlugin() {
  const src = readFileSync(PLUGIN_PATH, "utf-8");
  const context = vm.createContext({ console, setTimeout, clearTimeout });
  const script = new vm.Script(src, { filename: "plugin.js" });
  script.runInContext(context);

  const mockHost = {
    log: (...args) => console.log("[plugin]", ...args),
    emit: (name, payload) =>
      console.log("[plugin:emit]", name, JSON.stringify(payload)),
    storage: (cmd) =>
      console.log("[plugin:storage]", JSON.stringify(cmd)),
  };

  plugin = context.createPlugin(mockHost);
  plugin.onLoad({});
  console.log(`Loaded plugin ${plugin.id} v${plugin.version}`);
}

// ── File watching ───────────────────────────────────────────────────

let reloadTimer = null;

function watchPlugin() {
  try {
    watch(PLUGIN_PATH, () => {
      clearTimeout(reloadTimer);
      reloadTimer = setTimeout(() => {
        console.log("\nPlugin file changed — reloading...");
        try {
          loadPlugin();
        } catch (err) {
          console.error("Reload failed:", err.message);
        }
      }, 200);
    });
  } catch {
    console.warn(
      "Could not watch plugin.js — auto-reload disabled. Build the plugin first."
    );
  }
}

// ── API proxy ───────────────────────────────────────────────────────

function proxyRequest(req, res) {
  const options = {
    hostname: bridgeUrl.hostname,
    port: bridgeUrl.port || 80,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: bridgeUrl.host },
  };

  const proxyReq = httpRequest(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on("error", (err) => {
    console.error(`Proxy error: ${err.message}`);
    res.writeHead(502, { "Content-Type": "text/plain" });
    res.end(`Proxy error: ${err.message}\nIs Decent running at ${BRIDGE_URL}?`);
  });

  req.pipe(proxyReq, { end: true });
}

// ── Plugin page handler ─────────────────────────────────────────────

function handlePluginPage(endpoint, req, res) {
  if (!plugin) {
    res.writeHead(503, { "Content-Type": "text/plain" });
    res.end("Plugin not loaded. Build it first: npm run build");
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const query = Object.fromEntries(url.searchParams.entries());

  const request = {
    requestId: `dev-${Date.now()}`,
    endpoint,
    method: req.method,
    headers: req.headers,
    body: null,
    query,
  };

  try {
    const response = plugin.__httpRequestHandler(request);
    Promise.resolve(response).then((resp) => {
      res.writeHead(resp.status, resp.headers);
      res.end(resp.body);
    });
  } catch (err) {
    console.error(`Handler error for /${endpoint}:`, err.message);
    res.writeHead(500, { "Content-Type": "text/plain" });
    res.end(`Plugin error: ${err.message}`);
  }
}

// ── HTTP server ─────────────────────────────────────────────────────

const PLUGIN_ROUTES = ["beans", "grinders", "bean-picker", "grinder-picker"];

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname.replace(/\/+$/, "") || "/";

  for (const route of PLUGIN_ROUTES) {
    if (pathname === `/${route}`) {
      handlePluginPage(route, req, res);
      return;
    }
  }

  if (pathname.startsWith("/api/")) {
    proxyRequest(req, res);
    return;
  }

  if (pathname === "/") {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(`<!DOCTYPE html>
<html><head><title>DYE2 Dev Server</title>
<style>body{font-family:system-ui;max-width:600px;margin:2em auto;background:#1a1a1a;color:#e0e0e0}
a{color:#6cf;display:block;padding:.5em 0;font-size:1.2em}h1{border-bottom:1px solid #333;padding-bottom:.5em}
code{background:#333;padding:.2em .4em;border-radius:3px;font-size:.9em}</style></head>
<body><h1>DYE2 Dev Server</h1>
<p>Plugin: <code>${plugin ? `${plugin.id} v${plugin.version}` : "not loaded"}</code></p>
<p>Bridge: <code>${BRIDGE_URL}</code></p>
<h2>Pages</h2>
${PLUGIN_ROUTES.map((r) => `<a href="/${r}">/${r}</a>`).join("\n")}
<h2>API Proxy</h2>
<p>All <code>/api/v1/*</code> requests are proxied to the bridge.</p>
</body></html>`);
    return;
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not found");
});

// ── Start ───────────────────────────────────────────────────────────

try {
  loadPlugin();
} catch (err) {
  console.error(`Failed to load plugin: ${err.message}`);
  console.error("Build it first: cd packages/dye2-plugin && npm run build");
  process.exit(1);
}

watchPlugin();

server.listen(PORT, () => {
  console.log(`\nDYE2 Dev Server running at http://localhost:${PORT}`);
  console.log(`Proxying /api/v1/* → ${BRIDGE_URL}`);
  console.log(`Watching ${PLUGIN_PATH} for changes\n`);
  console.log("Routes:");
  for (const route of PLUGIN_ROUTES) {
    console.log(`  http://localhost:${PORT}/${route}`);
  }
  console.log();
});
