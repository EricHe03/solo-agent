const outside = () => {
  throw new Error("swiplet/input runs inside Swipt; build the swiplet with `swiplet build`");
};

export const tap = outside;
export const swipe = outside;
export const drag = outside;
export const pinch = outside;
export const touch = outside;
export const pressKey = outside;
export const pressHome = outside;
export const openAppSwitcher = outside;
export const pressPower = outside;
export const pressVolumeUp = outside;
export const pressVolumeDown = outside;
