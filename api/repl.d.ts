declare global {
  const accessibility: typeof import("@swipt/api/accessibility");
  const input: typeof import("@swipt/api/input");
  const device: typeof import("@swipt/api/device");
  var screen: Screen;
  interface Screen extends Readonly<typeof import("@swipt/api/screen")> {}
  const image: typeof import("@swipt/api/image");
  const dataDirectory: import("@swipt/api/file-system").DirectoryHandle;
  const dialog: import("@swipt/api/swiplet").IntentDialog;
  const args: readonly string[];

  function show(image: import("@swipt/api/image").RasterImage): void;
}

export {};
