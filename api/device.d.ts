import type { CallOptions, ObservableState } from "./index";
import type { FileHandle } from "./file-system";

export type DisplayState = "off" | "dimmed" | "inactiveOn" | "activeOn";

export interface DeviceInfo {
  readonly name: string;
  readonly model: string;
  readonly os: string;
  readonly build: string;
  readonly language: string;
  readonly screen: {
    readonly width: number;
    readonly height: number;
    readonly scale: number;
    readonly orientation: "portrait" | "portraitUpsideDown" | "landscape";
  };
}

export interface InstalledApplication {
  readonly bundleId: string;
  readonly name: string;
  readonly version?: string;
  readonly build?: string;
}

export interface ApplicationStateEvent {
  readonly type: "launch" | "foreground" | "background";
  readonly bundleId: string;
  readonly pid: number;
  readonly time: number;
}

export declare function info(options?: CallOptions): Promise<DeviceInfo>;
export declare const foregroundApplication: ObservableState<string>;
export declare const locked: ObservableState<boolean>;
export declare const displayState: ObservableState<DisplayState>;
export declare function unlock(options?: CallOptions): Promise<void>;

export declare function applicationEvents(options?: CallOptions): AsyncIterable<ApplicationStateEvent>;
export declare function installedApplications(options?: CallOptions): Promise<InstalledApplication[]>;
export declare function applicationIcon(bundleId: string, options?: CallOptions): Promise<FileHandle>;
export declare function launchApplication(bundleId: string, options?: CallOptions & { url?: string; restart?: boolean }): Promise<void>;

export declare function pasteboard(options?: CallOptions): Promise<string | null>;
export declare function setPasteboard(text: string | null, options?: CallOptions): Promise<void>;

export declare function simulateLocation(latitude: number, longitude: number, options?: CallOptions): Promise<void>;
export declare function clearSimulatedLocation(options?: CallOptions): Promise<void>;
