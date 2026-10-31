import fs from "node:fs";
import path from "node:path";

import { TraceMap, originalPositionFor } from "@jridgewell/trace-mapping";

import { loadProject } from "./project.mjs";

const suffix = ".map";

function loadSourceMap(name) {
  const raw = JSON.parse(fs.readFileSync(name, "utf8"));
  const directory = path.dirname(name);
  const working = process.cwd();
  const resolve = source => {
    const resolved = path.join(directory, raw.sourceRoot ?? "", source);
    const relative = path.relative(working, resolved);
    return relative.startsWith("..") || path.isAbsolute(relative) ? resolved : relative;
  };
  const map = new TraceMap({ ...raw, sourceRoot: undefined });
  return (line, column) => {
    const found = originalPositionFor(map, { line, column: column - 1 });
    return found.source === null ? undefined : { file: resolve(found.source), line: found.line, column: found.column + 1 };
  };
}

export class SourceMaps {
  root = "";
  loaded = new Map();

  forSwiplet(id) {
    if (this.root === "") {
      return {};
    }
    if (this.loaded.has(id)) {
      return this.loaded.get(id);
    }
    const found = {};
    let project;
    try {
      project = loadProject(this.root);
    } catch {
      project = undefined;
    }
    if (project?.config.id === id) {
      const directory = path.join(project.root, "dist", id, "src");
      let names = [];
      try {
        names = fs.readdirSync(directory).filter(name => name.endsWith(suffix));
      } catch {
        names = [];
      }
      for (const name of names) {
        try {
          found[name.slice(0, -suffix.length)] = loadSourceMap(path.join(directory, name));
        } catch {
          continue;
        }
      }
    }
    this.loaded.set(id, found);
    return found;
  }

  forget(id) {
    this.loaded.delete(id);
  }

  frame(id) {
    return frame => {
      const lookup = this.forSwiplet(id)[frame.file];
      const mapped = lookup?.(frame.line, frame.column);
      return mapped ? { ...frame, ...mapped } : frame;
    };
  }
}

export const sources = new SourceMaps();
