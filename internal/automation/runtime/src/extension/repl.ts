import { inspect } from "../shared/inspect";
import { accessibility, device, image, input, screen } from "./api";
import { createDialog } from "./dialog";
import { failureOf } from "./errors";
import { dataDirectory } from "./files";
import { jsonOf, setInputColumns } from "./format";
import { handleOf, RasterImage } from "./image";
import { native } from "./native";

const show = (image: unknown): void => {
  native.show(handleOf(image, "show's argument").showBytes());
};

const outcome = (value: unknown): string => {
  if (value === undefined) {
    return "";
  }
  if (value instanceof RasterImage) {
    return JSON.stringify({ image: native.put(handleOf(value).showBytes()) });
  }
  return `{"text":${JSON.stringify(inspect(value))},"json":${jsonOf(value)}}`;
};

export const replGlobals = () => ({ accessibility, input, device, screen, image, dataDirectory: dataDirectory(), dialog: createDialog(), show });

export function launch(script: () => Promise<unknown>, columns: [output: number, input: number][][], id: string): void {
  setInputColumns(id, columns);
  void script().then(outcome).then(output => native.finish("", output, id), error => native.finish(failureOf(error), "", id));
}
