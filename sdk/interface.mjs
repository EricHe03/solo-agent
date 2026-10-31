const outside = () => {
  throw new Error("swiplet/interface runs inside Swipt; build the swiplet with `swiplet build`");
};

export const actions = outside;
export const useService = outside;
