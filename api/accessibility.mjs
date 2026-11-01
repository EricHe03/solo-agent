const outside = () => {
  throw new Error("@swipt/api/accessibility runs inside Swipt; build the swiplet with `swipt build`");
};

export const snapshot = outside;
export const find = outside;
export const setText = outside;
export const perform = outside;
