// Resend adapter, over its HTTP API (no SDK). Only this file knows about Resend: the rest of the
// notification system sees the provider-neutral EmailProvider interface and opaque message ids.
// The API key is sent only in the Authorization header and never appears in results or errors.
import type { EmailMessage, EmailProvider, EmailSendResult } from "../types.ts";

export const RESEND_API_URL = "https://api.resend.com/emails";
const PROVIDER = "resend";

export type ResendProviderOptions = {
  apiKey: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
  apiUrl?: string;
};

function describeError(status: number, body: unknown): string {
  const message =
    body && typeof body === "object" && "message" in body && typeof body.message === "string"
      ? body.message
      : "";
  return `HTTP ${status}${message ? `: ${message}` : ""}`.slice(0, 300);
}

export function createResendProvider(options: ResendProviderOptions): EmailProvider {
  if (!options.apiKey) throw new Error("Resend API key is not configured");
  const doFetch = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const apiUrl = options.apiUrl ?? RESEND_API_URL;
  return {
    name: PROVIDER,
    async send(message: EmailMessage): Promise<EmailSendResult> {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      let response: Response;
      try {
        response = await doFetch(apiUrl, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${options.apiKey}`,
            "Content-Type": "application/json",
            "Idempotency-Key": message.idempotencyKey,
          },
          body: JSON.stringify({
            from: message.from,
            to: [message.to],
            subject: message.subject,
            html: message.html,
            text: message.text,
          }),
          signal: controller.signal,
        });
      } catch (error) {
        const aborted = controller.signal.aborted;
        return {
          ok: false,
          provider: PROVIDER,
          retryable: true,
          error: aborted
            ? `timeout after ${timeoutMs} ms`
            : `network error: ${error instanceof Error ? error.name : "unknown"}`,
        };
      } finally {
        clearTimeout(timer);
      }
      let body: unknown = null;
      try {
        body = await response.json();
      } catch {
        body = null;
      }
      if (response.ok) {
        const id =
          body && typeof body === "object" && "id" in body && typeof body.id === "string"
            ? body.id
            : null;
        return { ok: true, provider: PROVIDER, messageId: id };
      }
      // 408/409 (idempotent request still in flight)/429 and 5xx are transient; other 4xx mean
      // the message itself was rejected and will not succeed on retry.
      const retryable = response.status >= 500 || [408, 409, 429].includes(response.status);
      return {
        ok: false,
        provider: PROVIDER,
        retryable,
        error: describeError(response.status, body),
      };
    },
  };
}
