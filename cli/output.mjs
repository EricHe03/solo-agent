import { timestampDate } from "@bufbuild/protobuf/wkt";

import { LogLevel, LogLevelSchema } from "./proto/common_pb.js";
import { ServiceStatus, ServiceStatusSchema } from "./proto/swiplets_pb.js";

export class FalseResult extends Error {}

export const enumText = (schema, value, prefix) =>
  schema.value[value].name
    .slice(prefix.length)
    .toLowerCase()
    .replaceAll("_", " ");

const levelName = (level) =>
  level === LogLevel.UNSPECIFIED
    ? "info"
    : enumText(LogLevelSchema, level, "LOG_LEVEL_");

const pad = (value, width) => String(value).padStart(width, "0");

export function clockTime(timestamp) {
  const at = timestampDate(timestamp);
  return `${pad(at.getHours(), 2)}:${pad(at.getMinutes(), 2)}:${pad(at.getSeconds(), 2)}.${pad(at.getMilliseconds(), 3)}`;
}

export function dateTime(timestamp) {
  const at = timestampDate(timestamp);
  return `${at.getFullYear()}-${pad(at.getMonth() + 1, 2)}-${pad(at.getDate(), 2)} ${pad(at.getHours(), 2)}:${pad(at.getMinutes(), 2)}:${pad(at.getSeconds(), 2)}`;
}

export function columns(rows) {
  const widths = [];
  for (const row of rows) {
    row.forEach((cell, index) => {
      widths[index] = Math.max(widths[index] ?? 0, cell.length);
    });
  }
  return rows
    .map((row) =>
      row
        .map((cell, index) =>
          index === row.length - 1 ? cell : cell.padEnd(widths[index] + 2),
        )
        .join("")
        .trimEnd(),
    )
    .join("\n");
}

const frameText = (frame) => {
  const position = `${frame.file}:${frame.line}:${frame.column}`;
  return frame.function === "" ? position : `${frame.function} (${position})`;
};

export const failureText = (failure) =>
  [
    `${failure.name}: ${failure.message}`,
    ...failure.stack.map((frame) => `    at ${frameText(frame)}`),
  ].join("\n");

export function printScriptError(failure) {
  console.error(`error: ${failureText(failure)}`);
  return new FalseResult();
}

export function printLog(entry, toStdout) {
  const message =
    entry.tag === "" ? entry.message : `${entry.tag}: ${entry.message}`;
  (toStdout ? console.log : console.error)(
    clockTime(entry.time),
    levelName(entry.level).toUpperCase(),
    message,
  );
}

export function serviceText(id, state) {
  let text = state?.enabled ? "enabled" : "disabled";
  text += `, ${state && state.status !== ServiceStatus.UNSPECIFIED ? enumText(ServiceStatusSchema, state.status, "SERVICE_STATUS_") : "stopped"}`;
  if (state?.since) {
    text += ` since ${clockTime(state.since)}`;
  }
  if (state?.error) {
    text += `: ${failureText(state.error)}`;
  }
  return text;
}
