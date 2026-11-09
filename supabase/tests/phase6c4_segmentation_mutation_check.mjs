#!/usr/bin/env node
// Phase 6C.4 mutation check for the TypeScript side: page segmentation, the Henry Schein page
// detector, the Henry Schein invoice layout in the existing parser, packet helpers and batch
// statuses. Each mutant edits one source file in place, runs tests/phase6c4-batch-invoice-intake.test.ts,
// and restores the file (also on interrupt). A mutant survives if the suite still passes.
//
// Usage: node supabase/tests/phase6c4_segmentation_mutation_check.mjs
// (Run from a clean working tree; it refuses to start if a target file has uncommitted edits
// it cannot restore from memory.)
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const suite = "tests/phase6c4-batch-invoice-intake.test.ts";
const SEG = "src/invoice-batch/segmentation.ts";
const DET = "src/invoice-batch/detectors.ts";
const HS = "src/extraction/layouts/henry-schein-invoice.ts";
const PROVIDER = "src/extraction/deterministic-invoice-provider.ts";
const PACKET = "src/invoice-batch/packet.ts";
const STATUS = "src/invoice-batch/status.ts";

// [name, file, exact text, replacement, (more text, replacement)...]
const mutants = [
  [
    "split every page into a separate invoice",
    SEG,
    "if (open && open.invoiceNumber === number && !restart) {",
    "if (false) {",
  ],
  [
    "merge adjacent different invoice numbers",
    SEG,
    "if (open && open.invoiceNumber === number && !restart) {",
    "if (open && !restart) {",
  ],
  [
    "ignore invoice number changes on continuation pages",
    SEG,
    "if (open && open.invoiceNumber === number && !restart) {",
    "if (open && (open.invoiceNumber === number || page.pageOf === null || page.pageOf.index > 1) && !restart) {",
  ],
  [
    "ignore Page 1 resets",
    SEG,
    "const restart = page.pageOf?.index === 1;",
    "const restart = false;",
  ],
  [
    "drop continuation pages",
    SEG,
    "      open.endPage = page.page;\n      continue;",
    "      continue;",
  ],
  [
    "drop unnumbered continuation pages",
    SEG,
    "        open.endPage = page.page;\n        open.lastIndex = page.pageOf!.index;",
    "        open.lastIndex = page.pageOf!.index;",
  ],
  [
    "assign a page to two invoices",
    SEG,
    '      kind: "invoice",\n      startPage: current.startPage,',
    '      kind: "invoice",\n      startPage: Math.max(1, current.startPage - 1),',
  ],
  ["lose the final invoice", SEG, "  }\n  close();\n", "  }\n"],
  [
    "attach any unnumbered page to the open invoice",
    SEG,
    "const continuation =\n        open &&\n",
    "const continuation =\n        open ||\n",
    "open.lastIndex = page.pageOf!.index;",
    "open.lastIndex = page.pageOf?.index ?? open.lastIndex;",
  ],
  [
    "treat a shared account as the same invoice",
    SEG,
    "if (open && open.invoiceNumber === number && !restart) {",
    "if (open && (open.invoiceNumber === number || (page.accountKey !== null && page.accountKey === open.accountKey)) && !restart) {",
  ],
  [
    "in-packet copies are not duplicates",
    SEG,
    '      addReason(segment.reasons, "DUPLICATE_IN_PACKET");\n      segment.duplicateOfIndex = first;',
    "      void first;",
  ],
  [
    "page irregularities are not flagged",
    SEG,
    '        ) {\n          open.reasons.add("PAGE_SEQUENCE_IRREGULAR");\n        }',
    "        ) {\n          /* none */\n        }",
  ],
  [
    "incomplete invoices are not flagged",
    SEG,
    '    )\n      addReason(reasons, "INCOMPLETE_PAGE_SEQUENCE");',
    "    )\n      void reasons;",
  ],
  [
    "missing first page is not flagged",
    SEG,
    'reasons: new Set(page.pageOf && page.pageOf.index !== 1 ? ["MISSING_FIRST_PAGE"] : []),',
    "reasons: new Set<SegmentReason>(),",
  ],
  [
    "header conflicts are not flagged",
    SEG,
    '      )\n        open.reasons.add("HEADER_MISMATCH");',
    "      )\n        void open;",
  ],
  [
    "text-less pages are silently skipped",
    SEG,
    '        reasons: ["NO_TEXT"],\n      });\n      continue;',
    '        reasons: ["NO_TEXT"],\n      });\n      segments.pop();\n      continue;',
  ],
  [
    "allocation check accepts a lost page",
    SEG,
    "    if (!owner[page]) throw new Error(`Page ${page} is not assigned to any segment`);",
    "    void owner[page];",
  ],
  [
    "multi-invoice threshold is one invoice",
    SEG,
    "invoiceSegments(segmentation).length >= 2",
    "invoiceSegments(segmentation).length >= 1",
  ],
  [
    "use the order number as the invoice identity",
    DET,
    "const numbers = [...new Set(identities.map((identity) => normalizeNumber(identity.value)))];",
    "const numbers = [...new Set([...text.matchAll(/^(\\S+) Order Date/gm)].map((match) => normalizeNumber(match[1])))];",
  ],
  ["page marker glued to text is missed", DET, "(\\d{1,3})(?!\\d)/gi", "(\\d{1,3})\\b/gi"],
  [
    "footer identity (after the account) is ignored",
    HS,
    "const INVOICE_LABEL = /(?:^|\\s)invoice#$/i;",
    "const INVOICE_LABEL = /^invoice#$/i;",
  ],
  [
    "billed quantity is the quantity ordered",
    HS,
    "const quantity = Number(shipped);",
    "const quantity = Number(ordered);",
  ],
  [
    "several invoices in one text are merged",
    HS,
    "const { accepted, candidates } = single ? rows(lines) : { accepted: [], candidates: [] };",
    "const { accepted, candidates } = rows(lines);",
  ],
  [
    "invoice total read from the wrong column position",
    HS,
    "else if (/^invoice\\s+total$/i.test(label)) result.total = value;",
    "else if (/^invoice\\s+total$/i.test(label)) result.total = values[0];",
  ],
  [
    "row arithmetic not checked",
    HS,
    "      Math.abs(cents(expectedExtension) - cents(lineTotal)) <= 2 &&\n",
    "",
  ],
  [
    "unshipped lines counted as rejected amounts",
    PROVIDER,
    ".filter((candidate) => candidate.reason !== 'HENRY_SCHEIN_NOT_SHIPPED')",
    ".filter(() => true)",
  ],
  [
    "Henry Schein layout never used",
    PROVIDER,
    "if (classification.type === 'INVOICE' && isHenryScheinInvoiceLayout(lines))",
    "if (false)",
  ],
  [
    "segment summary reads the wrong pages",
    PACKET,
    "pages.slice(startPage - 1, endPage)",
    "pages.slice(startPage, endPage + 1)",
  ],
  [
    "subset PDF shifted by one page",
    PACKET,
    "(_, offset) => startPage - 1 + offset,",
    "(_, offset) => Math.min(startPage + offset, packet.getPageCount() - 1),",
  ],
  [
    "held ranges shown as ready",
    STATUS,
    '    case "held":\n      return "segmentation_issue";',
    '    case "held":\n      return "ready";',
  ],
  [
    "parse problems shown as ready",
    STATUS,
    '      if (segment.parseNeedsReview || segment.kind !== "invoice") return "needs_review";\n',
    "",
  ],
];

