import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Check, ChevronsUpDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { listOrgMembersFn } from "@/lib/orgs.functions";
import {
  listWorkspaceItemsFn,
  listWorkspaceLocationsFn,
} from "@/lib/inventory-workspace.functions";
import { adjustmentHistoryReasons } from "@/inventory/activity";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { ActivityFilterState } from "./useActivityFilterState";

export function ActivityFilterBar({
  organizationId,
  locationId,
  state,
  personLabel,
  showReason,
}: {
  organizationId: string;
  locationId?: string;
  state: ActivityFilterState;
  personLabel: string;
  showReason?: boolean;
}) {
  const listLocations = useServerFn(listWorkspaceLocationsFn);
  const listMembers = useServerFn(listOrgMembersFn);
  const locations = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "locations", "all"],
    queryFn: () => listLocations({ data: { organizationId, status: "all" } }),
    enabled: !locationId,
    select: (data) => data.locations,
  });
  const members = useQuery({
    queryKey: ["org-members", organizationId],
    queryFn: () => listMembers({ data: { organizationId } }),
    select: (rows) => [...rows].sort((a, b) => a.fullName.localeCompare(b.fullName)),
  });
  const { values, set } = state;
  return (
    <>
      <div
        className="grid gap-3 rounded-xl border bg-card p-4 sm:grid-cols-2 lg:grid-cols-[repeat(auto-fit,minmax(10rem,1fr))]"
        data-testid="activity-filters"
      >
        {!locationId && (
          <select
            aria-label="Location filter"
            className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
            value={values.location}
            onChange={(e) => set.setLocation(e.target.value)}
          >
            <option value="">All locations</option>
            {locations.data?.map((row) => (
              <option key={row.id} value={row.id}>
                {row.name}
                {row.active ? "" : " (archived)"}
              </option>
            ))}
          </select>
        )}
        <ItemFilter organizationId={organizationId} value={values.item} onChange={set.setItem} />
        <select
          aria-label={`${personLabel} filter`}
          className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
          value={values.person}
          onChange={(e) => set.setPerson(e.target.value)}
        >
          <option value="">Anyone</option>
          {members.data?.map((member) => (
            <option key={member.userId} value={member.userId}>
              {member.fullName}
            </option>
          ))}
        </select>
        {showReason && (
          <select
            aria-label="Reason filter"
            className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
            value={values.reason}
            onChange={(e) => set.setReason(e.target.value)}
          >
            <option value="">Any reason</option>
            {adjustmentHistoryReasons.map((reason) => (
              <option key={reason} value={reason}>
                {reason}
              </option>
            ))}
          </select>
        )}
        <Input
          type="date"
          aria-label="From date"
          className="min-w-0"
          value={values.from}
          onChange={(e) => set.setFrom(e.target.value)}
        />
        <Input
          type="date"
          aria-label="To date"
          className="min-w-0"
          value={values.to}
          onChange={(e) => set.setTo(e.target.value)}
        />
      </div>
      {state.invalidRange && (
        <p role="alert" className="text-sm text-destructive">
          The start date must be on or before the end date.
        </p>
      )}
    </>
  );
}

// Items are searched on the server, a few at a time; an organization may have thousands.
function ItemFilter({
  organizationId,
  value,
  onChange,
}: {
  organizationId: string;
  value: { id: string; name: string } | null;
  onChange: (value: { id: string; name: string } | null) => void;
}) {
  const listItems = useServerFn(listWorkspaceItemsFn);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(search.trim()), 250);
    return () => clearTimeout(timer);
  }, [search]);
  const items = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "activity-item-search", debounced],
    queryFn: () =>
      listItems({
        data: { organizationId, search: debounced, status: "all", limit: 20 },
      }),
    enabled: open,
  });
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="outline"
          role="combobox"
          aria-expanded={open}
          aria-label="Item filter"
          className="h-9 min-w-0 justify-between px-3 font-normal"
        >
          <span className="truncate">{value?.name ?? "Any item"}</span>
          <ChevronsUpDown className="h-4 w-4 shrink-0 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-0" align="start">
        <Command shouldFilter={false}>
          <CommandInput placeholder="Search items…" value={search} onValueChange={setSearch} />
          <CommandList>
            <CommandEmpty>{items.isLoading ? "Searching…" : "No items found."}</CommandEmpty>
            <CommandGroup>
              <CommandItem
                value="__any__"
                onSelect={() => {
                  onChange(null);
                  setOpen(false);
                }}
              >
                <Check className={`h-4 w-4 ${value ? "opacity-0" : ""}`} />
                Any item
              </CommandItem>
              {items.data?.rows.map((item) => (
                <CommandItem
                  key={item.id}
                  value={item.id}
                  onSelect={() => {
                    onChange({ id: item.id, name: item.name });
                    setOpen(false);
                  }}
                >
                  <Check className={`h-4 w-4 ${value?.id === item.id ? "" : "opacity-0"}`} />
                  <span className="min-w-0 truncate">
                    {item.name}
                    {item.sku ? ` · ${item.sku}` : ""}
                    {item.active ? "" : " (archived)"}
                  </span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
