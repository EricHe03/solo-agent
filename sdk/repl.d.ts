import type * as sdk from "./extension";

declare global {
  const device: typeof sdk.device;
  const ui: typeof sdk.ui;
  const graphics: typeof sdk.graphics;
  const dialog: sdk.Dialog;
  const sleep: typeof sdk.sleep;

  function show(image: sdk.Image): void;
}

export {};
