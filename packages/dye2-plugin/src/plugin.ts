/// <reference path="./host.d.ts" />

import { renderBeansPage } from "./pages/beans";
import { renderGrindersPage } from "./pages/grinders";
import { renderBeanPickerPage } from "./pages/bean-picker";
import { renderGrinderPickerPage } from "./pages/grinder-picker";

export default function createPlugin(host: PluginHost): PluginInstance {
  function log(msg: string) {
    host.log(`[dye2] ${msg}`);
  }

  return {
    id: "dye2.reaplugin",
    version: "0.1.0",

    onLoad(_settings: Record<string, unknown>) {
      log("DYE2 plugin loaded");
    },

    onUnload() {
      log("DYE2 plugin unloaded");
    },

    onEvent(_event: PluginEvent) {
    },

    __httpRequestHandler(request: HttpRequest): HttpResponse {
      log(`HTTP ${request.method} ${request.endpoint}`);

      switch (request.endpoint) {
        case "beans":
          return renderBeansPage(request);

        case "grinders":
          return renderGrindersPage(request);

        case "bean-picker":
          return renderBeanPickerPage(request);

        case "grinder-picker":
          return renderGrinderPickerPage(request);

        default:
          return {
            requestId: request.requestId,
            status: 404,
            headers: { "Content-Type": "text/plain" },
            body: "Not found",
          };
      }
    },
  };
}
