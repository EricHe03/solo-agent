import { parse } from "meriyah";

import { completion, hoist, replHead } from "./head";

type Node = { type: string; start: number; end: number; [key: string]: any };
type Edit = [position: number, length: number, insert: string];

const bindings = (pattern: Node | null, names: Set<string>): void => {
  switch (pattern?.type) {
    case "Identifier":
      names.add(pattern.name);
      break;
    case "ObjectPattern":
      for (const property of pattern.properties) {
        bindings(property.type === "RestElement" ? property.argument : property.value, names);
      }
      break;
    case "ArrayPattern":
      for (const item of pattern.elements) {
        bindings(item, names);
      }
      break;
    case "AssignmentPattern":
      bindings(pattern.left, names);
      break;
    case "RestElement":
      bindings(pattern.argument, names);
      break;
  }
};

const resetting = ["IfStatement", "TryStatement", "SwitchStatement", "WithStatement", "ForStatement", "ForInStatement", "ForOfStatement", "WhileStatement", "DoWhileStatement"];

const unlabeled = (node: Node): Node => node.type === "LabeledStatement" ? unlabeled(node.body) : node;

const reset = `${completion} = void 0;`;

const track = (source: string, edits: Edit[]) => {
  const statement = (node: Node | null, listed: boolean, finalizer: boolean): void => {
    if (node === null) {
      return;
    }
    const core = unlabeled(node);
    const wrapped = !finalizer && !listed && resetting.includes(core.type);
    if (!finalizer && listed && resetting.includes(core.type)) {
      edits.push([node.start, 0, reset]);
    }
    if (wrapped) {
      edits.push([node.start, 0, `{${reset}`]);
    }
    inner(core, finalizer);
    if (wrapped) {
      edits.push([node.end, 0, "}"]);
    }
  };
  const list = (nodes: Node[], finalizer: boolean) => {
    for (const node of nodes) {
      statement(node, true, finalizer);
    }
  };
  const inner = (node: Node, finalizer: boolean): void => {
    switch (node.type) {
      case "ExpressionStatement":
        if (!finalizer && node.directive !== "use strict") {
          const terminated = source[node.end - 1] === ";";
          edits.push([node.start, 0, `${completion} = (`]);
          edits.push([terminated ? node.end - 1 : node.end, 0, terminated ? ")" : ");"]);
        }
        break;
      case "BlockStatement":
        list(node.body, finalizer);
        break;
      case "IfStatement":
        statement(node.consequent, false, finalizer);
        statement(node.alternate, false, finalizer);
        break;
      case "ForStatement":
      case "ForInStatement":
      case "ForOfStatement":
      case "WhileStatement":
      case "DoWhileStatement":
      case "WithStatement":
        statement(node.body, false, finalizer);
        break;
      case "TryStatement":
        list(node.block.body, finalizer);
        if (node.handler) {
          list(node.handler.body.body, finalizer);
        }
        if (node.finalizer) {
          list(node.finalizer.body, true);
        }
        break;
      case "SwitchStatement":
        for (const branch of node.cases) {
          list(branch.consequent, finalizer);
        }
        break;
    }
  };
  return list;
};

export type Columns = [output: number, input: number][][];

const columnsOf = (source: string, start: number, edits: (readonly [number, number, string, number])[]): Columns => {
  const starts = [start];
  for (let index = source.indexOf("\n", start); index >= 0; index = source.indexOf("\n", index + 1)) {
    starts.push(index + 1);
  }
  const columns: Columns = starts.map((_, line) => [[line === 0 ? replHead.length + 1 : 1, 1]]);
  for (const [position, length, insert] of [...edits].sort((a, b) => a[0] - b[0] || a[3] - b[3])) {
    let line = starts.length - 1;
    while (line > 0 && starts[line] > position) {
      line--;
    }
    const column = position - starts[line] + 1;
    const anchors = columns[line];
    const [output, input] = anchors[anchors.length - 1];
    anchors.push([output + column - input + insert.length, column + length]);
  }
  return columns;
};

export function rewrite(code: string): { text: string; columns: Columns } {
  const head = "(async () => {";
  const source = `${head}${code}\n})`;
  let program: Node;
  try {
    program = parse(source, { ranges: true, loc: true, webcompat: true }) as unknown as Node;
  } catch (error) {
    const located = error as { loc?: { start: { line: number; column: number } }; description?: string };
    if (located.loc) {
      const { line, column } = located.loc.start;
      throw new SyntaxError(`${located.description} (line ${line}, column ${(line === 1 ? column - head.length : column) + 1})`);
    }
    throw error;
  }
  const body: Node[] = program.body[0].expression.body.body;
  const names = new Set<string>();
  const hoisted: string[] = [];
  const edits: Edit[] = [];
  const list = track(source, edits);
  for (const node of body) {
    switch (node.type) {
      case "VariableDeclaration":
        if (node.kind !== "var" && node.kind !== "let" && node.kind !== "const") {
          break;
        }
        edits.push([node.start, node.kind.length, ";"]);
        for (const declarator of node.declarations) {
          bindings(declarator.id, names);
          edits.push([declarator.start, 0, "("]);
          edits.push([declarator.end, 0, declarator.init ? ")" : " = void 0)"]);
        }
        break;
      case "FunctionDeclaration":
        names.add(node.id.name);
        hoisted.push(`globalThis[${JSON.stringify(node.id.name)}] = ${node.id.name};`);
        break;
      case "ClassDeclaration":
        names.add(node.id.name);
        edits.push([node.start, 0, `;${node.id.name} = `]);
        edits.push([node.end, 0, ";"]);
        break;
      default:
        list([node], false);
    }
  }
  let text = source;
  const ordered = edits.map((edit, index) => [...edit, index] as const).sort((a, b) => b[0] - a[0] || b[3] - a[3]);
  for (const [position, length, insert] of ordered) {
    text = text.slice(0, position) + insert + text.slice(position + length);
  }
  const declarations = names.size > 0 ? `\n;var ${[...names].join(", ")};` : "";
  return {
    text: `${replHead}${text.slice(head.length, -2)}\n;function ${hoist}() {${hoisted.join("")}}\nreturn ${completion};})${declarations}`,
    columns: columnsOf(source.slice(0, -3), head.length, ordered),
  };
}
