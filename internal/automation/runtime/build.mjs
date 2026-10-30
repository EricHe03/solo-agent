import fs from "node:fs";
import { build } from "esbuild";

const shared = { bundle: true, format: "iife", target: "es2022", platform: "neutral", mainFields: ["module", "main"], minify: true, legalComments: "inline" };

await build({ ...shared, entryPoints: ["src/extension/index.ts"], inject: ["src/extension/encoding.ts"], globalName: "__swiptRuntime", outfile: "../runtime.js" });
await build({ ...shared, entryPoints: ["src/extension/rewrite.ts"], globalName: "__swiptRewrite", outfile: "../rewrite.js" });

const read = name => fs.readFileSync(new URL(`../../../sdk/${name}`, import.meta.url), "utf8");
const extension = read("extension.d.ts");
const surface = extension.slice(extension.indexOf("export interface Options {")).replace(/^export (declare )?/gm, (_, declared) => declared ? "declare " : "");
const repl = read("repl.d.ts");
const globals = repl.slice(repl.indexOf("declare global {") + "declare global {".length, repl.lastIndexOf("\n}\n\nexport"))
  .split("\n")
  .filter(line => !/^\s*const (device|ui|graphics|sleep):/.test(line))
  .map(line => line.replace(/^  /, "").replace(/sdk\./g, "").replace(/^(const|function) /, "declare $1 "))
  .join("\n");
fs.writeFileSync(new URL("../declarations/api.d.ts", import.meta.url), `type File = import("expo-file-system").File;\n\n${surface.trimEnd()}\n${globals.trimEnd()}\n`);