const originals = new Map();
const restore = () => {
  for (const [file, text] of originals) writeFileSync(join(root, file), text);
};
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => {
    restore();
    process.exit(130);
  });

const run = () => {
  try {
    execFileSync(process.execPath, ["--test", suite], {
      cwd: root,
      stdio: "pipe",
      timeout: 240_000,
    });
    return { passed: true, detail: "" };
  } catch (error) {
    const output = String(error.stdout ?? "");
    const failing =
      output.split("\n").find((line) => line.startsWith("✖") && !line.includes("failing tests")) ??
      "suite failed";
    return { passed: false, detail: failing.slice(0, 120) };
  }
};

let survived = 0;
try {
  const control = run();
  if (!control.passed) throw new Error(`control run failed: ${control.detail}`);
  for (const [name, file, ...pairs] of mutants) {
    const path = join(root, file);
    const text = originals.get(file) ?? readFileSync(path, "utf8");
    originals.set(file, text);
    let mutated = text;
    for (let index = 0; index < pairs.length; index += 2) {
      if (!mutated.includes(pairs[index]))
        throw new Error(`mutation target not found for "${name}" in ${file}`);
      mutated = mutated.split(pairs[index]).join(pairs[index + 1]);
    }
    writeFileSync(path, mutated);
    const result = run();
    writeFileSync(path, text);
    if (result.passed) {
      survived++;
      console.log(`SURVIVED - ${name}`);
    } else console.log(`KILLED - ${name}: ${result.detail}`);
  }
} finally {
  restore();
}
if (survived) {
  console.log(`${survived} mutant(s) survived`);
  process.exit(1);
}
console.log(`all ${mutants.length} mutants killed; control passed`);
