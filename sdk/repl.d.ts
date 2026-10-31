declare global {
  const accessibility: typeof import("swiplet/accessibility");
  const input: typeof import("swiplet/input");
  const device: typeof import("swiplet/device");
  const screen: typeof import("swiplet/screen");
  const image: typeof import("swiplet/image");
  const dialog: import("swiplet/extension").IntentDialog;
  const sleep: typeof import("swiplet/extension").sleep;

  function show(image: import("swiplet/image").RasterImage): void;
}

export {};
