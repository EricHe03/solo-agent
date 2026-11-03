import { parse } from "meriyah";

export const hiddenSlots = (code) => {
  const program = parse(code, { module: true, next: true, ranges: true });
  const visit = (node, enter) => {
    if (node === null || typeof node !== "object") {
      return;
    }
    if (Array.isArray(node)) {
      node.forEach((child) => visit(child, enter));
      return;
    }
    if (typeof node.type !== "string") {
      return;
    }
    enter(node);
    for (const [key, child] of Object.entries(node)) {
      if (key !== "start" && key !== "end" && key !== "range") {
        visit(child, enter);
      }
    }
  };
  const slot = (name) => typeof name === "string" && name.startsWith("_");
  const plain = new Set();
  visit(program, (node) => {
    if (
      (node.type === "Property" ||
        node.type === "PropertyDefinition" ||
        node.type === "MethodDefinition") &&
      !node.computed &&
      slot(node.key.name ?? node.key.value)
    ) {
      if (node.type === "PropertyDefinition") {
        throw new Error(
          `web-streams-polyfill declares the class field ${node.key.name}, which internal slots can't hide`,
        );
      }
      plain.add(node.key.name ?? node.key.value);
    }
  });
  const edits = [];
  visit(program, (node) => {
    if (
      node.type === "MemberExpression" &&
      !node.computed &&
      node.object.type !== "Super" &&
      slot(node.property.name) &&
      !plain.has(node.property.name)
    ) {
      edits.push(
        [node.object.start, node.object.start, "__swiptSlots("],
        [node.object.end, node.object.end, ")"],
      );
    }
    if (
      node.type === "CallExpression" &&
      code.slice(node.callee.start, node.callee.end) ===
        "Object.prototype.hasOwnProperty.call" &&
      slot(node.arguments[1]?.value)
    ) {
      if (
        node.arguments[0].type !== "Identifier" ||
        plain.has(node.arguments[1].value)
      ) {
        throw new Error(
          `web-streams-polyfill checks ${node.arguments[1].value} in a form internal slots can't hide`,
        );
      }
      edits.push([
        node.start,
        node.end,
        `__swiptHasSlot(${node.arguments[0].name}, ${JSON.stringify(node.arguments[1].value)})`,
      ]);
    }
  });
  edits.sort((left, right) => right[0] - left[0] || right[1] - left[1]);
  let out = code;
  for (const [start, end, text] of edits) {
    out = out.slice(0, start) + text + out.slice(end);
  }
  return `const __swiptSlotMap = new WeakMap();
function __swiptSlots(value) {
  let slots = __swiptSlotMap.get(value);
  if (slots === undefined) {
    if ((typeof value !== "object" || value === null) && typeof value !== "function") {
      return value;
    }
    slots = Object.create(null);
    __swiptSlotMap.set(value, slots);
  }
  return slots;
}
function __swiptHasSlot(value, name) {
  const slots = __swiptSlotMap.get(value);
  return slots !== undefined && Object.hasOwn(slots, name);
}
${out}
export { __swiptSlots as internalSlots };
`;
};
