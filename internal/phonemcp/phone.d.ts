type Point = [x: number, y: number];
type Rect = [x: number, y: number, width: number, height: number];

type Trait = "button" | "link" | "image" | "playsSound" | "keyboardKey" | "staticText" | "summaryElement"
  | "updatesFrequently" | "searchField" | "startsMediaSession" | "adjustable" | "allowsDirectInteraction"
  | "causesPageTurn" | "tabBar" | "header" | "webContent" | "textEntry";

interface Element {
  ref: number;
  role: string;
  // The view's class, only in a raw screen and from phone.find.
  class?: string;
  traits?: Trait[];
  label?: string;
  value?: string;
  identifier?: string;
  placeholder?: string;
  hint?: string;
  url?: string;
  frame?: Rect;
  point?: Point;
  partial?: true;
  offScreen?: true;
  inert?: true;
  remote?: true;
  disabled?: true;
  focused?: true;
  selected?: true;
  expanded?: boolean;
  secure?: true;
  selection?: [location: number, length: number];
  actions?: string[];
  children?: Element[];
  readonly parent?: Element;
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
}

interface Screen {
  app: string;
  root: Element;
  system?: Element;
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
}

interface Result {
  action: string;
  target?: Element;
  warnings?: string[];
}

type TextField = "role" | "class" | "label" | "value" | "identifier" | "placeholder" | "hint" | "url";
type Flag = "disabled" | "focused" | "selected" | "expanded" | "secure" | "partial" | "offScreen" | "inert" | "remote";

type Selector =
  | { ref?: number; traits?: Trait[]; within?: Selector | Element; parent?: Selector | Element; has?: Selector | Element; index?: number }
    & { [field in TextField]?: string | RegExp }
    & { [field in Flag]?: boolean }
  | ((element: Element) => boolean);

type Target = Selector | Element;

type Key = "return" | "backspace" | "forwardDelete" | "tab" | "escape" | "space" | "left" | "right" | "up" | "down"
  | "home" | "end" | "pageUp" | "pageDown" | `f${1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12}`;
type Modifier = "cmd" | "shift" | "ctrl" | "alt";

type Action = "press" | "increment" | "decrement" | "escape" | "menu"
  | "scrollUp" | "scrollDown" | "scrollLeft" | "scrollRight"
  | "scrollToVisible";

interface Phone {
  status(): {
    name: string;
    model: string;
    os: string;
    build: string;
    locked: boolean;
    display: "off" | "dimmed" | "inactiveOn" | "activeOn";
    screen: { width: number; height: number; scale: number; orientation: "portrait" | "portraitUpsideDown" | "landscape" };
    app: string;
    language: string;
  };
  unlock(): Result;

  // fast reads only the process of the app in front: no system or elements of other processes, and marks nothing inert.
  screen(options?: { raw?: boolean; within?: Selector | Element; fast?: boolean }): Screen;
  // Like screen({ raw: true, fast: true }).find, but reads only frame, point and the fields an object selector names;
  // focused is never read.
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
  elementAt(point: Point, options?: { fast?: boolean }): Element | { label: string; identifier: string; value: string; listed: false };

  waitFor<T>(condition: (screen: Screen) => T, options?: { timeoutMs?: number; raw?: boolean; fast?: boolean }): T;
  waitFor<T>(condition: (screen: Screen) => T, options: { timeoutMs: number; raw?: boolean; fast?: boolean; optional: true }): T | null;
  scrollTo(selector: Selector, options?: { direction?: "down" | "up" | "left" | "right"; within?: Selector; pages?: number }): Element;

  tap(target: Target | Point, options?: { count?: number; holdMs?: number }): Result;
  setText(target: Target, text: string): Result;
  perform(target: Target, action: Action | string): Result;
  swipe(from: Point, to: Point, options?: { durationMs?: number }): Result;
  drag(from: Point, to: Point, options?: { durationMs?: number; pressMs?: number }): Result;
  pinch(center: Point, scale: number, options?: { durationMs?: number }): Result;
  touch(fingers: [x: number, y: number, ms: number][][]): Result;
  // A letter goes to the input method in use, which can compose it instead of inserting it.
  pressKey(combo: Key | `${Modifier}+${Key}` | string): Result;

  screenshot(options?: { region?: Rect; scale?: number }): { width: number; height: number; scale: number; region: Rect };
  recognizeText(options?: { region?: Rect; language?: string }): { text: string; frame: Rect; point: Point }[];

  pressHome(): Result;
  openAppSwitcher(): Result;
  pressPower(): Result;
  pressVolumeUp(): Result;
  pressVolumeDown(): Result;

  // name is unlocalized.
  apps(): { name: string; bundleId: string }[];
  launch(bundleId: string, options?: { url?: string; restart?: boolean }): Result;
  clipboard(): string | null;
  setClipboard(text: string | null): void;

  setLocation(latitude: number, longitude: number): Result;
  clearLocation(): Result;

  // app is com.apple.springboard while SpringBoard's screens or alerts are in front. A js call drops its listeners and
  // timers when it ends.
  on(event: "foreground", listener: (event: { app: string; pid: number; time: number }) => void | Promise<void>): { cancel(): void };
}

declare const phone: Phone;

declare function print(...values: unknown[]): void;
declare function sleep(ms: number): Promise<void>;
