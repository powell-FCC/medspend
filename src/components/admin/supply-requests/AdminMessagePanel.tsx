export function AdminMessagePanel({
  staffMessage,
  internalNote,
  onStaffMessageChange,
  onInternalNoteChange,
  staffGuidance,
  staffPlaceholder,
  staffMessageRequired = false,
}: {
  staffMessage: string;
  internalNote: string;
  onStaffMessageChange: (value: string) => void;
  onInternalNoteChange: (value: string) => void;
  staffGuidance: string;
  staffPlaceholder: string;
  staffMessageRequired?: boolean;
}) {
  return (
    <section className="space-y-4" aria-labelledby="communication-heading">
      <div>
        <h3 id="communication-heading" className="font-semibold text-[#102a49]">Communication</h3>
        <p className="mt-1 text-sm text-[#697687]">Keep requester communication separate from private operational context.</p>
      </div>
      <div className="rounded-xl border border-[#f3d1b9] bg-[#fff8f3] p-4">
        <label htmlFor="admin-staff-message" className="text-sm font-semibold text-[#8d3c08]">Message to Staff{staffMessageRequired ? " (required)" : " (optional)"}</label>
        <p className="mt-0.5 text-xs text-[#8d674e]">Visible to requester</p>
        <p className="mt-2 text-sm text-[#6f513d]">{staffGuidance}</p>
        <textarea id="admin-staff-message" rows={3} required={staffMessageRequired} value={staffMessage} onChange={(event) => onStaffMessageChange(event.target.value)} placeholder={staffPlaceholder} className="mt-3 w-full resize-none rounded-lg border border-[#e8c6ae] bg-white p-3 text-sm outline-none focus:border-[#f56600] focus:ring-2 focus:ring-[#f56600]/15" />
      </div>
      <div className="rounded-xl border border-[#dce2e8] bg-[#f7f9fb] p-4">
        <label htmlFor="admin-internal-note" className="text-sm font-semibold text-[#34465b]">Internal Admin Note</label>
        <p className="mt-0.5 text-xs text-[#697687]">Admins only — never visible to staff</p>
        <textarea id="admin-internal-note" rows={3} value={internalNote} onChange={(event) => onInternalNoteChange(event.target.value)} placeholder="Record private operational context" className="mt-3 w-full resize-none rounded-lg border border-[#d5dde5] bg-white p-3 text-sm outline-none focus:border-[#102a49] focus:ring-2 focus:ring-[#102a49]/10" />
      </div>
    </section>
  );
}
