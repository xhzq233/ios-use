export interface RequestFrame {
  c: string;
  args?: Record<string, unknown>;
}

export interface ResponseFrame {
  ok: boolean;
  error?: string;
  data?: unknown;
}
