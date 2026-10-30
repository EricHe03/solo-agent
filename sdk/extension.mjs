const outside = () => {
  throw new Error("swiplet/extension runs inside Swipt; build the swiplet with `swiplet build`");
};

export const defineExtension = outside;
export const action = outside;
export const sleep = outside;
export const device = undefined;
export const ui = undefined;
export const graphics = undefined;
export const dataDirectory = undefined;
