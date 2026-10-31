const outside = () => {
  throw new Error("swiplet/image runs inside Swipt; build the swiplet with `swiplet build`");
};

export const decode = outside;
