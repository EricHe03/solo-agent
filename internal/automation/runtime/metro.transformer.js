const crypto = require("node:crypto");
const fs = require("node:fs");
const upstream = require("@expo/metro-config/build/babel-transformer");
const { hiddenSlots } = require("./slots.mjs");

const slots = crypto.createHash("sha256").update(fs.readFileSync(require.resolve("./slots.mjs"))).digest("hex");

module.exports = {
  ...upstream,
  transform(args) {
    return upstream.transform(/[\\/]web-streams-polyfill[\\/]dist[\\/]ponyfill\.mjs$/.test(args.filename) ? { ...args, src: hiddenSlots(args.src) } : args);
  },
  getCacheKey: (...args) => `${upstream.getCacheKey(...args)}:${slots}`,
};
