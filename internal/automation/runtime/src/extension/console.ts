import { createConsole } from "../shared/console";
import { inspect } from "../shared/inspect";
import { format, stackOf } from "./format";
import { native } from "./native";

export const console = createConsole({
  print: (severity, text) => native.print(severity, text),
  format,
  inspect,
  trace: label => `Trace${label === "" ? "" : `: ${label}`}${stackOf(new Error())}`,
  now: () => native.now(),
});
