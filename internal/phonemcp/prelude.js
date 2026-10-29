(() => {
	"use strict";
	const { parse, parseModule } = globalThis.meriyah;
	delete globalThis.meriyah;

	const printed = new WeakSet();
	const modules = new Set();
	const located = new WeakSet();

	const position = (url, line) => {
		if (modules.has(url)) {
			return ` (${url}:${line})`;
		}
		if (url === "input.js") {
			return ` (line ${line - 1})`;
		}
		return undefined;
	};
	const location = error => {
		for (const frame of String(error.stack).split("\n")) {
			const match = /^[^@]*@(.+):(\d+):\d+$/.exec(frame);
			const text = match && position(match[1], Number(match[2]));
			if (text) {
				return text;
			}
		}
		return error.line > 0 && position(error.sourceURL, error.line) || "";
	};
	const describe = error => error instanceof Error ? `${error.name}: ${error.message}${located.has(error) ? "" : location(error)}` : `Uncaught ${format(error)}`;
	const custom = value => !Array.isArray(value) && typeof value.toString === "function" && value.toString !== Object.prototype.toString;
	const inspect = (value, ancestors = []) => {
		switch (typeof value) {
		case "string":
			return JSON.stringify(value);
		case "number":
			return Object.is(value, -0) ? "-0" : String(value);
		case "bigint":
			return `${value}n`;
		case "undefined":
		case "boolean":
		case "symbol":
			return String(value);
		case "function":
			return value.name ? `[Function ${value.name}]` : "[Function]";
		}
		if (value === null) {
			return "null";
		}
		if (ancestors.includes(value)) {
			return "[Circular]";
		}
		if (value instanceof Error) {
			return `${value.name}: ${value.message}`;
		}
		if (value instanceof Date) {
			return Number.isNaN(value.getTime()) ? "Invalid Date" : value.toISOString();
		}
		if (value instanceof RegExp) {
			return String(value);
		}
		if (value instanceof Promise) {
			return "Promise {}";
		}
		if (custom(value)) {
			return String(value);
		}
		ancestors = [...ancestors, value];
		const nested = item => inspect(item, ancestors);
		if (Array.isArray(value)) {
			if (value.length > 0 && value.every(item => item !== null && typeof item === "object" && custom(item))) {
				return value.map(String).join("\n");
			}
			return `[${Array.from(value, nested).join(",")}]`;
		}
		if (value instanceof Map) {
			return `Map(${value.size}) {${Array.from(value, ([key, item]) => `${nested(key)} => ${nested(item)}`).join(", ")}}`;
		}
		if (value instanceof Set) {
			return `Set(${value.size}) {${Array.from(value, nested).join(", ")}}`;
		}
		const body = `{${Object.keys(value).map(key => `${JSON.stringify(key)}:${nested(value[key])}`).join(",")}}`;
		const prototype = Object.getPrototypeOf(value);
		const name = prototype && prototype !== Object.prototype && prototype.constructor && prototype.constructor.name;
		return name ? `${name} ${body}` : body;
	};
	const format = value => {
		if (typeof value === "string") {
			return value;
		}
		if (value instanceof Error) {
			return describe(value);
		}
		return inspect(value);
	};

	const bindings = (pattern, names) => {
		switch (pattern && pattern.type) {
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
	const rewrite = code => {
		const head = "(async () => {\n";
		const source = head + code + "\n})";
		let program;
		try {
			program = parse(source, { ranges: true, webcompat: true });
		} catch (error) {
			if (error.loc) {
				throw new SyntaxError(`${error.description} (line ${error.loc.start.line - 1}, column ${error.loc.start.column + 1})`);
			}
			throw error;
		}
		const body = program.body[0].expression.body.body;
		const names = new Set();
		const hoisted = [];
		const edits = [];
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
			}
		}
		const last = body.at(-1);
		if (last && last.type === "ExpressionStatement") {
			edits.push([last.start, 0, "return ("]);
			edits.push([source[last.end - 1] === ";" ? last.end - 1 : last.end, 0, ")"]);
		}
		let text = source;
		for (const [position, length, insert] of edits.reverse()) {
			text = text.slice(0, position) + insert + text.slice(position + length);
		}
		const declarations = names.size > 0 ? `var ${[...names].join(", ")};` : "";
		return `${declarations}${head.slice(0, -1)}${hoisted.join("")}\n${text.slice(head.length)}`;
	};

	const transform = (code, url) => {
		let program;
		try {
			program = parseModule(code, { ranges: true });
		} catch (error) {
			if (error.loc) {
				const failure = new SyntaxError(`${error.description} (${url}:${error.loc.start.line}:${error.loc.start.column + 1})`);
				located.add(failure);
				throw failure;
			}
			throw error;
		}
		const edits = [];
		const replace = (start, end, insert) => {
			edits.push([start, end - start, insert + code.slice(start, end).replace(/[^\n\r\u2028\u2029]/g, "")]);
		};
		const name = node => JSON.stringify(node.type === "Identifier" ? node.name : node.value);
		const load = node => `await __module.import(${JSON.stringify(node.source.value)})`;
		const getters = [];
		const imports = [];
		for (const node of program.body) {
			switch (node.type) {
			case "ImportDeclaration": {
				replace(node.start, node.end, "");
				const namespace = node.specifiers.find(specifier => specifier.type === "ImportNamespaceSpecifier");
				const named = node.specifiers.filter(specifier => specifier !== namespace).map(specifier =>
					`${specifier.type === "ImportDefaultSpecifier" ? "default" : name(specifier.imported)}: ${specifier.local.name}`);
				if (namespace) {
					const destructured = named.length > 0 ? `, {${named.join(", ")}} = ${namespace.local.name}` : "";
					imports.push(`const ${namespace.local.name} = ${load(node)}${destructured};`);
				} else if (named.length > 0) {
					imports.push(`const {${named.join(", ")}} = ${load(node)};`);
				} else {
					imports.push(`${load(node)};`);
				}
				break;
			}
			case "ExportAllDeclaration":
				replace(node.start, node.end, "");
				imports.push(node.exported ? `__module.define(${name(node.exported)}, ${load(node)});` : `__module.star(${load(node)});`);
				break;
			case "ExportNamedDeclaration":
				if (node.declaration) {
					replace(node.start, node.declaration.start, "");
					const names = new Set();
					if (node.declaration.type === "VariableDeclaration") {
						for (const declarator of node.declaration.declarations) {
							bindings(declarator.id, names);
						}
					} else {
						names.add(node.declaration.id.name);
					}
					for (const local of names) {
						getters.push(`${JSON.stringify(local)}: () => ${local}`);
					}
				} else if (node.source) {
					replace(node.start, node.end, "");
					const names = node.specifiers.map(specifier => `${name(specifier.exported)}: ${name(specifier.local)}`);
					imports.push(`__module.reexport(${load(node)}, {${names.join(", ")}});`);
				} else {
					replace(node.start, node.end, "");
					for (const specifier of node.specifiers) {
						getters.push(`${name(specifier.exported)}: () => ${specifier.local.name}`);
					}
				}
				break;
			case "ExportDefaultDeclaration": {
				const declaration = node.declaration;
				if (declaration.type.endsWith("Declaration") && declaration.id) {
					replace(node.start, declaration.start, "");
					getters.push(`default: () => ${declaration.id.name}`);
				} else {
					replace(node.start, declaration.start, "__module.define(\"default\", ");
					edits.push([declaration.end, 0, declaration.type.endsWith("Declaration") ? ");" : ")"]);
				}
				break;
			}
			}
		}
		const visit = node => {
			if (Array.isArray(node)) {
				node.forEach(visit);
			} else if (node !== null && typeof node === "object") {
				if (node.type === "ImportExpression") {
					edits.push([node.start, "import".length, "__module.import"]);
				}
				for (const key in node) {
					if (key !== "range") {
						visit(node[key]);
					}
				}
			}
		};
		visit(program.body);
		let text = code;
		for (const [position, length, insert] of edits.sort((a, b) => b[0] - a[0] || b[1] - a[1])) {
			text = text.slice(0, position) + insert + text.slice(position + length);
		}
		const exports = getters.length > 0 ? `__module.export({${getters.join(", ")}});` : "";
		return `(async function (__module) {"use strict";${exports}${imports.join("")}${text}\n})`;
	};

	return {
		rewrite,
		transform,
		modules,
		// JavaScriptCore reports a rejection with no handlers once the outermost
		// call into it returns (WebKit 21bb1f66,
		// Source/JavaScriptCore/runtime/JSLock.cpp:315; WebKit 21bb1f66,
		// Source/JavaScriptCore/runtime/VM.cpp:1458).
		launch: (script, fulfilled, rejected) => {
			void script().then(fulfilled, rejected);
		},
		format: (...values) => values.map(format).join(" "),
		outcome: value => value === undefined || printed.has(value) ? "" : format(value),
		describe,
		sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
		inspect,
		printed,
	};
})()
