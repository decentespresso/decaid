import { defineConfig } from "vite";
import { resolve } from "path";
import { mkdirSync, copyFileSync } from "fs";

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, "src/plugin.ts"),
      name: "createPlugin",
      formats: ["iife"],
      fileName: () => "plugin.js",
    },
    outDir: resolve(__dirname, "../../assets/plugins/dye2.reaplugin"),
    emptyOutDir: false,
    minify: false,
    rollupOptions: {
      output: {
        footer: "",
      },
    },
  },
  plugins: [
    {
      name: "copy-manifest",
      closeBundle() {
        const outDir = resolve(
          __dirname,
          "../../assets/plugins/dye2.reaplugin"
        );
        mkdirSync(outDir, { recursive: true });
        copyFileSync(
          resolve(__dirname, "manifest.json"),
          resolve(outDir, "manifest.json")
        );
      },
    },
  ],
});
