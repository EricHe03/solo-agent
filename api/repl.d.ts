declare global {
  const accessibility: typeof import("@swipt/api/accessibility");
  const input: typeof import("@swipt/api/input");
  const device: typeof import("@swipt/api/device");
  const screen: typeof import("@swipt/api/screen");
  const image: typeof import("@swipt/api/image");
  const dialog: import("@swipt/api/swiplet").IntentDialog;

  function show(image: import("@swipt/api/image").RasterImage): void;
}

export {};
