/* replay-simulator.reaplugin
 *
 * Toggles historical-shot replay in the simulated espresso machine.
 *
 * The simulator's telemetry is produced in the device layer (MockDe1), below
 * the plugin sandbox, so this plugin cannot generate the replay itself. Instead
 * it signals its enabled state to the app: on load it emits setEnabled{true},
 * on unload setEnabled{false}. main.dart listens and flips the simulated-device
 * service, which the simulated machine reads at the start of each shot.
 *
 * Contract: define createPlugin(host); return { onLoad, onUnload, onEvent }.
 */

function createPlugin(host) {
  "use strict";

  function setEnabled(enabled) {
    host.log(
      `[replay-simulator] historical-shot replay ${
        enabled ? "enabled" : "disabled"
      }`
    );
    host.emit("setEnabled", { enabled: enabled });
  }

  return {
    id: "replay-simulator.reaplugin",
    version: "1.0.0",

    onLoad() {
      setEnabled(true);
    },

    onUnload() {
      setEnabled(false);
    },

    onEvent() {
      // No telemetry needed; the app owns the replay behavior.
    },
  };
}
