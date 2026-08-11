import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import test from "node:test";
import {
  classifyDocument,
  extractVendorEvidence,
  resolveVendor,
} from "../src/extraction/document-identity.ts";
import { DeterministicInvoiceExtractionProvider } from "../src/extraction/deterministic-invoice-provider.ts";
import { EmbeddedPdfTextProvider } from "../src/extraction/embedded-pdf-text-provider.ts";

test("explicit document labels classify without using totals or tables", () => {
  assert.equal(classifyDocument("Sales Invoice\nInvoice: A-1").type, "INVOICE");
  assert.equal(classifyDocument("Order Confirmation\nOrder Number 123").type, "ORDER_CONFIRMATION");
  assert.equal(classifyDocument("Purchase Order\nPO # 123").type, "PURCHASE_ORDER");
  assert.equal(classifyDocument("Credit Memo\nCredit # C1").type, "CREDIT_MEMO");
  assert.equal(classifyDocument("Account Statement\nBalance 10.00").type, "STATEMENT");
  assert.equal(classifyDocument("Products\nTotal 10.00").type, "UNKNOWN");
});

test("semantic identity keeps invoice, order, PO, and named dates separate", async () => {
  const provider = new DeterministicInvoiceExtractionProvider();
  const invoice = await provider.extractInvoice(
    "Sales Invoice\nInvoice # INV-7\nInvoice Date: July 23, 2026\nOrder Number: O-9\nOrder Date: 07/20/2026\nShip Date: 07/21/2026\nDue Date: 08/20/2026\nPO: PO-42\nTotal 10.00",
  );
  assert.equal(invoice.header.invoiceNumber.value, "INV-7");
  assert.equal(invoice.header.invoiceDate.value, "2026-07-23");
  assert.equal(invoice.header.purchaseOrder.value, "PO-42");
  const order = await provider.extractInvoice(
    "Order Confirmation\nORDER NUMBER: 80728662\nORDER DATE\n08/06/26\nInvoice-looking item total 10.00",
  );
  assert.equal(order.header.orderNumber?.value, "80728662");
  assert.equal(order.header.orderDate?.value, "2026-08-06");
  assert.equal(order.header.invoiceNumber.value, "");
  assert.equal(order.header.invoiceDate.value, "");
  const missingPo = await provider.extractInvoice(
    "Invoice: I-1\nInvoice Date: 07/23/2026\nCustomer PO No. Order No.\nO-22\nTotal 10.00",
  );
  assert.equal(missingPo.header.purchaseOrder.value, "");
});

test("date and identifier exclusions do not promote order, ship, due, customer email, or PO", async () => {
  const extraction = await new DeterministicInvoiceExtractionProvider().extractInvoice(
    "Order Confirmation\nOrder Number: O-1\nOrder Date: 07/20/2026\nShip Date: 07/21/2026\nDue Date: 08/20/2026\ncustomer@example.org\nPO:\nTotal 10.00",
  );
  assert.equal(extraction.header.invoiceNumber.value, "");
  assert.equal(extraction.header.invoiceDate.value, "");
  assert.equal(extraction.header.purchaseOrder.value, "");
});

test("seller domains resolve existing vendors while customer and ship-to identities do not", () => {
  const vendors = [
    {
      id: "thorne",
      organizationId: "org-a",
      name: "Thorne",
      normalizedName: "thorne",
      website: null,
      email: null,
    },
    {
      id: "customer",
      organizationId: "org-a",
      name: "FC Cincinnati",
      normalizedName: "fc cincinnati",
    },
  ];
  const seller = resolveVendor(
    "org-a",
    extractVendorEvidence("Ship To: FC Cincinnati\nhttps://www.thorne.com\nsupport@thorne.com"),
    vendors,
    [],
  );
  assert.equal(seller.state, "MATCHED");
  assert.equal(seller.vendorId, "thorne");
  const customerOnly = resolveVendor(
    "org-a",
    extractVendorEvidence("powell@fccincinnati.com\nSHIP TO: FC Cincinnati"),
    vendors,
    [],
  );
  assert.notEqual(customerOnly.state, "MATCHED");
});

test("manufacturer text alone cannot resolve vendor and similar names remain ambiguous", () => {
  const vendors = [
    { id: "a", organizationId: "org-a", name: "Acme Medical", normalizedName: "acme medical" },
    {
      id: "b",
      organizationId: "org-a",
      name: "Acme Medical Supply",
      normalizedName: "acme medical supply",
    },
  ];
  assert.equal(
    resolveVendor(
      "org-a",
      extractVendorEvidence("Item Description\nAcme Medical Needles 10/Bx"),
      vendors,
      [],
    ).state,
    "UNRESOLVED",
  );
  assert.notEqual(
    resolveVendor("org-a", extractVendorEvidence("* special acme contract price *"), vendors, [])
      .state,
    "MATCHED",
  );
});

