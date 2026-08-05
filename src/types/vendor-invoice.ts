export type VendorInvoiceStatus = 'uploaded';

export type VendorInvoice = {
  id: string;
  organizationId: string;
  uploadedBy: string;
  storagePath: string;
  originalFilename: string;
  fileSize: number;
  mimeType: 'application/pdf';
  status: VendorInvoiceStatus;
  createdAt: string;
};

export type InvoiceUploadMetadata = {
  organizationId: string;
  storagePath: string;
  originalFilename: string;
  fileSize: number;
  mimeType: 'application/pdf';
};
