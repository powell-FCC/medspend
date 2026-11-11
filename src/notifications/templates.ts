// Phase 6C.3 email templates. Rendered at delivery time from the context that
// claim_notification_deliveries returns (current request state). Every dynamic value is
// HTML-escaped; every email has a plain-text part. Internal notes are never part of any
// context, so no template can show one.
import type {
  ClaimedDelivery,
  DigestNotificationContext,
  DigestSectionKey,
  RequestItemSummary,
  RequestNotificationContext,
} from "./types.ts";

export const NOTIFICATION_SENDER = "SportSpend <notifications@notify.sport-spend.com>";
export const DEFAULT_APP_BASE_URL = "https://app.sport-spend.com";

export type RenderedEmail = { subject: string; html: string; text: string };

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Single-line text for subjects and plain-text bodies: no control characters, bounded. */
function oneLine(value: unknown, max = 120): string {
  const text = String(value ?? "")
    .split("")
    .map((char) => (char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127 ? " " : char))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function link(appBaseUrl: string, path: string): string {
  return `${appBaseUrl.replace(/\/+$/, "")}${path}`;
}

export function formatDateTime(iso: string | null | undefined, timeZone: string): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  try {
    return new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZone,
      timeZoneName: "short",
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

export function formatAge(iso: string | null | undefined, now: Date): string {
  if (!iso) return "";
  const ms = now.getTime() - new Date(iso).getTime();
  if (!Number.isFinite(ms) || ms < 0) return "just now";
  const hours = Math.floor(ms / 3_600_000);
  if (hours < 1) return "under an hour";
  if (hours < 48) return `${hours} hour${hours === 1 ? "" : "s"}`;
  const days = Math.floor(hours / 24);
  return `${days} days`;
}

function itemLines(summary: RequestItemSummary): string[] {
  const lines = summary.items.map((item) => {
    const quantity =
      item.quantity == null ? "" : `${item.quantity}${item.unit ? ` ${item.unit}` : ""} × `;
    return `${quantity}${oneLine(item.label, 200)}`;
  });
  const more = summary.itemCount - summary.items.length;
  if (more > 0) lines.push(`and ${more} more item${more === 1 ? "" : "s"}`);
  return lines;
}

function itemSummary(summary: RequestItemSummary): string {
  if (summary.itemCount === 0 || summary.items.length === 0) return "Supply request";
  const first = oneLine(summary.items[0].label, 60);
  const more = summary.itemCount - 1;
  return more > 0 ? `${first} and ${more} more` : first;
}

function layout(title: string, bodyHtml: string, footerHtml: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(title)}</title></head>
<body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2933;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:8px;padding:24px;">
<tr><td style="font-size:13px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:#52606d;padding-bottom:12px;">SportSpend</td></tr>
<tr><td style="font-size:15px;line-height:1.5;">${bodyHtml}</td></tr>
<tr><td style="font-size:12px;line-height:1.5;color:#7b8794;padding-top:20px;border-top:1px solid #e4e7eb;">${footerHtml}</td></tr>
</table></td></tr></table></body></html>`;
}

function button(href: string, label: string): string {
  return `<p style="margin:20px 0 0;"><a href="${escapeHtml(href)}" style="display:inline-block;background:#1f2933;color:#ffffff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:600;">${escapeHtml(label)}</a></p>`;
}

function itemListHtml(summary: RequestItemSummary): string {
  const lines = itemLines(summary);
  if (lines.length === 0) return "";
  return `<ul style="margin:8px 0 0;padding-left:20px;">${lines.map((line) => `<li>${escapeHtml(line)}</li>`).join("")}</ul>`;
}

function greeting(name: string | null): string {
  const clean = oneLine(name, 80);
  return clean ? `Hi ${clean},` : "Hi,";
}

function renderSubmitted(
  context: RequestNotificationContext,
  appBaseUrl: string,
  timeZone: string,
): RenderedEmail {
  const requester = oneLine(context.requesterName, 80) || "A team member";
  const href = link(
    appBaseUrl,
    `/supply-requests?request=${encodeURIComponent(context.requestId)}`,
  );
  const submitted = formatDateTime(context.submittedAt, timeZone);
  const note = context.requestNote ? oneLine(context.requestNote, 1000) : "";
  const subject = `New supply request from ${requester}`;
  const html = layout(
    subject,
    `<p style="margin:0 0 12px;">${escapeHtml(greeting(context.recipientName))}</p>
<p style="margin:0 0 12px;"><strong>${escapeHtml(requester)}</strong> submitted a supply request (${escapeHtml(context.reference)})${submitted ? ` on ${escapeHtml(submitted)}` : ""}.</p>
<p style="margin:0;font-weight:600;">Items</p>${itemListHtml(context.items)}
${note ? `<p style="margin:12px 0 0;"><span style="font-weight:600;">Note:</span> ${escapeHtml(note)}</p>` : ""}
${button(href, "Review request")}`,
    `You receive this because you are an admin${context.organizationName ? ` of ${escapeHtml(oneLine(context.organizationName, 120))}` : ""} in SportSpend.`,
  );
  const text = [
    greeting(context.recipientName),
    "",
    `${requester} submitted a supply request (${context.reference})${submitted ? ` on ${submitted}` : ""}.`,
    "",
    "Items:",
    ...itemLines(context.items).map((line) => `- ${line}`),
    ...(note ? ["", `Note: ${note}`] : []),
    "",
    `Review request: ${href}`,
    "",
    `You receive this because you are an admin${context.organizationName ? ` of ${oneLine(context.organizationName, 120)}` : ""} in SportSpend.`,
  ].join("\n");
  return { subject, html, text };
}

function renderOutcome(
  context: RequestNotificationContext,
  approved: boolean,
  appBaseUrl: string,
): RenderedEmail {
  const href = link(appBaseUrl, `/staff/requests/${encodeURIComponent(context.requestId)}`);
  const summary = itemSummary(context.items);
  const note = !approved && context.staffVisibleNote ? oneLine(context.staffVisibleNote, 2000) : "";
  const subject = approved ? "Your supply request was approved" : "Your supply request was denied";
  const lead = approved
    ? "Your supply request has been approved and is being processed."
    : "Your supply request has been denied.";
  const html = layout(
    subject,
    `<p style="margin:0 0 12px;">${escapeHtml(greeting(context.recipientName))}</p>
<p style="margin:0 0 12px;">${escapeHtml(lead)}</p>
<p style="margin:0;color:#52606d;">Request ${escapeHtml(context.reference)}: ${escapeHtml(summary)}</p>
${note ? `<p style="margin:12px 0 0;"><span style="font-weight:600;">Reason:</span> ${escapeHtml(note)}</p>` : ""}
${button(href, "View request")}`,
    "You receive this because you submitted this request in SportSpend.",
  );
  const text = [
    greeting(context.recipientName),
    "",
    lead,
    "",
    `Request ${context.reference}: ${summary}`,
    ...(note ? ["", `Reason: ${note}`] : []),
    "",
    `View request: ${href}`,
    "",
    "You receive this because you submitted this request in SportSpend.",
  ].join("\n");
  return { subject, html, text };
}

const DIGEST_SECTIONS: { key: DigestSectionKey; title: string; queue: string }[] = [
  { key: "awaitingReview", title: "Awaiting review", queue: "needsReview" },
  { key: "underReview", title: "Under review", queue: "needsReview" },
  { key: "approvedNotOrdered", title: "Approved, not yet ordered", queue: "awaitingOrder" },
  { key: "orderedNotReceived", title: "Ordered, not yet received", queue: "awaitingDelivery" },
];

function renderDigest(
  context: DigestNotificationContext,
  appBaseUrl: string,
  now: Date,
): RenderedEmail {
  const total = context.digest.totalCount;
  const subject = `${total} supply request${total === 1 ? "" : "s"} need${total === 1 ? "s" : ""} attention`;
  const sections = DIGEST_SECTIONS.map((section) => ({
    ...section,
    data: context.digest.sections[section.key],
  })).filter((section) => section.data && section.data.count > 0);
  const settingsHref = link(appBaseUrl, "/settings");
  const htmlSections = sections
    .map((section) => {
      const href = link(appBaseUrl, `/supply-requests?queue=${section.queue}`);
      const title =
        section.key === "orderedNotReceived"
          ? `${section.title} after ${context.digest.thresholdDays} days`
          : section.title;
      const rows = section.data.items
        .map(
          (item) =>
            `<li>${escapeHtml(item.reference)} · ${escapeHtml(oneLine(item.requesterName, 80))} · ${escapeHtml(itemSummary(item.items))} <span style="color:#7b8794;">(${escapeHtml(formatAge(item.since, now))})</span></li>`,
        )
        .join("");
      const more = section.data.count - section.data.items.length;
      return `<h2 style="font-size:15px;margin:20px 0 4px;">${escapeHtml(title)}: ${section.data.count}</h2>
<p style="margin:0;color:#52606d;font-size:13px;">Oldest: ${escapeHtml(formatAge(section.data.oldestAt, now))}</p>
<ul style="margin:8px 0 0;padding-left:20px;">${rows}</ul>
${more > 0 ? `<p style="margin:4px 0 0;font-size:13px;color:#52606d;">and ${more} more</p>` : ""}
<p style="margin:6px 0 0;font-size:13px;"><a href="${escapeHtml(href)}">Open ${escapeHtml(section.title.toLowerCase())}</a></p>`;
    })
    .join("");
  const html = layout(
    subject,
    `<p style="margin:0 0 12px;">${escapeHtml(greeting(context.recipientName))}</p>
<p style="margin:0;">Here are the supply requests that need action${context.organizationName ? ` at ${escapeHtml(oneLine(context.organizationName, 120))}` : ""}.</p>
${htmlSections}
${button(link(appBaseUrl, "/supply-requests"), "Open request inbox")}`,
    `You receive this digest because you are an admin in SportSpend. <a href="${escapeHtml(settingsHref)}">Change digest settings</a>.`,
  );
  const text = [
    greeting(context.recipientName),
    "",
    `Here are the supply requests that need action${context.organizationName ? ` at ${oneLine(context.organizationName, 120)}` : ""}.`,
    ...sections.flatMap((section) => {
      const title =
        section.key === "orderedNotReceived"
          ? `${section.title} after ${context.digest.thresholdDays} days`
          : section.title;
      const more = section.data.count - section.data.items.length;
      return [
        "",
        `${title}: ${section.data.count} (oldest ${formatAge(section.data.oldestAt, now)})`,
        ...section.data.items.map(
          (item) =>
            `- ${item.reference} · ${oneLine(item.requesterName, 80)} · ${itemSummary(item.items)} (${formatAge(item.since, now)})`,
        ),
        ...(more > 0 ? [`- and ${more} more`] : []),
        `  ${link(appBaseUrl, `/supply-requests?queue=${section.queue}`)}`,
      ];
    }),
    "",
    `Open request inbox: ${link(appBaseUrl, "/supply-requests")}`,
    "",
    `You receive this digest because you are an admin in SportSpend. Change digest settings: ${settingsHref}`,
  ].join("\n");
  return { subject, html, text };
}

export function renderNotificationEmail(
  delivery: Pick<ClaimedDelivery, "eventType" | "context">,
  options: { appBaseUrl?: string; now?: Date } = {},
): RenderedEmail {
  const appBaseUrl = options.appBaseUrl ?? DEFAULT_APP_BASE_URL;
  const now = options.now ?? new Date();
  const timeZone = (delivery.context as { timezone?: string }).timezone || "America/New_York";
  switch (delivery.eventType) {
    case "request_submitted":
      return renderSubmitted(delivery.context as RequestNotificationContext, appBaseUrl, timeZone);
    case "request_approved":
      return renderOutcome(delivery.context as RequestNotificationContext, true, appBaseUrl);
    case "request_denied":
      return renderOutcome(delivery.context as RequestNotificationContext, false, appBaseUrl);
    case "approver_digest":
      return renderDigest(delivery.context as DigestNotificationContext, appBaseUrl, now);
    default:
      throw new Error(`Unknown notification event type: ${String(delivery.eventType)}`);
  }
}
