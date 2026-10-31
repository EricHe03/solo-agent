const outside = () => {
  throw new Error("@swipt/api/screen runs inside Swipt; build the swiplet with `swipt build`");
};

export const screenshot = outside;
export const frames = undefined;
export const waitFor = outside;
export const waitForChange = outside;
export const waitForStable = outside;
export const record = outside;
export const openRecording = outside;
