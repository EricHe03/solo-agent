const outside = () => {
  throw new Error("swiplet/screen runs inside Swipt; build the swiplet with `swiplet build`");
};

export const screenshot = outside;
export const frames = undefined;
export const waitFor = outside;
export const waitForChange = outside;
export const waitForStable = outside;
export const record = outside;
export const openRecording = outside;
