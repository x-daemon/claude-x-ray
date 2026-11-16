// Bundles the main process, the preload bridge and the renderer with esbuild.
import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";

const watch = process.argv.includes("--watch");
rmSync("dist", { recursive: true, force: true });
mkdirSync("dist/renderer", { recursive: true });

const common = { bundle: true, sourcemap: false, logLevel: "info", target: "es2022", legalComments: "none" };
await Promise.all([
  build({ ...common, entryPoints: ["src/main/main.ts"], outfile: "dist/main.js", platform: "node", format: "cjs", external: ["electron"] }),
  build({ ...common, entryPoints: ["src/preload/preload.ts"], outfile: "dist/preload.js", platform: "node", format: "cjs", external: ["electron"] }),
  build({ ...common, entryPoints: ["src/renderer/app.tsx"], outfile: "dist/renderer/app.js", platform: "browser", format: "iife", minify: true, jsx: "automatic", jsxImportSource: "preact" }),
]);
cpSync("src/renderer/index.html", "dist/renderer/index.html");
cpSync("src/renderer/styles.css", "dist/renderer/styles.css");
if (watch) console.log("built");
