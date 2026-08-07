interface PluginHost {
  log(message: string): void;
  emit(eventName: string, payload: Record<string, unknown>): void;
  storage(command: StorageCommand): void;
}

interface StorageCommand {
  type: "read" | "write";
  key: string;
  namespace: string;
  data?: unknown;
}

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
