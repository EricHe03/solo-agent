import { device } from "./device";
import { createDialog } from "./dialog";
import { failureOf } from "./errors";
import { inspect, jsonOf, setInputColumns } from "./format";
import { graphics } from "./graphics";
import { handleOf, Image } from "./image";
import { native } from "./native";
import { sleep } from "./timers";
import { ui } from "./ui";

const show = (image: unknown): void => {
  native.show(handleOf(image, "show's argument").showBytes());
};

const outcome = (value: unknown): string => {
  if (value === undefined) {
    return "";
  }
  if (value instanceof Image) {
    return JSON.stringify({ image: native.put(handleOf(value).showBytes()) });
  }
  return `{"text":${JSON.stringify(inspect(value))},"json":${jsonOf(value)}}`;
};

export const replGlobals = () => ({ device, ui, graphics, dialog: createDialog(), show, sleep });

export function launch(script: () => Promise<unknown>, columns: [output: number, input: number][][], id: string): void {
  setInputColumns(id, columns);
  void script().then(outcome).then(output => native.finish("", output, id), error => native.finish(failureOf(error), "", id));
}
