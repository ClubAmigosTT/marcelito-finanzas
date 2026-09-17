import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const vite = path.join(repositoryRoot, "node_modules", "vite", "bin", "vite.js");
const config = path.join(repositoryRoot, "scripts", "ios-rappi-engine.vite.config.mjs");

const result = spawnSync(process.execPath, [vite, "build", "--config", config], {
  cwd: repositoryRoot,
  stdio: "inherit",
});

if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);

// Vite's IIFE library wrapper places its export object on the same global
// name as the engine. Restore the deliberately smaller API after the wrapper
// finishes so JavaScriptCore receives `{ version, parse }`, not the module
// namespace used by the web bundler.
appendFileSync(
  path.join(repositoryRoot, "apps", "ios", "Cauce", "Resources", "rappi-engine.js"),
  "\n;globalThis.MarcelitoRappiEngine = globalThis.MarcelitoRappiEngine.rappiSharedEngine;\n",
  "utf8",
);
