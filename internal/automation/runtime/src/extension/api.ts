import { find, locator, snapshot, tap } from "./accessibility";
import * as deviceModule from "./device";
import { decode } from "./image";
import * as inputModule from "./input";
import { frames, openRecording, record, screenshot, waitFor, waitForChange, waitForStable } from "./screen";

export const accessibility = Object.freeze({ locator, snapshot, find, tap });
export const input = Object.freeze({ ...inputModule });
export const device = Object.freeze({ ...deviceModule });
export const screen = Object.freeze({ screenshot, frames, waitFor, waitForChange, waitForStable, record, openRecording });
export const image = Object.freeze({ decode });
