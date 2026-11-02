import fs from "node:fs";
import { build } from "esbuild";

const shared = { bundle: true, format: "iife", target: "es2022", platform: "neutral", mainFields: ["module", "main"], minify: true, legalComments: "inline" };

await build({ ...shared, entryPoints: ["src/extension/index.ts"], inject: ["src/extension/encoding.ts"], globalName: "__swiptRuntime", outfile: "../runtime.js" });
await build({ ...shared, entryPoints: ["src/extension/rewrite.ts"], globalName: "__swiptRewrite", outfile: "../rewrite.js" });

const read = name => fs.readFileSync(new URL(`../../../api/${name}.d.ts`, import.meta.url), "utf8");
const globalModules = ["index", "file-system", "swiplet"];
const namespaces = ["accessibility", "input", "device", "screen", "image"];

const imports = text => {
  const aliases = [];
  const body = text.replace(/^import type \{([^}]+)\} from "\.\/([a-z-]+)";\n/gm, (_, names, module) => {
    if (!globalModules.includes(module)) {
      for (const name of names.split(",").map(name => name.trim()).filter(Boolean)) {
        aliases.push(`type ${name} = ${module}.${name};`);
      }
    }
    return "";
  }).replace(/^import type .*\n/gm, "");
  return { aliases, body: body.replace(/^\n+/, "") };
};

const replOnly = text => {
  const packaging = text.indexOf("export type ActionCaller");
  return packaging < 0 ? text : text.slice(0, packaging);
};
const ambient = text => text.replace(/^declare global \{\n([\s\S]*?)^\}\n/gm, (_, body) => body.replace(/^  (?=\S)/gm, "declare "));
const globals = globalModules.map(name => ambient(replOnly(imports(read(name)).body).replace(/^export declare const assets: .*\n/m, "").replace(/^export (declare )?/gm, (_, declared) => declared ? "declare " : "")).trimEnd());
const namespaced = namespaces.map(name => {
  const { aliases, body } = imports(read(name));
  const members = [...aliases, body.replace(/^export declare /gm, "export ")].join("\n").trimEnd();
  return `declare namespace ${name} {\n${members.replace(/^(?=.)/gm, "  ")}\n}`;
});
const repl = read("repl");
const extras = repl.slice(repl.indexOf("declare global {") + "declare global {".length, repl.lastIndexOf("\n}\n\nexport"))
  .split("\n")
  .filter(line => line.trim() !== "" && !namespaces.some(name => line.startsWith(`  const ${name}:`)))
  .map(line => line.replace(/^  /, "declare ").replace(/import\("@swipt\/api\/swiplet"\)\./g, "").replace(/import\("@swipt\/api\/image"\)\./g, "image."));
fs.writeFileSync(new URL("../declarations/api.d.ts", import.meta.url), `${[...globals, ...namespaced, extras.join("\n")].join("\n\n").trimEnd()}\n`);
