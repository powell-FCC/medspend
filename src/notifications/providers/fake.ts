// Fake email providers for local, integration and Worker-runtime tests. They never contact a
// real email service.
//
//   * FakeEmailProvider: in memory. Records every message and plays back a script of outcomes
//     (success, rejection, retryable failure, timeout).
//   * createSinkEmailProvider: posts each message as JSON to a LOCAL test endpoint (loopback
//     only); the endpoint's reply decides the outcome. Used by the workerd scheduled-handler
//     check, where the test process cannot see Worker memory.
import type { EmailMessage, EmailProvider, EmailSendResult } from "../types.ts";

export type FakeOutcome = "success" | "reject" | "retryable" | "timeout";

export class FakeEmailProvider implements EmailProvider {
  readonly name = "fake";
  readonly sent: EmailMessage[] = [];
  readonly attempts: { message: EmailMessage; outcome: FakeOutcome }[] = [];
  private script: FakeOutcome[];
  private readonly fallback: FakeOutcome;
  private counter = 0;

  constructor(script: FakeOutcome[] = [], fallback: FakeOutcome = "success") {
    this.script = [...script];
    this.fallback = fallback;
  }

  /** Queue outcomes for the next sends (then the fallback applies). */
  queue(...outcomes: FakeOutcome[]): void {
    this.script.push(...outcomes);
  }

  async send(message: EmailMessage): Promise<EmailSendResult> {
    const outcome = this.script.shift() ?? this.fallback;
    this.attempts.push({ message, outcome });
    switch (outcome) {
      case "success":
        this.sent.push(message);
        return { ok: true, provider: this.name, messageId: `fake-${++this.counter}` };
      case "reject":
        return {
          ok: false,
          provider: this.name,
          retryable: false,
          error: "HTTP 422: invalid recipient",
        };
      case "retryable":
        return {
          ok: false,
          provider: this.name,
          retryable: true,
          error: "HTTP 503: provider unavailable",
        };
      case "timeout":
        return { ok: false, provider: this.name, retryable: true, error: "timeout after 10000 ms" };
    }
  }
}

export function isLoopbackUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  } catch {
    return false;
  }
}

export function createSinkEmailProvider(
  endpoint: string,
  doFetch: typeof fetch = fetch,
): EmailProvider {
  if (!isLoopbackUrl(endpoint))
    throw new Error("The fake email endpoint must be a loopback http URL");
  return {
    name: "fake",
    async send(message: EmailMessage): Promise<EmailSendResult> {
      try {
        const response = await doFetch(endpoint, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(message),
        });
        const body = (await response.json().catch(() => ({}))) as {
          outcome?: FakeOutcome;
          id?: string;
        };
        if (response.ok && (body.outcome ?? "success") === "success") {
          return { ok: true, provider: "fake", messageId: body.id ?? null };
        }
        const retryable = body.outcome !== "reject";
        return {
          ok: false,
          provider: "fake",
          retryable,
          error: `fake endpoint: ${body.outcome ?? response.status}`,
        };
      } catch {
        return { ok: false, provider: "fake", retryable: true, error: "fake endpoint unreachable" };
      }
    },
  };
}
