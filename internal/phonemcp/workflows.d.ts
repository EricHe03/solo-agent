interface File {
  readonly path: string;
  exists(): boolean;
  text(): string;
  json(): unknown;
  bytes(): Uint8Array;
  write(contents: string | Uint8Array): void;
  remove(): void;
}

interface Folder {
  list(): File[];
  file(path: string): File;
}

type WorkflowColor = "red" | "orange" | "tangerine" | "yellow" | "lime" | "teal" | "cyan" | "blue" | "navy" | "grape"
  | "purple" | "pink" | "grayBlue" | "grayGreen" | "grayBrown";

interface WorkflowIcon {
  color: WorkflowColor;
  // An SF Symbol name.
  symbol: string;
}

// main.js starts with a userscript metadata block, // ==Workflow== to // ==/Workflow==, of @name, @name:<BCP 47 tag>,
// @version, @color, @symbol and @updateURL. The icon is kept there, so writing main.js without the block resets it.
interface Workflow {
  readonly name: string;
  readonly icon: WorkflowIcon;
  setIcon(icon: Partial<WorkflowIcon>): void;
  readonly sourceFiles: Folder;
  readonly dataFiles: Folder;
  // main.js has the globals of a js call, with its own dataFiles in place of workflows, and print goes to phone.logs().
  // run returns its default export through JSON once that settles and no listener or timer is left.
  run(): unknown;
  remove(): void;
}

declare const workflows: {
  list(): Workflow[];
  get(name: string): Workflow | null;
  create(name: string, icon?: Partial<WorkflowIcon>): Workflow;
};
