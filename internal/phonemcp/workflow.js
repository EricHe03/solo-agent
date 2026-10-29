((host, repl, workflow) => {
	"use strict";

	const string = (value, what) => {
		if (typeof value !== "string") {
			throw new TypeError(`${what} is not a string`);
		}
		return value;
	};

	const icon = value => {
		if (typeof value !== "object" || value === null) {
			throw new TypeError("the icon is not an object");
		}
		const { color, symbol } = value;
		return {
			color: color === undefined ? color : string(color, "the color"),
			symbol: symbol === undefined ? symbol : string(symbol, "the symbol"),
		};
	};

	class File {
		#location;
		#path;

		constructor(location, path) {
			this.#location = location;
			this.#path = path;
		}

		get path() {
			return this.#path;
		}

		exists() {
			return host.exists(...this.#location, this.#path);
		}

		text() {
			return host.text(...this.#location, this.#path);
		}

		json() {
			const text = this.text();
			try {
				return JSON.parse(text);
			} catch (error) {
				throw new SyntaxError(`${this.#path}: ${error.message}`);
			}
		}

		bytes() {
			return host.bytes(...this.#location, this.#path);
		}

		write(contents) {
			if (typeof contents === "string") {
				host.writeText(...this.#location, this.#path, contents);
			} else if (contents instanceof Uint8Array) {
				host.writeBytes(...this.#location, this.#path, contents);
			} else {
				throw new TypeError("the contents are neither a string nor a Uint8Array");
			}
		}

		remove() {
			host.remove(...this.#location, this.#path);
		}

		toString() {
			return this.#path;
		}
	}

	class Folder {
		#location;

		constructor(workflow, kind) {
			this.#location = [workflow, kind];
		}

		list() {
			return host.list(...this.#location).map(path => new File(this.#location, path));
		}

		file(path) {
			return new File(this.#location, string(path, "the path"));
		}
	}

	if (workflow !== undefined) {
		const modules = new Map();
		const load = async (specifier, referrer, ancestors) => {
			const path = host.resolve(string(specifier, "the module specifier"), referrer);
			const loaded = modules.get(path);
			if (loaded) {
				return ancestors.includes(path) ? loaded.namespace : loaded.done;
			}
			const namespace = Object.create(null);
			Object.defineProperty(namespace, Symbol.toStringTag, { value: "Module" });
			const define = (name, descriptor) => Object.defineProperty(namespace, name, { enumerable: true, ...descriptor });
			const chain = [...ancestors, path];
			const module = {
				import: next => load(next, path, chain),
				export: getters => {
					for (const name of Object.keys(getters)) {
						define(name, { get: getters[name] });
					}
				},
				define: (name, value) => define(name, { value }),
				reexport: (source, names) => {
					for (const name of Object.keys(names)) {
						define(name, { get: () => source[names[name]] });
					}
				},
				star: source => {
					for (const name of Object.keys(source)) {
						if (name !== "default" && !(name in namespace)) {
							define(name, { get: () => source[name] });
						}
					}
				},
			};
			const record = { namespace };
			modules.set(path, record);
			repl.modules.add(path);
			record.done = (async () => {
				const evaluate = host.evaluate(repl.transform(host.source(path), path), path);
				await evaluate(module);
				return namespace;
			})();
			return record.done;
		};
		return {
			dataFiles: new Folder(workflow, "data"),
			main: async () => (await load("./main.js", "", [])).default,
		};
	}

	class Workflow {
		#name;

		constructor(name) {
			this.#name = name;
		}

		get name() {
			return this.#name;
		}

		get sourceFiles() {
			return new Folder(this.#name, "source");
		}

		get dataFiles() {
			return new Folder(this.#name, "data");
		}

		get icon() {
			return host.icon(this.#name);
		}

		setIcon(value) {
			host.setIcon(this.#name, icon(value));
		}

		run() {
			return host.runWorkflow(this.#name);
		}

		remove() {
			host.removeWorkflow(this.#name);
		}

		toString() {
			return this.#name;
		}
	}

	return {
		workflows: {
			list: () => host.listWorkflows().map(name => new Workflow(name)),
			get: name => host.hasWorkflow(string(name, "the workflow name")) ? new Workflow(name) : null,
			create: (name, value = {}) => {
				host.createWorkflow(string(name, "the workflow name"), icon(value));
				return new Workflow(name);
			},
		},
	};
})
