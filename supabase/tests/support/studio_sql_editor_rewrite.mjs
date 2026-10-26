// Reproduces what the Supabase Studio SQL Editor does to a query before sending it, when its
// warning modal offers "Run and enable RLS" for CREATE TABLE statements that have no matching
// ENABLE ROW LEVEL SECURITY in the same submission. Studio appends one
// `ALTER TABLE … ENABLE ROW LEVEL SECURITY;` per such table at the very END of the text, so
// for a migration that ends in COMMIT those statements run after the commit.
//
// Ported from supabase/supabase:
//   apps/studio/lib/sql-event-parser.ts (3036bb103b3214bfbf7e87ffb8321f527b38af1a)
//   apps/studio/components/interfaces/SQLEditor/SQLEditor.utils.ts
//     getCreateTablesMissingRLS + appendEnableRLSStatements (4bb36b944fe3bb5cc4825e9653e694c883f0f21b)
// Studio's other rewrites (auto-limit, role impersonation) do not apply to a migration run as
// the default role, so they are not modelled.
//
// Usage: node studio_sql_editor_rewrite.mjs <file.sql> [--tables]
//   default   prints the SQL Studio sends after "Run and enable RLS"
//   --tables  prints the tables the modal flags, one per line (empty: no modal for RLS)
import { readFileSync } from "node:fs";

const ident = String.raw`(?<schema>(?:"[^"]+"|[\w]+)\.)?(?<table>(?:"(?:[^"]|"")+"|\`(?:[^\`]|\`\`)+\`|[\w]+))`;
const DETECTORS = [
  {
    type: "created",
    patterns: [
      new RegExp(String.raw`CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?${ident}`, "i"),
      new RegExp(
        String.raw`CREATE\s+TEMP(?:ORARY)?\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?${ident}`,
        "i",
      ),
      new RegExp(String.raw`CREATE\s+UNLOGGED\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?${ident}`, "i"),
      new RegExp(String.raw`SELECT\s+.*?\s+INTO\s+${ident}`, "is"),
      new RegExp(String.raw`CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?${ident}\s+AS\s+SELECT`, "i"),
    ],
  },
  {
    type: "data",
    patterns: [
      new RegExp(String.raw`INSERT\s+INTO\s+${ident}`, "i"),
      new RegExp(String.raw`COPY\s+${ident}\s+FROM`, "i"),
    ],
  },
  {
    type: "rls",
    patterns: [
      new RegExp(
        String.raw`ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?${ident}.*?ENABLE\s+ROW\s+LEVEL\s+SECURITY`,
        "i",
      ),
      new RegExp(
        String.raw`ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?${ident}.*?ENABLE\s+RLS`,
        "i",
      ),
    ],
  },
];

const clean = (identifier) => identifier?.replace(/["`']/g, "").replace(/\.$/, "");

function tableEvents(sql) {
  const stripped = sql
    .replace(/(\$[a-zA-Z0-9_]*\$)[\s\S]*?\1/g, "$1$1")
    .replace(/--.*?$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const tokens =
    stripped.match(
      /'([^']|'')*'|"([^"]|"")*"|\$[a-zA-Z0-9_]*\$[\s\S]*?\$[a-zA-Z0-9_]*\$|;|[^'"$;]+/g,
    ) ?? [];
  const statements = [];
  let current = "";
  for (const token of tokens) {
    if (token === ";") {
      if (current.trim()) statements.push(current.trim());
      current = "";
    } else current += token;
  }
  if (current.trim()) statements.push(current.trim());

  const events = [];
  for (const statement of statements) {
    outer: for (const { type, patterns } of DETECTORS) {
      for (const pattern of patterns) {
        const match = statement.match(pattern);
        if (match?.groups) {
          events.push({
            type,
            schema: clean(match.groups.schema),
            tableName: clean(match.groups.table),
          });
          break outer;
        }
      }
    }
  }
  const seen = new Set();
  return events.filter((e) => {
    const key = `${e.type}:${e.schema ?? ""}:${e.tableName ?? ""}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function tablesMissingRLS(sql) {
  const events = tableEvents(sql);
  const key = (e) => `${e.schema ?? ""}.${e.tableName}`;
  const enabled = new Set(events.filter((e) => e.type === "rls" && e.tableName).map(key));
  return events.filter((e) => e.type === "created" && e.tableName && !enabled.has(key(e)));
}

export function appendEnableRLS(sql, tables) {
  if (tables.length === 0) return sql;
  const quote = (identifier) =>
    /^[a-z_][a-z0-9_]*$/.test(identifier) ? identifier : `"${identifier.replace(/"/g, '""')}"`;
  const additions = tables
    .map(({ schema, tableName }) => {
      const target = schema ? `${quote(schema)}.${quote(tableName)}` : quote(tableName);
      return `ALTER TABLE ${target} ENABLE ROW LEVEL SECURITY;`;
    })
    .join("\n");
  const trimmed = sql.replace(/\s+$/, "");
  const separator = trimmed.endsWith(";")
    ? "\n\n"
    : /--[^\r\n]*$/.test(trimmed)
      ? "\n;\n\n"
      : ";\n\n";
  return `${trimmed}${separator}-- Added by Supabase: enable Row Level Security on newly created tables\n${additions}\n`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const sql = readFileSync(process.argv[2], "utf8");
  const tables = tablesMissingRLS(sql);
  if (process.argv.includes("--tables")) {
    for (const t of tables)
      process.stdout.write(`${t.schema ? `${t.schema}.` : ""}${t.tableName}\n`);
  } else process.stdout.write(appendEnableRLS(sql, tables));
}
