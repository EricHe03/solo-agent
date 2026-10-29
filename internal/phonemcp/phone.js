((host, repl) => {
	"use strict";
	const { inspect, printed, describe } = repl;

	const defaultPages = 10;

	class Element {}
	class Screen {}
	class Result {}

	const clip = (text, limit) => text.length > limit ? `${text.slice(0, limit - limit / 3)}…${text.slice(-limit / 3)}` : text;
	const flags = ["selected", "focused", "disabled", "secure", "partial", "offScreen", "inert", "remote"];
	const line = element => {
		const parts = [`#${element.ref}`, element.role];
		if (element.class !== undefined) {
			parts.push(`class=${JSON.stringify(clip(element.class, 90))}`);
		}
		if (element.label !== undefined) {
			parts.push(JSON.stringify(clip(element.label, 300)));
		}
		if (element.value !== undefined) {
			parts.push(`value=${JSON.stringify(clip(element.value, 300))}`);
		}
		if (element.placeholder !== undefined) {
			parts.push(`placeholder=${JSON.stringify(element.placeholder)}`);
		}
		if (element.identifier !== undefined) {
			parts.push(`id=${JSON.stringify(clip(element.identifier, 120))}`);
		}
		if (element.url !== undefined) {
			parts.push(`url=${JSON.stringify(clip(element.url, 100))}`);
		}
		if (element.frame !== undefined) {
			parts.push(`[${element.frame.map(Math.round).join(",")}]`);
		}
		for (const flag of flags) {
			if (element[flag]) {
				parts.push(flag);
			}
		}
		if (element.expanded !== undefined) {
			parts.push(element.expanded ? "expanded" : "collapsed");
		}
		if (element.actions !== undefined) {
			parts.push(`actions=${JSON.stringify(element.actions)}`);
		}
		return parts.join(" ");
	};
	const short = element => {
		const parts = [`#${element.ref}`, element.role];
		const text = element.label ?? element.value ?? element.identifier;
		if (text !== undefined) {
			parts.push(JSON.stringify(clip(text, 60)));
		}
		return parts.join(" ");
	};
	const outline = root => {
		const lines = [];
		const visit = (element, depth) => {
			lines.push("  ".repeat(depth) + line(element));
			if (element.role === "keyboard") {
				return;
			}
			for (const child of element.children || []) {
				visit(child, depth + 1);
			}
		};
		visit(root, 0);
		return lines.join("\n");
	};
	const flatten = root => {
		const out = [];
		const visit = element => {
			out.push(element);
			for (const child of element.children || []) {
				visit(child);
			}
		};
		visit(root);
		return out;
	};
	const summary = result => {
		const lines = [result.target === undefined ? result.action : `${result.action} ${short(result.target)}`];
		for (const warning of result.warnings || []) {
			lines.push(`  ! ${warning}`);
		}
		return lines.join("\n");
	};
	const plain = text => text.replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").replace(/[\u00a0\u2007\u2009\u202f]/g, " ").trim();
	const stringFields = ["role", "class", "label", "value", "identifier", "placeholder", "hint", "url"];
	const stateFields = ["expanded"];
	const relations = ["within", "parent", "has"];
	const selectorFields = ["ref", ...stringFields, "traits", ...flags, ...stateFields, ...relations, "index"];
	const holds = (element, scope) => (element.children || []).some(child => scope.has(child.ref) || holds(child, scope));
	const matcher = (selector, universe) => {
		if (typeof selector === "function") {
			return element => Boolean(selector(element));
		}
		if (selector === null || typeof selector !== "object" || Array.isArray(selector) || selector instanceof Element) {
			throw new TypeError("expected a selector: an object of element fields, or a function of an element");
		}
		const entries = Object.entries(selector).filter(([key]) => key !== "index");
		if (entries.length === 0) {
			throw new TypeError("the selector is empty");
		}
		const checks = entries.map(([key, expected]) => {
			if (key === "ref") {
				if (typeof expected !== "number") {
					throw new TypeError("ref must be a number");
				}
				return element => element.ref === expected;
			}
			if (key === "traits") {
				if (!Array.isArray(expected) || !expected.every(item => typeof item === "string")) {
					throw new TypeError("traits must be an array of strings");
				}
				return element => expected.every(item => (element.traits || []).includes(item));
			}
			if (relations.includes(key)) {
				const scope = new Set((expected instanceof Element ? [expected] : select(universe, expected, universe)).map(item => item.ref));
				if (key === "parent") {
					return element => element.parent !== undefined && scope.has(element.parent.ref);
				}
				if (key === "has") {
					return element => holds(element, scope);
				}
				return element => {
					for (let ancestor = element.parent; ancestor !== undefined; ancestor = ancestor.parent) {
						if (scope.has(ancestor.ref)) {
							return true;
						}
					}
					return false;
				};
			}
			if (stateFields.includes(key)) {
				if (typeof expected !== "boolean") {
					throw new TypeError(`${key} must be a boolean`);
				}
				return element => element[key] === expected;
			}
			if (flags.includes(key)) {
				if (typeof expected !== "boolean") {
					throw new TypeError(`${key} must be a boolean`);
				}
				return element => expected === Boolean(element[key]);
			}
			if (stringFields.includes(key)) {
				if (expected instanceof RegExp) {
					return element => typeof element[key] === "string" && plain(element[key]).search(expected) >= 0;
				}
				if (typeof expected !== "string") {
					throw new TypeError(`${key} must be a string or a RegExp`);
				}
				const text = plain(expected);
				return element => typeof element[key] === "string" && plain(element[key]) === text;
			}
			throw new TypeError(`unknown element field ${JSON.stringify(key)}; the fields are ${selectorFields.join(", ")}`);
		});
		return element => checks.every(check => check(element));
	};
	const show = selector => typeof selector === "function" ? "the selector function" : inspect(selector);
	const ambiguous = (selector, found) => new Error(`${found.length} elements match ${show(selector)}; ${typeof selector === "function" ? "narrow the function down" : "add fields that tell them apart, within, parent, has or index"}:\n${found.slice(0, 8).map(line).join("\n")}${found.length > 8 ? "\n..." : ""}`);

	const wrap = (item, parent) => {
		if (item === undefined) {
			return item;
		}
		Object.setPrototypeOf(item, Element.prototype);
		if (parent !== undefined) {
			Object.defineProperty(item, "parent", { value: parent });
		}
		for (const child of item.children || []) {
			wrap(child, item);
		}
		return item;
	};
	const read = value => {
		const screen = Object.setPrototypeOf(host.screen(value), Screen.prototype);
		wrap(screen.root);
		wrap(screen.system);
		return screen;
	};
	const unread = ["focused", "inert"];
	const fieldsOf = (selector, fields) => {
		if (typeof selector === "function") {
			return false;
		}
		if (selector === null || typeof selector !== "object" || Array.isArray(selector) || selector instanceof Element) {
			throw new TypeError("expected a selector: an object of element fields, or a function of an element");
		}
		for (const [key, value] of Object.entries(selector)) {
			if (unread.includes(key)) {
				throw new TypeError(`${key} is not read by find; use phone.screen()`);
			}
			if (relations.includes(key)) {
				if (!(value instanceof Element) && !fieldsOf(value, fields)) {
					return false;
				}
			} else if (key !== "ref" && key !== "index") {
				fields.add(key);
			}
		}
		return true;
	};
	const search = selector => {
		const fields = new Set();
		const screen = Object.setPrototypeOf(host.find(fieldsOf(selector, fields) ? [...fields] : null), Screen.prototype);
		wrap(screen.root);
		return flatten(screen.root);
	};
	const everything = screen => screen.system === undefined ? flatten(screen.root) : [...flatten(screen.root), ...flatten(screen.system)];
	const select = (elements, selector, universe) => {
		const found = elements.filter(matcher(selector, universe));
		const at = typeof selector === "function" ? undefined : selector.index;
		if (at === undefined) {
			return found;
		}
		if (!Number.isInteger(at) || at < 0) {
			throw new TypeError("index must be a non-negative integer");
		}
		return at < found.length ? [found[at]] : [];
	};
	const unique = (elements, selector, universe) => {
		const found = select(elements, selector, universe);
		if (found.length > 1) {
			throw ambiguous(selector, found);
		}
		return found[0];
	};
	const universe = element => {
		let root = element;
		while (root.parent !== undefined) {
			root = root.parent;
		}
		return flatten(root);
	};
	Object.defineProperties(Screen.prototype, {
		find: { value(selector) { const all = everything(this); return unique(all, selector, all) ?? null; } },
		findAll: { value(selector) { const all = everything(this); return select(all, selector, all); } },
		toString: {
			value() {
				const app = `${this.app}\n${outline(this.root)}`;
				return this.system === undefined ? app : `${app}\ncom.apple.springboard, over the app\n${outline(this.system)}`;
			},
		},
	});
	Object.defineProperties(Element.prototype, {
		find: { value(selector) { return unique(flatten(this).slice(1), selector, universe(this)) ?? null; } },
		findAll: { value(selector) { return select(flatten(this).slice(1), selector, universe(this)); } },
		toString: { value() { return line(this); } },
	});
	Object.defineProperties(Result.prototype, {
		toString: { value() { return summary(this); } },
	});
	const acted = data => {
		Object.setPrototypeOf(data, Result.prototype);
		wrap(data.target);
		host.print(summary(data));
		printed.add(data);
		return data;
	};

	const options = (value, allowed) => {
		if (value === undefined) {
			return {};
		}
		if (value === null || typeof value !== "object" || Array.isArray(value)) {
			throw new TypeError("expected an options object");
		}
		for (const key of Object.keys(value)) {
			if (!allowed.includes(key)) {
				throw new TypeError(`unknown option ${JSON.stringify(key)}; the options are ${allowed.join(", ")}`);
			}
		}
		return value;
	};
	const where = screen => `${screen.app} is in front`;

	const resolve = target => {
		if (target instanceof Element) {
			return target;
		}
		const screen = read();
		const all = everything(screen);
		const found = unique(all, target, all);
		if (found === undefined) {
			throw new Error(`nothing matched ${show(target)}; ${where(screen)}`);
		}
		return found;
	};

	const scrolls = { down: "scrollDown", up: "scrollUp", left: "scrollLeft", right: "scrollRight" };
	const inside = (elements, frame) => {
		const x = frame[0] + frame[2] / 2, y = frame[1] + frame[3] / 2;
		return elements
			.filter(item => item.point !== undefined && item.children === undefined && item.role !== "application" && item.role !== "window" && item.role !== "key")
			.reduce((best, item) => best !== undefined && Math.hypot(best.point[0] - x, best.point[1] - y) <= Math.hypot(item.point[0] - x, item.point[1] - y) ? best : item, undefined);
	};
	const buttons = ["pressHome", "openAppSwitcher", "pressPower", "pressVolumeUp", "pressVolumeDown"];
	const listeners = new Map();
	host.listen((ids, payload) => {
		const event = JSON.parse(payload);
		for (const id of JSON.parse(ids)) {
			const entry = listeners.get(id);
			if (entry === undefined) {
				continue;
			}
			const fail = error => host.fail(`in a ${entry.event} listener: ${describe(error)}`);
			try {
				const result = entry.listener(event);
				if (result && typeof result.then === "function") {
					result.then(undefined, fail);
				}
			} catch (error) {
				fail(error);
			}
		}
	});
	const api = {
		status: host.status,
		unlock: (...args) => acted(host.unlock(...args)),
		screen: value => {
			const { within, ...rest } = options(value, ["raw", "within", "fast"]);
			const screen = read(rest);
			if (within === undefined) {
				return screen;
			}
			const all = everything(screen);
			const root = unique(all, within instanceof Element ? { ref: within.ref } : within, all);
			if (root === undefined) {
				throw new Error(`nothing matched ${show(within)}; ${where(screen)}`);
			}
			return Object.setPrototypeOf({ app: screen.app, root }, Screen.prototype);
		},
		find: selector => {
			const all = search(selector);
			return unique(all, selector, all) ?? null;
		},
		findAll: selector => {
			const all = search(selector);
			return select(all, selector, all);
		},
		elementAt: (point, value) => {
			const found = host.elementAt(point, options(value, ["fast"]));
			return found.listed === false ? found : wrap(found);
		},
		waitFor: (condition, value) => {
			const { timeoutMs, optional, ...view } = options(value, ["timeoutMs", "raw", "fast", "optional"]);
			if (typeof condition !== "function") {
				throw new TypeError("the condition must be a function");
			}
			if (timeoutMs !== undefined && !(Number.isFinite(timeoutMs) && timeoutMs > 0)) {
				throw new TypeError("timeoutMs must be a positive number of milliseconds");
			}
			if (optional && timeoutMs === undefined) {
				throw new TypeError("optional needs a timeoutMs");
			}
			const started = Date.now();
			for (;;) {
				const screen = read(view);
				const answer = condition(screen);
				if (answer && typeof answer.then === "function") {
					throw new TypeError("the condition must return its answer, not a promise");
				}
				if (answer) {
					return answer;
				}
				if (timeoutMs !== undefined && Date.now() - started >= timeoutMs) {
					if (optional) {
						return null;
					}
					throw new Error(`the condition stayed false for ${timeoutMs} ms, while ${where(screen)}`);
				}
			}
		},
		scrollTo: (selector, value) => {
			const { direction = "down", within, pages = defaultPages } = options(value, ["direction", "within", "pages"]);
			const action = scrolls[direction];
			if (action === undefined) {
				throw new TypeError(`direction must be one of ${Object.keys(scrolls).join(", ")}`);
			}
			if (!Number.isInteger(pages) || pages < 1) {
				throw new TypeError("pages must be a positive integer");
			}
			let paged = 0;
			let revealed;
			let settled;
			let moving;
			for (;;) {
				const screen = read();
				const elements = everything(screen);
				const scroller = within === undefined ? undefined : unique(elements, within, elements);
				if (within !== undefined && scroller === undefined) {
					throw new Error(`nothing matched ${show(within)}; ${where(screen)}`);
				}
				const element = unique(scroller === undefined ? elements : flatten(scroller).slice(1), selector, elements);
				if (element !== undefined && element.frame !== undefined && !element.offScreen && !element.inert) {
					const position = String(element.frame);
					if ((paged > 0 || revealed !== undefined) && position !== moving) {
						moving = position;
						continue;
					}
					host.print(`scrollTo ${short(element)}: ${paged === 0 ? "on the screen already" : `on the screen after ${paged} pages scrolled ${direction}`}`);
					return element;
				}
				if (element !== undefined) {
					const position = String(element.frame);
					if (position === revealed) {
						throw new Error(`${line(element)} stayed where it was after scrolling it into view`);
					}
					revealed = position;
					moving = undefined;
					host.perform(element.ref, "scrollToVisible");
					continue;
				}
				const view = inside(scroller === undefined ? elements : flatten(scroller), scroller?.frame ?? screen.root.frame) ?? scroller;
				if (view === undefined) {
					throw new Error("nothing on the screen to scroll");
				}
				if (host.supports(view.ref, action)) {
					if (paged >= pages) {
						throw new Error(`${show(selector)} did not come on the screen within ${pages} pages scrolled ${direction}; pass more pages to go on`);
					}
					try {
						host.perform(view.ref, action);
					} catch (error) {
						if (/ refused to perform /.test(String(error))) {
							throw new Error(`${show(selector)} did not come on the screen: ${short(view)} could not scroll further after ${paged} pages scrolled ${direction}`);
						}
						throw error;
					}
					paged++;
					settled = moving = undefined;
					continue;
				}
				// The device answered that a list could scroll no further while the
				// read before it still had the list 222 points short of where it
				// stopped (iPhone18,2, iOS 27.2 24B115).
				const signature = elements.map(item => `${item.ref}@${item.frame}`).join("\n");
				if (signature === settled) {
					throw new Error(`${show(selector)} did not come on the screen: ${short(view)} could not scroll further after ${paged} pages scrolled ${direction}`);
				}
				settled = signature;
			}
		},
		tap: (target, value) => acted(Array.isArray(target) ? host.tapPoint(target, value) : host.tap(resolve(target).ref, value)),
		setText: (target, text) => {
			if (typeof text !== "string") {
				throw new TypeError("the text must be a string");
			}
			return acted(host.setText(resolve(target).ref, text));
		},
		perform: (target, action) => {
			if (typeof action !== "string") {
				throw new TypeError("the action must be a string");
			}
			return acted(host.perform(resolve(target).ref, action));
		},
		swipe: (...args) => acted(host.swipe(...args)),
		drag: (...args) => acted(host.drag(...args)),
		pinch: (...args) => acted(host.pinch(...args)),
		touch: (...args) => acted(host.touch(...args)),
		pressKey: (...args) => acted(host.pressKey(...args)),
		screenshot: host.screenshot,
		recognizeText: host.recognizeText,
		apps: host.apps,
		launch: (...args) => acted(host.launch(...args)),
		clipboard: host.clipboard,
		setClipboard: host.setClipboard,
		setLocation: (...args) => acted(host.setLocation(...args)),
		clearLocation: (...args) => acted(host.clearLocation(...args)),
		logs: host.logs,
		record: () => {
			const id = host.record();
			return Object.freeze({ stop: () => host.stopRecording(id) });
		},
		on: (event, listener) => {
			if (typeof listener !== "function") {
				throw new TypeError("the listener is not a function");
			}
			const id = host.subscribe(event);
			listeners.set(id, { event, listener });
			return Object.freeze({
				cancel: () => {
					if (listeners.delete(id)) {
						host.unsubscribe(id);
					}
				},
			});
		},
	};
	for (const button of buttons) {
		api[button] = () => acted(host[button]());
	}
	const argument = value => value instanceof Element ? short(value) : typeof value === "function" ? String(value) : inspect(value);
	const phone = {};
	for (const [name, run] of Object.entries(api)) {
		const call = (...args) => {
			host.callStarted(`${name}(${args.map(argument).join(", ")})`);
			try {
				return run(...args);
			} catch (error) {
				if (error instanceof Error) {
					error.message = `phone.${name}: ${error.message}`;
				}
				throw error;
			} finally {
				host.callEnded();
			}
		};
		Object.defineProperty(call, "name", { value: name });
		phone[name] = call;
	}

	return Object.freeze(phone);
})
