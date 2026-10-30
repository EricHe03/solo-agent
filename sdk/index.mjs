const outside = () => {
  throw new Error("swiplet runs inside Swipt; build the swiplet with `swiplet build`");
};

export const useExtension = outside;
export const dataDirectory = undefined;
