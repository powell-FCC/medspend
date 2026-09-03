import type { Ref } from "react";

export function AdminMessagePanel({ staffMessage, internalNote, onStaffMessageChange, onInternalNoteChange,
  staffGuidance, staffPlaceholder, staffMessageRequired = false, disabled = false, staffMessageRef,
}: {
  staffMessage: string;
  internalNote: string;
  onStaffMessageChange: (value: string) => void;
  onInternalNoteChange: (value: string) => void;
  staffGuidance: string;
  staffPlaceholder: string;
  staffMessageRequired?: boolean;
  disabled?: boolean;
  staffMessageRef?: Ref<HTMLTextAreaElement>;
}) {
  return (
    <fieldset disabled={disabled} className="grid min-w-0 gap-4 sm:grid-cols-2">
      <div>
        <label htmlFor="admin-staff-message" className="text-sm font-semibold text-[#293e55]">
          {staffMessageRequired ? "Reason for decline (required)" : "Message to Staff (optional)"}
        </label>
        <p id="staff-message-guidance" className="mt-1 text-xs leading-5 text-[#697687]">Visible to requester. {staffGuidance}</p>
        <textarea ref={staffMessageRef} id="admin-staff-message" aria-describedby="staff-message-guidance" rows={3} maxLength={5000} required={staffMessageRequired} value={staffMessage} onChange={(event) => onStaffMessageChange(event.target.value)} placeholder={staffPlaceholder} className="mt-2 w-full resize-y rounded-lg border border-[#ccd5df] bg-white p-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#f56600]" />
      </div>
      <div>
        <label htmlFor="admin-internal-note" className="text-sm font-semibold text-[#293e55]">Internal Admin Note</label>
        <p id="internal-note-guidance" className="mt-1 text-xs leading-5 text-[#697687]">Admins only — never visible to staff.</p>
        <textarea id="admin-internal-note" aria-describedby="internal-note-guidance" rows={3} maxLength={5000} value={internalNote} onChange={(event) => onInternalNoteChange(event.target.value)} placeholder="Optional private context" className="mt-2 w-full resize-y rounded-lg border border-[#ccd5df] bg-[#f8fafc] p-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#102a49]" />
      </div>
    </fieldset>
  );
}
