const path = require("node:path");
const { getDefaultConfig } = require("expo/metro-config");

const config = getDefaultConfig(__dirname);
const ponyfill = require.resolve("web-streams-polyfill/dist/ponyfill.mjs");
const sources = path.join(__dirname, "src");
const resolveRequest = config.resolver.resolveRequest;

config.transformer.babelTransformerPath = require.resolve("./metro.transformer.js");
config.resolver.resolveRequest = (context, moduleName, platform) => {
  switch (context.originModulePath.startsWith(sources) ? moduleName : undefined) {
    case "swipt:modules":
      return { type: "sourceFile", filePath: path.join(__dirname, "src/app/modules.ts") };
    case "web-streams-polyfill":
      return { type: "sourceFile", filePath: ponyfill };
  }
  return (resolveRequest ?? context.resolveRequest)(context, moduleName, platform);
};

module.exports = config;
