((host, repl) => {
	"use strict";
	const { inspect } = repl;

	const styles = ["default", "destructive", "cancel"];
	const actionNames = ["add", "addData", "book", "buy", "call", "checkIn", "continue", "create", "do", "download", "filter", "find",
		"get", "go", "log", "open", "order", "pay", "play", "playSound", "post", "request", "run", "search", "send", "set", "share", "start",
		"startNavigation", "toggle", "turnOff", "turnOn", "view"];
	const types = ["text", "integer", "number", "date", "time", "dateTime", "file", "person", "placemark"];

	const options = (value, allowed) => {
		if (value === undefined) {
			return {};
		}
		if (value === null || typeof value !== "object" || Array.isArray(value)) {
			throw new TypeError("expected an options object");
		}
		for (const key of Object.keys(value)) {
			if (!allowed.includes(key)) {
				throw new TypeError(allowed.length === 0 ? `unknown option ${JSON.stringify(key)}; this type has no options` : `unknown option ${JSON.stringify(key)}; the options are ${allowed.join(", ")}`);
			}
		}
		return value;
	};
	const text = (value, name) => {
		if (typeof value !== "string") {
			throw new TypeError(`${name} must be a string, not ${inspect(value)}`);
		}
		return value;
	};
	const prompt = value => value === undefined ? undefined : text(value, "the prompt");
	const flag = (value, name) => {
		if (typeof value !== "boolean") {
			throw new TypeError(`${name} must be a boolean`);
		}
		return value;
	};
	const strings = (values, name) => {
		if (!Array.isArray(values) || values.length === 0 || !values.every(value => typeof value === "string")) {
			throw new TypeError(`${name} must be a non-empty array of strings`);
		}
		return values;
	};
	const range = (min, max, integer) => {
		for (const [name, value] of [["min", min], ["max", max]]) {
			if (value !== undefined && !(integer ? Number.isSafeInteger(value) : Number.isFinite(value))) {
				throw new TypeError(`${name} must be ${integer ? "an integer" : "a finite number"}`);
			}
		}
		if (min !== undefined && max !== undefined && min > max) {
			throw new TypeError("min is greater than max");
		}
	};

	const api = {
		requestChoice: (choices, message) => {
			if (!Array.isArray(choices) || choices.length === 0) {
				throw new TypeError("the options must be a non-empty array");
			}
			const list = choices.map(choice => {
				if (typeof choice === "string") {
					return { title: choice, style: "default" };
				}
				const { title, style = "default" } = options(choice, ["title", "style"]);
				if (!styles.includes(style)) {
					throw new TypeError(`style must be one of ${styles.join(", ")}`);
				}
				return { title: text(title, "an option's title"), style };
			});
			return choices[host.ask({ kind: "choice", prompt: text(message, "the prompt"), options: list })];
		},
		requestConfirmation: (message, value) => {
			let { actionName = "continue" } = options(value, ["actionName"]);
			if (typeof actionName === "object" && actionName !== null) {
				const { accept, deny, destructive = false } = options(actionName, ["accept", "deny", "destructive"]);
				actionName = { accept: text(accept, "accept"), deny: text(deny, "deny"), destructive: flag(destructive, "destructive") };
			} else if (!actionNames.includes(actionName)) {
				throw new TypeError(`actionName must be one of ${actionNames.join(", ")}, or an object of accept, deny and destructive`);
			}
			host.ask({ kind: "confirmation", prompt: text(message, "the prompt"), actionName });
		},
		requestValue: (type, message, value) => {
			const request = { kind: "value", type, prompt: prompt(message) };
			switch (type) {
			case "text": {
				const { multiline = false, literal = false } = options(value, ["multiline", "literal"]);
				return host.askInApp({ ...request, multiline: flag(multiline, "multiline"), literal: flag(literal, "literal") });
			}
			case "integer": {
				const { stepper = false, min, max } = options(value, ["stepper", "min", "max"]);
				range(min, max, true);
				return host.askInApp({ ...request, stepper: flag(stepper, "stepper"), min, max });
			}
			case "number": {
				const { min, max } = options(value, ["min", "max"]);
				range(min, max, false);
				return host.askInApp({ ...request, min, max });
			}
			case "date":
			case "time":
			case "dateTime":
				options(value, []);
				return new Date(host.askInApp(request));
			case "file": {
				options(value, []);
				const { name, type: fileType, data } = host.askInApp(request);
				return { name, type: fileType, bytes: host.bytes(data) };
			}
			case "person":
			case "placemark":
				options(value, []);
				return host.askInApp(request);
			default:
				throw new TypeError(`the type must be one of ${types.join(", ")}`);
			}
		},
		requestDisambiguation: (values, message) => values[host.ask({ kind: "disambiguation", prompt: text(message, "the prompt"), values: strings(values, "the values") })],
		requestValueConfirmation: (value, message) => host.ask({ kind: "valueConfirmation", prompt: text(message, "the prompt"), value: text(value, "the value") }),
		continueInForeground: (message, value) => {
			const { alwaysConfirm = true } = options(value, ["alwaysConfirm"]);
			host.ask({ kind: "foreground", prompt: prompt(message), alwaysConfirm: flag(alwaysConfirm, "alwaysConfirm") });
			host.stay();
		},
	};

	const dialog = {};
	for (const [name, run] of Object.entries(api)) {
		const call = (...args) => {
			try {
				return run(...args);
			} catch (error) {
				if (error instanceof Error) {
					error.message = `dialog.${name}: ${error.message}`;
				}
				throw error;
			}
		};
		Object.defineProperty(call, "name", { value: name });
		dialog[name] = call;
	}
	return Object.freeze(dialog);
})
