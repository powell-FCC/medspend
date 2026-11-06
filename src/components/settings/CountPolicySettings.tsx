import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { setCountPolicyFn } from "@/lib/inventory.functions";
import { getCountPolicyFn } from "@/lib/inventory-workspace.functions";
import {
  COUNT_CADENCE_EXPLAINER,
  SUGGESTED_INTERVALS,
  cadenceLabel,
  formatCadenceDate,
  parseIntervalDays,
} from "@/inventory/count-cadence";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { CountPolicy } from "@/types/inventory-workspace";

// Phase 7B.5: the organization's optional physical count cadence. Owners change it; admins
// see it. Staff never reach Settings.
export function CountPolicySettings({
  organizationId,
  canManage,
}: {
  organizationId: string;
  canManage: boolean;
}) {
  const getPolicy = useServerFn(getCountPolicyFn);
  const policy = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "count-policy"],
    queryFn: () => getPolicy({ data: { organizationId } }),
  });
  return (
    <section className="rounded-xl border bg-card p-5" data-section="count-cadence">
      <h2 className="font-medium">Physical count cadence</h2>
      <p className="mt-1 max-w-3xl text-sm text-muted-foreground">{COUNT_CADENCE_EXPLAINER}</p>
      {policy.isLoading && <p className="mt-3 text-sm text-muted-foreground">Loading…</p>}
      {policy.isError && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {policy.error instanceof Error
            ? policy.error.message
            : "Could not load the count cadence."}
        </p>
      )}
      {policy.data &&
        (canManage ? (
          <CountPolicyForm organizationId={organizationId} policy={policy.data} />
        ) : (
          <CountPolicySummary policy={policy.data} />
        ))}
    </section>
  );
}

export function CountPolicySummary({ policy }: { policy: CountPolicy }) {
  return (
    <div className="mt-3 space-y-1 text-sm" data-testid="count-policy-summary">
      <p>
        <span className="text-muted-foreground">Count cadence: </span>
        <span className="font-medium">{cadenceLabel(policy)}</span>
      </p>
      <LastChanged policy={policy} />
      <p className="text-xs text-muted-foreground">Only owners can change the count cadence.</p>
    </div>
  );
}

function LastChanged({ policy }: { policy: CountPolicy }) {
  if (!policy.updatedAt) return null;
  return (
    <p className="text-xs text-muted-foreground">
      Last changed {formatCadenceDate(policy.updatedAt)}
      {policy.updatedByName ? ` by ${policy.updatedByName}` : ""}
    </p>
  );
}

export function CountPolicyForm({
  organizationId,
  policy,
}: {
  organizationId: string;
  policy: CountPolicy;
}) {
  const queryClient = useQueryClient();
  const save = useServerFn(setCountPolicyFn);
  const [enabled, setEnabled] = useState(policy.enabled);
  const [days, setDays] = useState(policy.intervalDays ? String(policy.intervalDays) : "");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    setEnabled(policy.enabled);
    setDays(policy.intervalDays ? String(policy.intervalDays) : "");
  }, [policy.enabled, policy.intervalDays]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError("");
    setSaved(false);
    let intervalDays: number | null = null;
    if (enabled || days.trim()) {
      const parsed = parseIntervalDays(days);
      if (!parsed.ok) {
        setError(parsed.error);
        return;
      }
      intervalDays = parsed.value;
    }
    setSaving(true);
    try {
      await save({ data: { organizationId, enabled, intervalDays } });
      await queryClient.invalidateQueries({ queryKey: workspaceQueryKey(organizationId) });
      setSaved(true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save the count cadence.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="mt-4 space-y-4" data-testid="count-policy-form">
      <label className="flex items-center gap-2 text-sm font-medium">
        <input
          type="checkbox"
          checked={enabled}
          onChange={(event) => {
            setEnabled(event.target.checked);
            setSaved(false);
          }}
        />
        Enable count cadence
      </label>
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <label htmlFor="count-interval-days">Count every</label>
        <Input
          id="count-interval-days"
          inputMode="numeric"
          className="w-24"
          value={days}
          disabled={!enabled}
          aria-invalid={Boolean(error) || undefined}
          onChange={(event) => {
            setDays(event.target.value);
            setSaved(false);
          }}
        />
        <span>days</span>
      </div>
      <div className="flex flex-wrap gap-2" aria-label="Suggested intervals">
        {SUGGESTED_INTERVALS.map((value) => (
          <Button
            key={value}
            type="button"
            size="sm"
            variant={days === String(value) ? "secondary" : "outline"}
            disabled={!enabled}
            onClick={() => {
              setDays(String(value));
              setSaved(false);
            }}
          >
            {value} days
          </Button>
        ))}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="flex flex-wrap items-center gap-3">
        <Button type="submit" disabled={saving}>
          {saving ? "Saving…" : "Save count cadence"}
        </Button>
        {saved && <span className="text-sm text-muted-foreground">Saved.</span>}
      </div>
      <LastChanged policy={policy} />
    </form>
  );
}
