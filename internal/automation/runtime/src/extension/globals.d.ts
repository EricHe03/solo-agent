declare module "swipt:modules" {
  export const modules: Readonly<Record<string, object>>;
}

interface String {
  toWellFormed(): string;
}
