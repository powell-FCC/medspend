// Loads the BUILT production Worker (.output/server, what Workers Builds deploys) into the
// Cloudflare Workers runtime (workerd, through Miniflare) and fires its real scheduled() handler,
// the path the cron trigger in wrangler.jsonc drives. Proves, in workerd and not just Node:
//   * the Nitro plugin registers the cloudflare:scheduled hook and scheduled() runs the cycle;
//   * the cycle claims due work through PostgREST (service role), renders, sends through the
//     fake email adapter and records each outcome;
//   * a provider failure is recorded (retry scheduled / dead-lettered), not lost;
//   * overlapping scheduled() runs never send a delivery twice;
//   * a Worker without the service-role secret does nothing (fail safe) and leaks no value.
//
// Everything is local: PostgREST and Postgres on 127.0.0.1 (started by
// scripts/worker-scheduled-check.sh), a fake email sink served by this process. No hosted
// project, no email provider.
//
// Env: MEDSPEND_MINIFLARE (miniflare package dir), MEDSPEND_REST_URL, MEDSPEND_JWT_SECRET,
//      MEDSPEND_DB_PORT.
import { execFileSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const serverDir = resolve(".output/server");
const miniflareDir = process.env.MEDSPEND_MINIFLARE;
const restUrl = process.env.MEDSPEND_REST_URL;
const jwtSecret = process.env.MEDSPEND_JWT_SECRET;
const dbPort = process.env.MEDSPEND_DB_PORT;
if (!miniflareDir || !restUrl || !jwtSecret || !dbPort)
  throw new Error("run through scripts/worker-scheduled-check.sh");
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(restUrl)) throw new Error("PostgREST must be local");
const { Miniflare } = await import(pathToFileURL(join(miniflareDir, "dist/src/index.js")).href);

const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const signToken = (claims) => {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", jwtSecret).update(body).digest("base64url")}`;
};
const serviceKey = signToken({ role: "service_role" });
const sql = (statement) =>
  execFileSync(
    "psql",
    [
      "-X",
      "-q",
      "-At",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-c",
      statement,
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PGPASSWORD: "postgres",
        PGHOST: "127.0.0.1",
        PGPORT: dbPort,
        PGOPTIONS: "-c client_min_messages=warning",
      },
    },
  ).trim();

// Local server: /rest/v1/* -> PostgREST (supabase-js adds the prefix); /sink = fake email endpoint.
const received = [];
const sinkScript = [];
const server = createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  if (request.url === "/sink") {
    const message = JSON.parse(body.toString("utf8"));
    const outcome = sinkScript.shift() ?? "success";
    received.push({ ...message, outcome });
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ outcome, id: `sink-${received.length}` }));
    return;
  }
  const target = new URL(request.url.replace(/^\/rest\/v1/, ""), restUrl);
  const headers = { ...request.headers };
  delete headers.host;
  delete headers["content-length"];
  const upstream = await fetch(target, {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : body,
  });
  response.writeHead(upstream.status, Object.fromEntries(upstream.headers));
  response.end(Buffer.from(await upstream.arrayBuffer()));
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const local = `http://127.0.0.1:${server.address().port}`;

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (path.endsWith(".mjs")) files.push(path);
  }
};
walk(serverDir);
const config = JSON.parse(readFileSync(join(serverDir, "wrangler.json"), "utf8"));
const mainPath = join(serverDir, config.main ?? "index.mjs");
const modules = [mainPath, ...files.filter((file) => file !== mainPath)].map((path) => ({
  type: "ESModule",
  path,
  contents: readFileSync(path, "utf8"),
}));
const worker = (bindings) => {
  const options = {
    name: "medspend-scheduled-check",
    modules,
    modulesRoot: serverDir,
    compatibilityDate: config.compatibility_date,
    compatibilityFlags: config.compatibility_flags,
    bindings,
  };
  try {
    return new Miniflare({ workers: [options] });
  } catch {
    return new Miniflare(options);
  }
};

