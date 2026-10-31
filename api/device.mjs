const outside = () => {
  throw new Error("@swipt/api/device runs inside Swipt; build the swiplet with `swiplet build`");
};

export const info = outside;
export const foregroundApplication = undefined;
export const locked = undefined;
export const displayState = undefined;
export const unlock = outside;
export const applicationEvents = outside;
export const installedApplications = outside;
export const applicationIcon = outside;
export const launchApplication = outside;
export const pasteboard = outside;
export const setPasteboard = outside;
export const simulateLocation = outside;
export const clearSimulatedLocation = outside;
