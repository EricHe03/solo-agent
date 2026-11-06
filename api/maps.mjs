const outside = () => {
  throw new Error(
    "@swipt/api/maps runs inside Swipt; build the swiplet with `swipt project build`",
  );
};

export const searchPlaces = outside;