let failed = false;
const check = (ok, label, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? `: ${detail}` : ""}`);
  failed ||= !ok;
};
const cron = config.triggers?.crons?.[0];
check(cron === "*/5 * * * *", "built wrangler.json carries the cron trigger", String(cron));

const fullBindings = {
  SUPABASE_URL: local,
  SUPABASE_SERVICE_ROLE_KEY: serviceKey,
  NOTIFICATIONS_EMAIL_PROVIDER: "fake",
  NOTIFICATIONS_FAKE_EMAIL_ENDPOINT: `${local}/sink`,
  APP_BASE_URL: "https://app.example.test",
};
const deliveryCounts = () =>
  Object.fromEntries(
    sql(
      "SELECT status || '=' || count(*) FROM public.notification_deliveries GROUP BY status ORDER BY status",
    )
      .split("\n")
      .filter(Boolean)
      .map((line) => line.split("=")),
  );

try {
  // 1. Without the service-role secret: nothing happens, nothing is claimed.
  const unconfigured = worker({ ...fullBindings, SUPABASE_SERVICE_ROLE_KEY: "" });
  try {
    const fetcher = await unconfigured.getWorker();
    const result = await fetcher.scheduled({ cron, scheduledTime: new Date() });
    check(result.outcome === "ok", "scheduled() without the secret completes", result.outcome);
  } finally {
    await unconfigured.dispose();
  }
  check(received.length === 0, "no email without the secret");
  check(
    sql("SELECT count(*) FROM public.notification_deliveries") === "0",
    "nothing dispatched or claimed without the secret",
  );

  // 2. Configured: the pending submission and decision events go out, once each.
  const mf = worker(fullBindings);
  try {
    const fetcher = await mf.getWorker();
    sinkScript.push("success", "success", "retryable", "reject");
    const first = await fetcher.scheduled({ cron, scheduledTime: new Date() });
    check(first.outcome === "ok", "scheduled() completes", first.outcome);
    const counts = deliveryCounts();
    check(
      received.length === 4,
      "four emails attempted through the fake adapter",
      String(received.length),
    );
    check(
      counts.sent === "2" && counts.pending === "1" && counts.dead === "1",
      "outcomes recorded: 2 sent, 1 retry scheduled, 1 dead",
      JSON.stringify(counts),
    );
    const subjects = received.map((message) => message.subject).sort();
    check(
      subjects.filter((subject) => subject === "New supply request from Runtime Staff").length ===
        3 && subjects.includes("Your supply request was approved"),
      "submission notice to the 3 admins and the requester's approval",
      JSON.stringify(subjects),
    );
    check(
      received.every(
        (message) => message.from === "SportSpend <notifications@notify.sport-spend.com>",
      ),
      "sender",
    );
    check(
      received.every((message) => !/RUNTIME-INTERNAL/.test(message.html + message.text)),
      "no internal note in any email",
    );
    check(
      received.every((message) =>
        /^notification-delivery-[0-9a-f-]{36}$/.test(message.idempotencyKey),
      ),
      "per-delivery idempotency key",
    );
    check(
      sql(
        "SELECT count(*) FROM public.notification_deliveries WHERE status = 'sent' AND provider = 'fake' AND provider_message_id LIKE 'sink-%'",
      ) === "2",
      "provider message ids stored",
    );

    // 3. Overlapping scheduled() runs over a burst: every delivery exactly once.
    sql(`SELECT set_config('request.jwt.claim.sub', '6c3e0000-0000-4000-8000-000000000003', false);
         SELECT public.submit_supply_request('6c3e0000-0000-4000-8000-000000000101', 'reorder', NULL, NULL, NULL,
           jsonb_build_array(jsonb_build_object('freeTextItem', 'Burst ' || n, 'quantity', 1))) FROM generate_series(1, 8) n`);
    const before = received.length;
    const runs = await Promise.all(
      [1, 2, 3].map(() => fetcher.scheduled({ cron, scheduledTime: new Date() })),
    );
    check(
      runs.every((run) => run.outcome === "ok"),
      "three overlapping scheduled() runs complete",
    );
    const burst = received.slice(before);
    const keys = new Set(burst.map((message) => message.idempotencyKey));
    check(
      burst.length === 24 && keys.size === 24,
      "8 submissions x 3 admins sent exactly once",
      `${burst.length} sent, ${keys.size} distinct`,
    );
    check(
      sql("SELECT count(*) FROM public.notification_deliveries WHERE status = 'processing'") ===
        "0",
      "no delivery left leased",
    );

    // 4. A later run sends nothing new (the retry is not due yet; nothing pending).
    const after = received.length;
    await fetcher.scheduled({ cron, scheduledTime: new Date() });
    check(received.length === after, "a repeated run sends nothing twice");
  } finally {
    await mf.dispose();
  }
} finally {
  server.close();
}
process.exit(failed ? 1 : 0);
