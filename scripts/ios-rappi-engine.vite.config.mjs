import { defineConfig } from "vite";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export default defineConfig({
  root: repositoryRoot,
  build: {
    // JavaScriptCore on the supported iOS floor is close to Safari 17. Keep
    // the generated contract inside that syntax/runtime envelope; PDFKit and
    // Vision remain outside this bundle.
    target: "safari17",
    lib: {
      entry: path.join(repositoryRoot, "src/rappiEngineBridge.ts"),
      name: "MarcelitoRappiEngine",
      formats: ["iife"],
      fileName: () => "rappi-engine.js",
    },
    outDir: path.join(repositoryRoot, "apps/ios/Cauce/Resources"),
    emptyOutDir: false,
    copyPublicDir: false,
    minify: false,
    sourcemap: false,
  },
});
