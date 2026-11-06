const outside = () => {
  throw new Error(
    "@swipt/api/localization runs inside Swipt; build the swiplet with `swipt project build`",
  );
};

export const preferredLocalizations = outside;
