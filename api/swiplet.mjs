const outside = () => {
  throw new Error(
    "@swipt/api/swiplet runs inside Swipt; build the swiplet with `swipt project build`",
  );
};

export const defineExtension = outside;
export const defineAction = outside;
export const actions = outside;
export const useService = outside;
export const exit = outside;
export const preferredLocalizations = outside;
