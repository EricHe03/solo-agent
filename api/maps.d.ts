import type { Placemark } from "./swiplet";

export declare function searchPlaces(
  query: string,
  options?: { signal?: AbortSignal },
): Promise<(Placemark & Required<Pick<Placemark, "coordinate">>)[]>;
