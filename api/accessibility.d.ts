import type { CallOptions, Point, Rect } from "./index";
import type { TapOptions } from "./input";

export type AccessibilityTrait = "button" | "link" | "image" | "playsSound" | "keyboardKey" | "staticText" | "summaryElement"
  | "updatesFrequently" | "searchField" | "startsMediaSession" | "adjustable" | "allowsDirectInteraction"
  | "causesPageTurn" | "tabBar" | "header" | "webContent" | "textEntry";

export type AccessibilityAction = "press" | "increment" | "decrement" | "escape" | "menu"
  | "scrollUp" | "scrollDown" | "scrollLeft" | "scrollRight" | "scrollToVisible";

export interface AccessibilityElement {
  readonly role: string;
  readonly class?: string;
  readonly traits: readonly AccessibilityTrait[];
  readonly label?: string;
  readonly value?: string;
  readonly identifier?: string;
  readonly placeholder?: string;
  readonly hint?: string;
  readonly url?: string;
  readonly frame?: Rect;
  readonly point?: Point;
  readonly partial?: true;
  readonly offScreen?: true;
  readonly inert?: true;
  readonly remote?: true;
  readonly disabled?: true;
  readonly focused?: true;
  readonly selected?: true;
  readonly expanded?: boolean;
  readonly secure?: true;
  readonly selection?: [location: number, length: number];
  readonly actions?: readonly string[];
  readonly children: readonly AccessibilityElement[];
  readonly parent?: AccessibilityElement;
  find(selector: AccessibilitySelector): AccessibilityElement | null;
  findAll(selector: AccessibilitySelector): AccessibilityElement[];
}

export interface AccessibilitySnapshot {
  readonly app: string;
  readonly time: number;
  readonly root: AccessibilityElement;
  readonly system?: AccessibilityElement;
  find(selector: AccessibilitySelector): AccessibilityElement | null;
  findAll(selector: AccessibilitySelector): AccessibilityElement[];
}

type TextField = "role" | "class" | "label" | "value" | "identifier" | "placeholder" | "hint" | "url" | "app";
type Flag = "disabled" | "focused" | "selected" | "expanded" | "secure" | "partial" | "offScreen" | "inert" | "remote";

export type AccessibilityQuery = { traits?: AccessibilityTrait[]; within?: AccessibilityQuery; parent?: AccessibilityQuery; has?: AccessibilityQuery; not?: AccessibilityQuery; index?: number }
  & { [field in TextField]?: string | RegExp }
  & { [field in Flag]?: boolean };

export type AccessibilitySelector =
  | ({ traits?: AccessibilityTrait[]; within?: AccessibilitySelector | AccessibilityElement; parent?: AccessibilitySelector | AccessibilityElement; has?: AccessibilitySelector | AccessibilityElement; not?: AccessibilitySelector | AccessibilityElement; index?: number }
    & { [field in TextField]?: string | RegExp }
    & { [field in Flag]?: boolean })
  | ((element: AccessibilityElement) => boolean);

export interface SnapshotOptions extends CallOptions {
  readonly scope?: "screen" | "frontApp";
  readonly full?: boolean;
}

export interface LocatorOptions extends CallOptions {
  /** 10000 when omitted; Infinity waits without a limit. */
  readonly timeoutMs?: number;
}

export interface AccessibilityLocator {
  tap(options?: LocatorOptions & TapOptions): Promise<void>;
  /** Taps each element as it comes to match, once while it stays matched, and resolves when the app in front at the call leaves the front, at once if the query names only other apps. */
  tapEach(options?: TapOptions): Promise<void>;
  setText(text: string, options?: LocatorOptions): Promise<void>;
  perform(action: AccessibilityAction | (string & {}), options?: LocatorOptions): Promise<void>;
}

export declare function locator(query: AccessibilityQuery | readonly AccessibilityQuery[]): AccessibilityLocator;
export declare function snapshot(options?: SnapshotOptions): Promise<AccessibilitySnapshot>;
export declare function find(selector: AccessibilitySelector, options?: CallOptions): Promise<AccessibilityElement | null>;
export declare function tap(element: AccessibilityElement, options?: TapOptions): Promise<void>;
