const outside = () => {
  throw new Error("swiplet/extension runs inside Swipt; build the swiplet with `swiplet build`");
};

export const defineExtension = outside;
export const defineAction = outside;
export const sleep = outside;
