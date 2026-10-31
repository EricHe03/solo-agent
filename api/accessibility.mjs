const outside = () => {
  throw new Error("@swipt/api/accessibility runs inside Swipt; build the swiplet with `swiplet build`");
};

export const locator = outside;
export const snapshot = outside;
export const find = outside;
export const tap = outside;
