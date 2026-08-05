import { useRef, useState, type DragEvent } from 'react';
import { FileText, UploadCloud } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

type Props = {
  disabled?: boolean;
  onSelect: (file: File) => void;
};

export function InvoiceDropzone({ disabled = false, onSelect }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);

  function accept(files: FileList | null) {
    const file = files?.item(0);
    if (file) onSelect(file);
  }

  function drop(event: DragEvent<HTMLDivElement>) {
    event.preventDefault();
    setDragging(false);
    if (!disabled) accept(event.dataTransfer.files);
  }

  return (
    <div
      className={cn(
        'relative flex min-h-72 flex-col items-center justify-center rounded-2xl border-2 border-dashed px-6 py-12 text-center transition-colors',
        dragging ? 'border-primary bg-primary/5' : 'border-border bg-muted/20 hover:bg-muted/35',
        disabled && 'cursor-not-allowed opacity-60',
      )}
      onDragEnter={(event) => { event.preventDefault(); if (!disabled) setDragging(true); }}
      onDragOver={(event) => event.preventDefault()}
      onDragLeave={() => setDragging(false)}
      onDrop={drop}
      data-testid="invoice-dropzone"
    >
      <div className="mb-5 grid h-16 w-16 place-items-center rounded-2xl bg-primary/10 text-primary">
        {dragging ? <FileText className="h-8 w-8" /> : <UploadCloud className="h-8 w-8" />}
      </div>
      <h2 className="text-lg font-semibold">Drop a vendor invoice here</h2>
      <p className="mt-2 max-w-md text-sm text-muted-foreground">
        Upload one PDF at a time. Files are stored securely for your organization.
      </p>
      <Button className="mt-6" type="button" disabled={disabled} onClick={() => inputRef.current?.click()}>
        Choose PDF
      </Button>
      <p className="mt-3 text-xs text-muted-foreground">PDF only · Maximum 25 MB</p>
      <input
        ref={inputRef}
        className="sr-only"
        type="file"
        accept="application/pdf,.pdf"
        disabled={disabled}
        onChange={(event) => { accept(event.target.files); event.target.value = ''; }}
        aria-label="Choose invoice PDF"
      />
    </div>
  );
}
