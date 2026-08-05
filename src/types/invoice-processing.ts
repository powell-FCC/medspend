export type ProcessingStatus = 'uploaded' | 'processing' | 'review_required' | 'completed' | 'failed';

export interface ReviewItem {
  id: string;
  sku: string;
  description: string;
  quantity: number;
  unitPrice: number;
  category: string;
  unitOfMeasure: string;
}

export interface InvoiceReview {
  sourceFileId: string;
  organizationId: string;
  originalFilename: string;
  vendorName: string | null;
  invoiceNumber: string | null;
  invoiceDate: string | null;
  invoiceTotal: number | null;
  status: ProcessingStatus;
  items: ReviewItem[];
}

export const MOCK_REVIEW_ITEMS: ReviewItem[] = [
  { id: 'mock-1', sku: '123456', description: 'Nitrile Exam Gloves', quantity: 20, unitPrice: 25, category: 'Clinical supplies', unitOfMeasure: 'box' },
];
