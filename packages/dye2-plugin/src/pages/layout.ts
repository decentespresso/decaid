import { html } from "../utils/html";

export function sharedStyles(): string {
  return `
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #1a1a2e;
      color: #e0e0e0;
      padding: 16px;
    }
    h1 { font-size: 1.4rem; margin-bottom: 16px; color: #fff; }
    h2 { font-size: 1.1rem; margin-bottom: 12px; color: #ccc; }
    button {
      background: #16213e;
      color: #e0e0e0;
      border: 1px solid #0f3460;
      padding: 8px 16px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 0.9rem;
    }
    button:hover { background: #0f3460; }
    button.primary { background: #533483; border-color: #533483; }
    button.primary:hover { background: #6a42a0; }
    button.danger { background: #6b2737; border-color: #6b2737; }
    button.danger:hover { background: #8b3a4a; }
    input, select, textarea {
      background: #16213e;
      color: #e0e0e0;
      border: 1px solid #0f3460;
      padding: 8px;
      border-radius: 4px;
      font-size: 0.9rem;
      width: 100%;
    }
    input:focus, select:focus, textarea:focus {
      outline: none;
      border-color: #533483;
    }
    .card {
      background: #16213e;
      border: 1px solid #0f3460;
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 12px;
    }
    .flex { display: flex; gap: 8px; align-items: center; }
    .flex-between { display: flex; justify-content: space-between; align-items: center; }
    .grid { display: grid; gap: 12px; }
    .grid-2 { grid-template-columns: 1fr 1fr; }
    .mt-8 { margin-top: 8px; }
    .mt-16 { margin-top: 16px; }
    .mb-8 { margin-bottom: 8px; }
    .text-muted { color: #888; }
    .text-small { font-size: 0.8rem; }
    .hidden { display: none; }
    .icon-btn {
      background: none;
      border: none;
      color: #888;
      padding: 4px 8px;
      font-size: 1.1rem;
      line-height: 1;
      cursor: pointer;
      border-radius: 4px;
    }
    .icon-btn:hover { background: #0f3460; color: #e0e0e0; }
    .tag {
      display: inline-block;
      background: #0f3460;
      padding: 2px 8px;
      border-radius: 12px;
      font-size: 0.75rem;
      margin-right: 4px;
    }
  `;
}

export function pageShell(title: string, content: string, scripts: string[] = []): string {
  return html`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>DYE2 - ${title}</title>
  <style>${sharedStyles()}</style>
</head>
<body>
  ${content}
  ${scripts.map((s) => `<script>${s}</script>`).join("\n")}
</body>
</html>`;
}
