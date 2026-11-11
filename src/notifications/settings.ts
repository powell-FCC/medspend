// Phase 6C.3 organization notification settings: shared by the Settings UI and the server
// functions (client-safe; no server imports).

export type DigestFrequency = "daily" | "weekdays" | "weekly";

export type OrganizationNotificationSettings = {
  organizationId: string;
  /** Master safety switch. Read-only in the app; enabled per organization at rollout. */
  sendingEnabled: boolean;
  digestEnabled: boolean;
  digestFrequency: DigestFrequency;
  /** Local hour, 0–23 (whole hours only). */
  digestSendHour: number;
  /** ISO weekday for Weekly: 1 = Monday … 7 = Sunday. */
  digestWeekday: number;
  timezone: string;
  orderedReceiptThresholdDays: number;
  updatedAt: string | null;
};

export type DigestSettingsInput = {
  digestEnabled: boolean;
  digestFrequency: DigestFrequency;
  digestSendHour: number;
  digestWeekday: number;
  timezone: string;
};

export const DEFAULT_NOTIFICATION_SETTINGS: Omit<
  OrganizationNotificationSettings,
  "organizationId" | "updatedAt"
> = {
  sendingEnabled: false,
  digestEnabled: true,
  digestFrequency: "daily",
  digestSendHour: 8,
  digestWeekday: 1,
  timezone: "America/New_York",
  orderedReceiptThresholdDays: 7,
};

export const DIGEST_FREQUENCIES: { value: DigestFrequency; label: string }[] = [
  { value: "daily", label: "Daily" },
  { value: "weekdays", label: "Weekdays only" },
  { value: "weekly", label: "Weekly" },
];

export const WEEKDAYS: { value: number; label: string }[] = [
  { value: 1, label: "Monday" },
  { value: 2, label: "Tuesday" },
  { value: 3, label: "Wednesday" },
  { value: 4, label: "Thursday" },
  { value: 5, label: "Friday" },
  { value: 6, label: "Saturday" },
  { value: 7, label: "Sunday" },
];

/** The explicit list of time zones an admin can choose. The database also checks the name. */
export const SUPPORTED_TIMEZONES: { value: string; label: string }[] = [
  { value: "America/New_York", label: "Eastern Time (New York)" },
  { value: "America/Chicago", label: "Central Time (Chicago)" },
  { value: "America/Denver", label: "Mountain Time (Denver)" },
  { value: "America/Phoenix", label: "Mountain Time, no DST (Phoenix)" },
  { value: "America/Los_Angeles", label: "Pacific Time (Los Angeles)" },
  { value: "America/Anchorage", label: "Alaska Time (Anchorage)" },
  { value: "Pacific/Honolulu", label: "Hawaii Time (Honolulu)" },
  { value: "America/Puerto_Rico", label: "Atlantic Time (Puerto Rico)" },
  { value: "America/Toronto", label: "Eastern Time (Toronto)" },
  { value: "America/Vancouver", label: "Pacific Time (Vancouver)" },
  { value: "America/Mexico_City", label: "Central Time (Mexico City)" },
  { value: "Europe/London", label: "United Kingdom (London)" },
  { value: "Europe/Dublin", label: "Ireland (Dublin)" },
  { value: "Europe/Paris", label: "Central Europe (Paris)" },
  { value: "Europe/Berlin", label: "Central Europe (Berlin)" },
  { value: "Australia/Sydney", label: "Australia Eastern (Sydney)" },
  { value: "Pacific/Auckland", label: "New Zealand (Auckland)" },
  { value: "UTC", label: "Coordinated Universal Time (UTC)" },
];

export const SUPPORTED_TIMEZONE_VALUES = SUPPORTED_TIMEZONES.map((zone) => zone.value) as [
  string,
  ...string[],
];

export function isSupportedTimezone(value: string): boolean {
  return SUPPORTED_TIMEZONE_VALUES.includes(value);
}

export function formatSendHour(hour: number): string {
  const suffix = hour < 12 ? "AM" : "PM";
  const twelve = hour % 12 === 0 ? 12 : hour % 12;
  return `${twelve}:00 ${suffix}`;
}

export function timezoneLabel(value: string): string {
  return SUPPORTED_TIMEZONES.find((zone) => zone.value === value)?.label ?? value;
}

export function digestScheduleSummary(
  settings: Pick<
    OrganizationNotificationSettings,
    "digestEnabled" | "digestFrequency" | "digestSendHour" | "digestWeekday" | "timezone"
  >,
): string {
  if (!settings.digestEnabled) return "Off";
  const time = `${formatSendHour(settings.digestSendHour)} ${timezoneLabel(settings.timezone)}`;
  if (settings.digestFrequency === "weekly") {
    const day =
      WEEKDAYS.find((weekday) => weekday.value === settings.digestWeekday)?.label ?? "Monday";
    return `Weekly on ${day} at ${time}`;
  }
  if (settings.digestFrequency === "weekdays") return `Weekdays (Monday–Friday) at ${time}`;
  return `Daily at ${time}`;
}

export function parseNotificationSettings(value: unknown): OrganizationNotificationSettings {
  const row = (value ?? {}) as Record<string, unknown>;
  const frequency = row.digestFrequency;
  return {
    organizationId: String(row.organizationId ?? ""),
    sendingEnabled: row.sendingEnabled === true,
    digestEnabled: row.digestEnabled !== false,
    digestFrequency: frequency === "weekdays" || frequency === "weekly" ? frequency : "daily",
    digestSendHour: Number.isInteger(row.digestSendHour) ? Number(row.digestSendHour) : 8,
    digestWeekday: Number.isInteger(row.digestWeekday) ? Number(row.digestWeekday) : 1,
    timezone: typeof row.timezone === "string" && row.timezone ? row.timezone : "America/New_York",
    orderedReceiptThresholdDays: Number.isInteger(row.orderedReceiptThresholdDays)
      ? Number(row.orderedReceiptThresholdDays)
      : 7,
    updatedAt: typeof row.updatedAt === "string" ? row.updatedAt : null,
  };
}
