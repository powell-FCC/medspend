import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Button } from "@/components/ui/button";
import {
  getNotificationSettingsFn,
  updateNotificationSettingsFn,
} from "@/lib/notification-settings.functions";
import {
  DIGEST_FREQUENCIES,
  SUPPORTED_TIMEZONES,
  WEEKDAYS,
  digestScheduleSummary,
  formatSendHour,
  timezoneLabel,
  type DigestFrequency,
  type OrganizationNotificationSettings,
} from "@/notifications/settings";

// Phase 6C.3: the organization's approver digest (admins only; staff never reach Settings).
// Admins also get an email for every new request. The master sending switch is shown but not
// editable: it is turned on per organization at rollout.
const notificationSettingsKey = (organizationId: string) => [
  "org",
  organizationId,
  "notification-settings",
];

export function NotificationSettings({ organizationId }: { organizationId: string }) {
  const getSettings = useServerFn(getNotificationSettingsFn);
  const settings = useQuery({
    queryKey: notificationSettingsKey(organizationId),
    queryFn: () => getSettings({ data: { organizationId } }),
  });
  return (
    <section className="rounded-xl border bg-card p-5" data-section="notifications">
      <h2 className="font-medium">Notifications</h2>
      <p className="mt-1 max-w-3xl text-sm text-muted-foreground">
        Admins get an email when a new supply request is submitted, and a digest of requests that
        need action. Staff get one email when their request is approved or denied.
      </p>
      {settings.isLoading && <p className="mt-3 text-sm text-muted-foreground">Loading…</p>}
      {settings.isError && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {settings.error instanceof Error
            ? settings.error.message
            : "Could not load notification settings."}
        </p>
      )}
      {settings.data && (
        <NotificationSettingsForm organizationId={organizationId} settings={settings.data} />
      )}
    </section>
  );
}

export function NotificationSettingsForm({
  organizationId,
  settings,
}: {
  organizationId: string;
  settings: OrganizationNotificationSettings;
}) {
  const queryClient = useQueryClient();
  const save = useServerFn(updateNotificationSettingsFn);
  const [digestEnabled, setDigestEnabled] = useState(settings.digestEnabled);
  const [frequency, setFrequency] = useState<DigestFrequency>(settings.digestFrequency);
  const [hour, setHour] = useState(settings.digestSendHour);
  const [weekday, setWeekday] = useState(settings.digestWeekday);
  const [timezone, setTimezone] = useState(settings.timezone);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    setDigestEnabled(settings.digestEnabled);
    setFrequency(settings.digestFrequency);
    setHour(settings.digestSendHour);
    setWeekday(settings.digestWeekday);
    setTimezone(settings.timezone);
  }, [settings]);
  const changed = () => setSaved(false);
  const zones = SUPPORTED_TIMEZONES.some((zone) => zone.value === timezone)
    ? SUPPORTED_TIMEZONES
    : [{ value: timezone, label: timezoneLabel(timezone) }, ...SUPPORTED_TIMEZONES];

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError("");
    setSaved(false);
    setSaving(true);
    try {
      const next = await save({
        data: {
          organizationId,
          digestEnabled,
          digestFrequency: frequency,
          digestSendHour: hour,
          digestWeekday: weekday,
          timezone,
        },
      });
      queryClient.setQueryData(notificationSettingsKey(organizationId), next);
      setSaved(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save notification settings.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="mt-4 space-y-4" data-testid="notification-settings-form">
      <p className="text-sm" data-testid="notification-sending-status">
        <span className="text-muted-foreground">Email sending: </span>
        {settings.sendingEnabled ? (
          <span className="font-medium">On</span>
        ) : (
          <span className="font-medium">
            Off — notifications are not emailed until sending is turned on for this organization.
          </span>
        )}
      </p>
      <fieldset className="space-y-3">
        <legend className="text-sm font-medium">Approver digest</legend>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={digestEnabled}
            onChange={(event) => {
              setDigestEnabled(event.target.checked);
              changed();
            }}
          />
          Digest emails
        </label>
        <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-4">
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">Frequency</span>
            <select
              className="rounded-md border bg-background px-3 py-2 text-sm"
              value={frequency}
              disabled={!digestEnabled}
              onChange={(event) => {
                setFrequency(event.target.value as DigestFrequency);
                changed();
              }}
            >
              {DIGEST_FREQUENCIES.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          {frequency === "weekly" && (
            <label className="grid gap-1 text-sm">
              <span className="text-muted-foreground">Day</span>
              <select
                className="rounded-md border bg-background px-3 py-2 text-sm"
                value={weekday}
                disabled={!digestEnabled}
                onChange={(event) => {
                  setWeekday(Number(event.target.value));
                  changed();
                }}
              >
                {WEEKDAYS.map((day) => (
                  <option key={day.value} value={day.value}>
                    {day.label}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">Send time</span>
            <select
              className="rounded-md border bg-background px-3 py-2 text-sm"
              value={hour}
              disabled={!digestEnabled}
              onChange={(event) => {
                setHour(Number(event.target.value));
                changed();
              }}
            >
              {Array.from({ length: 24 }, (_, value) => (
                <option key={value} value={value}>
                  {formatSendHour(value)}
                </option>
              ))}
            </select>
          </label>
          <label className="grid gap-1 text-sm">
            <span className="text-muted-foreground">Time zone</span>
            <select
              className="rounded-md border bg-background px-3 py-2 text-sm"
              value={timezone}
              onChange={(event) => {
                setTimezone(event.target.value);
                changed();
              }}
            >
              {zones.map((zone) => (
                <option key={zone.value} value={zone.value}>
                  {zone.label}
                </option>
              ))}
            </select>
          </label>
        </div>
        <p className="text-xs text-muted-foreground" data-testid="notification-digest-summary">
          {digestScheduleSummary({
            digestEnabled,
            digestFrequency: frequency,
            digestSendHour: hour,
            digestWeekday: weekday,
            timezone,
          })}
          {digestEnabled ? ". Sent only when requests need action." : ""}
        </p>
      </fieldset>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="flex items-center gap-3">
        <Button type="submit" size="sm" disabled={saving}>
          {saving ? "Saving…" : "Save notification settings"}
        </Button>
        {saved && <span className="text-sm text-muted-foreground">Saved</span>}
      </div>
    </form>
  );
}