test("remembered signatures are deterministic, correctable, and organization scoped", () => {
  const evidence = extractVendorEvidence("https://seller.example.com");
  const vendors = [
    { id: "a", organizationId: "org-a", name: "Seller", normalizedName: "seller" },
    { id: "b", organizationId: "org-b", name: "Seller", normalizedName: "seller" },
  ];
  const signatures = [
    {
      id: "s1",
      organizationId: "org-a",
      vendorId: "a",
      signatureType: "WEB_DOMAIN" as const,
      normalizedValue: "seller.example.com",
    },
  ];
  assert.equal(resolveVendor("org-a", evidence, vendors, signatures).vendorId, "a");
  assert.equal(resolveVendor("org-b", evidence, vendors, signatures).vendorId, "b");
  const corrected = [{ ...signatures[0], vendorId: "a2" }];
  assert.equal(
    resolveVendor("org-a", evidence, [...vendors, { ...vendors[0], id: "a2" }], corrected).vendorId,
    "a2",
  );
});

test("monetary hierarchy rejects Total Tax and Total Applied as total", async () => {
  const extraction = await new DeterministicInvoiceExtractionProvider().extractInvoice(
    "Invoice: I-1\nInvoice Date: 07/23/2026\nSubtotal 100.00\nTotal Tax 7.00\nFreight 3.00\nTotal 110.00\nTotal Applied 0.00\nBalance 110.00",
  );
  assert.equal(extraction.header.subtotal.value, 100);
  assert.equal(extraction.header.tax.value, 7);
  assert.equal(extraction.header.shipping.value, 3);
  assert.equal(extraction.header.total.value, 110);
});

test(
  "real Thorne and Henry Schein PDFs preserve known-safe headers and semantic document identity",
  {
    skip:
      !existsSync("/Users/aaronpowell/Downloads/Sales Invoice SI010247127.pdf") ||
      !existsSync("/Users/aaronpowell/Downloads/80728662.pdf"),
  },
  async () => {
    const textProvider = new EmbeddedPdfTextProvider();
    const parser = new DeterministicInvoiceExtractionProvider();
    const thorneText = await textProvider.extractText(
      new Uint8Array(await readFile("/Users/aaronpowell/Downloads/Sales Invoice SI010247127.pdf")),
    );
    const thorne = await parser.extractInvoice(thorneText.text);
    assert.equal(thorne.header.documentType?.value, "INVOICE");
    assert.equal(thorne.header.invoiceNumber.value, "SI010247127");
    assert.equal(thorne.header.invoiceDate.value, "2026-07-23");
    assert.equal(thorne.header.subtotal.value, 893.03);
    assert.equal(thorne.header.tax.value, 60.28);
    assert.equal(thorne.header.total.value, 953.31);
    assert.equal(thorne.items.length, 4);
    assert.equal(
      resolveVendor(
        "org-a",
        thorne.vendorEvidence ?? [],
        [{ id: "thorne", organizationId: "org-a", name: "Thorne", normalizedName: "thorne" }],
        [],
      ).vendorId,
      "thorne",
    );
    const henryText = await textProvider.extractText(
      new Uint8Array(await readFile("/Users/aaronpowell/Downloads/80728662.pdf")),
    );
    const henry = await parser.extractInvoice(henryText.text);
    assert.equal(henry.header.documentType?.value, "ORDER_CONFIRMATION");
    assert.equal(henry.header.orderNumber?.value, "80728662");
    assert.equal(henry.header.orderDate?.value, "2026-08-06");
    assert.equal(henry.header.invoiceNumber.value, "");
    assert.equal(henry.header.invoiceDate.value, "");
    assert.equal(henry.header.shipping.value, 3.95);
    assert.equal(henry.header.tax.value, 46.15);
    assert.equal(henry.header.total.value, 729.94);
    assert.equal(henry.items.length, 4);
    assert.equal(
      resolveVendor(
        "org-a",
        henry.vendorEvidence ?? [],
        [
          {
            id: "henry",
            organizationId: "org-a",
            name: "Henry Schein",
            normalizedName: "henry schein",
          },
        ],
        [],
      ).vendorId,
      "henry",
    );
  },
);
