interface PluginHost {
  log(message: string): void;
  emit(eventName: string, payload: Record<string, unknown>): void;
  storage(command: StorageCommand | StorageCommandV2): void;
  /** 2 when the host supports correlated storageResult events. */
  readonly storageVersion?: number;
}

interface StorageCommand {
  type: "read" | "write";
  key: string;
  namespace: string;
  data?: unknown;
}

interface StorageCommandV2 {
  type: "read" | "write";
  key: string;
  data?: unknown;
  version: 2;
  /** Nonnegative safe integer, increasing within a plugin generation. */
  requestId: number;
}

type StorageErrorCode =
  | "invalid_command"
  | "capacity"
  | "quarantined"
  | "maintenance"
  | "timeout"
  | "write_indeterminate"
  | "storage_error";

type StorageResult =
  | {
      requestId: number;
      operation: "read" | "write";
      generation: number;
      ok: true;
      value?: unknown;
    }
  | {
      requestId: number;
      operation: "read" | "write" | null;
      generation: number;
      ok: false;
      error: { code: StorageErrorCode; message: string };
    };

interface PluginEvent {
  name: string;
  payload: Record<string, unknown>;
}

interface HttpRequest {
  requestId: string;
  endpoint: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
  query: Record<string, string>;
}

interface HttpResponse {
  requestId?: string;
  status: number;
  headers: Record<string, string>;
  body: string;
}

interface PluginInstance {
  id: string;
  version: string;
  onLoad(settings: Record<string, unknown>): void;
  onUnload(): void;
  onEvent(event: PluginEvent): void;
  __httpRequestHandler(request: HttpRequest): HttpResponse | Promise<HttpResponse>;
}
