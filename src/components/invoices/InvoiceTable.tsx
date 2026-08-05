import { FileText } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import type { VendorInvoice } from '@/types/vendor-invoice';

function formatSize(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function InvoiceTable({ invoices }: { invoices: VendorInvoice[] }) {
  return (
    <section className="overflow-hidden rounded-xl border bg-card">
      <div className="border-b px-5 py-4">
        <h2 className="font-semibold">Uploaded invoices</h2>
        <p className="mt-1 text-sm text-muted-foreground">Newest uploads appear first.</p>
      </div>
      {invoices.length === 0 ? (
        <div className="flex flex-col items-center px-6 py-12 text-center text-muted-foreground">
          <FileText className="mb-3 h-8 w-8" />
          <p className="text-sm font-medium text-foreground">No invoices uploaded yet</p>
          <p className="mt-1 text-xs">Your first upload will appear here.</p>
        </div>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="pl-5">Filename</TableHead>
              <TableHead>Uploaded</TableHead>
              <TableHead>Size</TableHead>
              <TableHead className="pr-5">Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {invoices.map((invoice) => (
              <TableRow key={invoice.id}>
                <TableCell className="max-w-sm pl-5 font-medium">
                  <span className="flex items-center gap-2 truncate">
                    <FileText className="h-4 w-4 shrink-0 text-muted-foreground" />
                    <span className="truncate">{invoice.originalFilename}</span>
                  </span>
                </TableCell>
                <TableCell>{new Date(invoice.createdAt).toLocaleString()}</TableCell>
                <TableCell>{formatSize(invoice.fileSize)}</TableCell>
                <TableCell className="pr-5"><Badge variant="secondary">Uploaded</Badge></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </section>
  );
}
