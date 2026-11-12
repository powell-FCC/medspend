import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Button } from "@/components/ui/button";
import {
  getRequestWorkflowSettingsFn,
  updateRequestWorkflowSettingsFn,
} from "@/lib/request-workflow-settings.functions";
import {
  REQUEST_WORKFLOW_PROFILE_OPTIONS,
  type OrganizationRequestWorkflowSettings,
  type RequestWorkflowProfile,
} from "@/supply-requests/workflow-profiles";

// Phase 7C.0: the organization's request workflow profile (admins only; staff never reach
// Settings). It changes which request actions are offered from now on. Requests already in
// progress keep their status, and any queue that still holds requests stays visible.
const requestWorkflowSettingsKey = (organizationId: string) => [
  "org",
  organizationId,
  "request-workflow-settings",
];

export function RequestWorkflowSettings({ organizationId }: { organizationId: string }) {
  const getSettings = useServerFn(getRequestWorkflowSettingsFn);
  const settings = useQuery({
    queryKey: requestWorkflowSettingsKey(organizationId),
    queryFn: () => getSettings({ data: { organizationId } }),
  });
  return (
    <section className="rounded-xl border bg-card p-5" data-section="request-workflow">
      <h2 className="font-medium">Request Workflow</h2>
      <p className="mt-1 max-w-3xl text-sm text-muted-foreground">
        Choose how many steps admins take to move a supply request from review to completion. Every
        step is still recorded in the request history.
      </p>
      {settings.isLoading && <p className="mt-3 text-sm text-muted-foreground">Loading…</p>}
      {settings.isError && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {settings.error instanceof Error
            ? settings.error.message
            : "Could not load request workflow settings."}
        </p>
      )}
      {settings.data && (
        <RequestWorkflowSettingsForm organizationId={organizationId} settings={settings.data} />
      )}
    </section>
  );
}

export function RequestWorkflowSettingsForm({
  organizationId,
  settings,
}: {
  organizationId: string;
  settings: OrganizationRequestWorkflowSettings;
}) {
  const queryClient = useQueryClient();
  const save = useServerFn(updateRequestWorkflowSettingsFn);
  const [profile, setProfile] = useState<RequestWorkflowProfile>(settings.workflowProfile);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  useEffect(() => setProfile(settings.workflowProfile), [settings]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError("");
    setSaved(false);
    setSaving(true);
    try {
      const next = await save({ data: { organizationId, workflowProfile: profile } });
      queryClient.setQueryData(requestWorkflowSettingsKey(organizationId), next);
      // The request inbox, dashboard and staff screens follow the new profile.
      await queryClient.invalidateQueries({ queryKey: ["org", organizationId, "requests"] });
      setSaved(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save the request workflow.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="mt-4 space-y-4" data-testid="request-workflow-form">
      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Workflow profile</legend>
        {REQUEST_WORKFLOW_PROFILE_OPTIONS.map((option) => (
          <label
            key={option.value}
            className="flex cursor-pointer items-start gap-3 rounded-lg border p-3 text-sm has-[:checked]:border-foreground"
          >
            <input
              type="radio"
              name="request-workflow-profile"
              value={option.value}
              checked={profile === option.value}
              className="mt-1"
              onChange={() => {
                setProfile(option.value);
                setSaved(false);
              }}
            />
            <span className="grid gap-0.5">
              <span className="font-medium">{option.label}</span>
              <span className="text-muted-foreground">{option.description}</span>
              <span className="text-xs text-muted-foreground">{option.stages}</span>
            </span>
          </label>
        ))}
      </fieldset>
      <p className="text-xs text-muted-foreground">
        Changing the profile affects actions from now on. Requests already in progress keep their
        status and can still be moved forward.
      </p>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="flex items-center gap-3">
        <Button type="submit" size="sm" disabled={saving || profile === settings.workflowProfile}>
          {saving ? "Saving…" : "Save request workflow"}
        </Button>
        {saved && <span className="text-sm text-muted-foreground">Saved</span>}
      </div>
    </form>
  );
}
