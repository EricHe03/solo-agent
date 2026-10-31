const outside = () => {
  throw new Error("@swipt/api/image runs inside Swipt; build the swiplet with `swipt build`");
};

export const decode = outside;
