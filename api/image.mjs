const outside = () => {
  throw new Error("@swipt/api/image runs inside Swipt; build the swiplet with `swiplet build`");
};

export const decode = outside;
