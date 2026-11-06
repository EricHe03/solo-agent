const fs = require("node:fs");

const source = fs.readFileSync("Swipt/Agent/AgentTools.swift", "utf8");
const match = source.match(/#"""([\s\S]*?)"""#/);
if (!match) throw new Error("Agent tool catalog not found");
const tools = JSON.parse(match[1]);
const expected = [
  "get_device_info",
  "get_foreground_app",
  "get_accessibility_tree",
  "take_screenshot",
  "launch_app",
  "tap_element",
  "tap_coordinates",
  "swipe",
  "type_text",
  "press_home",
  "press_back",
  "wait_for_screen",
  "finish_task",
];
const actual = tools.map((tool) => tool.function.name);
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(`Unexpected tool catalog: ${actual.join(", ")}`);
}
for (const tool of tools) {
  if (tool.type !== "function" || tool.function.parameters.type !== "object") {
    throw new Error(`Invalid schema for ${tool.function.name}`);
  }
}
console.log(`Validated ${tools.length} agent tool definitions.`);
