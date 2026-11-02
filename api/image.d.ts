import type { CallOptions, Point, Quad, Rect } from "./index";
import type { FileHandle } from "./file-system";

export type Color = `#${string}` | readonly [red: number, green: number, blue: number];
export type ImageFormat = "png" | "jpeg" | "heic";

export interface TemplateMatch {
  readonly frame: Rect;
  readonly center: Point;
  readonly score: number;
  readonly scale: number;
}

export interface TemplateMatchOptions extends CallOptions {
  readonly threshold?: number;
  readonly region?: Rect;
  readonly scales?: readonly number[];
}

export interface ColorCheck {
  readonly point: Point;
  readonly color: Color;
  readonly tolerance?: number;
}

export interface ConnectedComponent {
  readonly frame: Rect;
  readonly pixels: number;
  readonly centroid: Point;
}

export interface ImageStats {
  readonly mean: readonly number[];
  readonly min: readonly number[];
  readonly max: readonly number[];
  readonly deviation: readonly number[];
}

export interface TextRecognitionOptions extends CallOptions {
  readonly region?: Rect;
  readonly languages?: readonly string[];
  readonly detectLanguage?: boolean;
  readonly level?: "fast" | "accurate";
  readonly words?: readonly string[];
  readonly correction?: boolean;
  readonly minimumHeight?: number;
}

export interface RecognizedTextBox {
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

export interface RecognizedTextCandidate {
  readonly text: string;
  readonly confidence: number;
  boundingBox(start: number, end: number): RecognizedTextBox | null;
}

export interface RecognizedTextLine extends RecognizedTextCandidate, RecognizedTextBox {
  readonly candidates: readonly RecognizedTextCandidate[];
}

export interface ImageDifference {
  readonly ratio: number;
  readonly frames: readonly Rect[];
}

export interface DetectedBarcode {
  readonly payload: string | null;
  readonly symbology: string;
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

export interface RasterImage {
  readonly width: number;
  readonly height: number;
  readonly scale: number;
  readonly frame: Rect;
  readonly time: number | null;
  readonly timestamp: number | null;

  crop(rect: Rect): RasterImage;
  resize(scale: number): RasterImage;
  resize(size: { readonly width?: number; readonly height?: number }): RasterImage;
  rotate(degrees: number): RasterImage;
  grayscale(): RasterImage;
  threshold(level?: number | "otsu"): RasterImage;
  mask(color: Color, options?: { readonly tolerance?: number }): RasterImage;
  mask(range: readonly [low: Color, high: Color]): RasterImage;
  invert(): RasterImage;
  dilate(radius?: number): RasterImage;
  erode(radius?: number): RasterImage;

  encode(format?: ImageFormat, options?: CallOptions & { readonly quality?: number }): Promise<Uint8Array>;
  save(file: FileHandle | string, options?: CallOptions & { readonly format?: ImageFormat; readonly quality?: number }): Promise<FileHandle>;
  pixel(point: Point, options?: CallOptions): Promise<[red: number, green: number, blue: number, alpha: number]>;
  stats(options?: CallOptions & { readonly region?: Rect }): Promise<ImageStats>;

  find(template: RasterImage, options?: TemplateMatchOptions): Promise<TemplateMatch | null>;
  findAll(template: RasterImage, options?: TemplateMatchOptions & { readonly limit?: number; readonly overlap?: number }): Promise<TemplateMatch[]>;
  matchColors(checks: readonly ColorCheck[], options?: CallOptions): Promise<boolean[]>;
  components(options?: CallOptions & { readonly minimumPixels?: number }): Promise<ConnectedComponent[]>;
  recognizeText(options?: TextRecognitionOptions): Promise<RecognizedTextLine[]>;
  diff(other: RasterImage, options?: CallOptions & { readonly threshold?: number }): Promise<ImageDifference>;
  distance(other: RasterImage, options?: CallOptions): Promise<number>;
  nearest(candidates: readonly RasterImage[], options?: CallOptions): Promise<{ readonly index: number; readonly distance: number }>;
  detectBarcodes(options?: CallOptions): Promise<DetectedBarcode[]>;
}

export declare function decode(data: Uint8Array | FileHandle | string, options?: CallOptions & { readonly scale?: number }): Promise<RasterImage>;
