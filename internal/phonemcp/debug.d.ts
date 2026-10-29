type Push =
  | { time: number; kind: "app"; app: string; pid: number; state: string }
  | { time: number; kind: "notification"; notification: string; pid?: number }
  | { time: number; kind: "tree"; nodes: { pid: number; label?: string; identifier?: string; value?: string }[] };

interface Phone {
  // A tree push comes 0.75 s after the screen changes, with what changed meanwhile. A js call or workflow stops the
  // recordings it leaves when it ends.
  record(): { stop(): Push[] };

  // The server's log, not the device's; what a workflow prints and how it fails carry the tag workflow/<name>.
  logs(options?: { since?: number; level?: "debug" | "info" | "warn" | "error" }): { time: number; level: string; tag?: string; message: string }[];
}
