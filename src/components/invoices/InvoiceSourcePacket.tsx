import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Link } from "@tanstack/react-router";
import { getInvoiceProvenanceFn } from "@/lib/invoice-batches.functions";

// Phase 6C.4: where an invoice split from a packet came from. Renders nothing for a normal upload.
export function InvoiceSourcePacket({
  organizationId,
  sourceFileId,
}: {
  organizationId: string;
  sourceFileId: string;
}) {
  const getProvenance = useServerFn(getInvoiceProvenanceFn);
  const provenance = useQuery({
    queryKey: ["invoice-provenance", organizationId, sourceFileId],
    queryFn: () => getProvenance({ data: { organizationId, sourceFileId } }),
    staleTime: Infinity,
  });
  const value = provenance.data;
  if (!value) return null;
  const pages =
    value.pageStart === value.pageEnd
      ? `page ${value.pageStart}`
      : `pages ${value.pageStart}–${value.pageEnd}`;
  return (
    <p className="mt-1 text-xs text-muted-foreground" data-testid="invoice-source-packet">
      From {pages} of {value.originalFilename} ({value.packetPageCount} pages).{" "}
      <Link
        className="font-medium text-primary underline-offset-2 hover:underline"
        to="/invoices/batches/$batchId"
        params={{ batchId: value.batchId }}
      >
        View packet
      </Link>
    </p>
  );
}
