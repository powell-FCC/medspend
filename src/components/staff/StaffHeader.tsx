export function StaffHeader({ greeting, team }: { greeting: string; team: string }) {
  return (
    <header>
      <p className="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">{team}</p>
      <h1 className="mt-1 text-[1.7rem] font-semibold tracking-[-0.035em] text-[#071d38]">{greeting}</h1>
    </header>
  );
}
