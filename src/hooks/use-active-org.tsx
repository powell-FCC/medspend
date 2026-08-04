import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { listMyMembershipsFn } from "@/lib/orgs.functions";

export type Membership = {
  id: string;
  organizationId: string;
  role: "owner" | "admin" | "staff";
  defaultTeamId: string | null;
  defaultLocationId: string | null;
  organizationName: string;
};

type Ctx = {
  memberships: Membership[];
  active: Membership | null;
  loading: boolean;
  setActiveOrgId: (id: string) => void;
  refetch: () => void;
};

const ActiveOrgContext = createContext<Ctx | null>(null);
const KEY = "medspend.activeOrgId";

export function ActiveOrgProvider({ children }: { children: ReactNode }) {
  const fetcher = useServerFn(listMyMembershipsFn);
  const q = useQuery({
    queryKey: ["me", "memberships"],
    queryFn: () => fetcher(),
    staleTime: 30_000,
  });

  const memberships: Membership[] = useMemo(() => {
    const seen = new Set<string>();
    return (q.data ?? []).filter((m) => {
      if (seen.has(m.organizationId)) return false;
      seen.add(m.organizationId);
      return true;
    });
  }, [q.data]);

  const [activeId, setActiveIdState] = useState<string | null>(() => {
    if (typeof window === "undefined") return null;
    return window.localStorage.getItem(KEY);
  });

  useEffect(() => {
    if (!memberships.length) return;
    if (activeId && memberships.some((m) => m.organizationId === activeId)) return;
    if (memberships.length === 1) {
      setActiveIdState(memberships[0].organizationId);
      window.localStorage.setItem(KEY, memberships[0].organizationId);
    }
  }, [memberships, activeId]);

  const setActiveOrgId = (id: string) => {
    setActiveIdState(id);
    if (typeof window !== "undefined") window.localStorage.setItem(KEY, id);
  };

  const active = memberships.find((m) => m.organizationId === activeId) ?? null;

  return (
    <ActiveOrgContext.Provider
      value={{
        memberships,
        active,
        loading: q.isLoading,
        setActiveOrgId,
        refetch: () => q.refetch(),
      }}
    >
      {children}
    </ActiveOrgContext.Provider>
  );
}

export function useActiveOrg() {
  const ctx = useContext(ActiveOrgContext);
  if (!ctx) throw new Error("useActiveOrg must be used within ActiveOrgProvider");
  return ctx;
}