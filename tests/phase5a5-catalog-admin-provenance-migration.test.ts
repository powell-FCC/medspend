import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260831130000_phase5a5_catalog_admin_provenance.sql", root),
  "utf8",
);
const verification = await readFile(
  new URL("supabase/verification/phase5a5_catalog_admin_provenance.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a5_catalog_admin_provenance_behavior.sql", root),
  "utf8",
);

const body = migration.match(/AS \$\$([\s\S]*?)\n\$\$;/)?.[1];
const returnedJsonKeys = [...migration.matchAll(/'([A-Za-z][A-Za-z0-9]*)'\s*,/g)]
  .map((match) => match[1])
  .sort();
const expectedJsonKeys = [
  "active",
  "active",
  "active",
  "catalogVendorProductId",
  "description",
  "discontinued",
  "effectiveFrom",
  "evidenceStatus",
  "id",
  "id",
  "lifecycle",
  "manufacturer",
  "manufacturerSku",
  "name",
  "name",
  "normalizedVendorSku",
  "overrideType",
  "package",
  "product",
  "productionRule",
  "provenance",
  "rawDescription",
  "rawPackage",
  "rawProductName",
  "rawVariant",
  "rawVendorSku",
  "sourceName",
  "sourceName",
  "sourcePage",
  "sourceVendorSku",
  "sourceVersion",
  "sourceVersion",
  "status",
  "vendor",
  "vendorSku",
  "verificationOverrides",
  "verificationStatus",
  "verificationStatus",
  "verifiedQuantity",
  "verifiedUnit",
  "verifiedVendorSku",
  "website",
].sort();

test("Phase 5A.5 catalog provenance RPC is exact, stable, and owner/admin protected", () => {
  assert.ok(body);
  assert.match(
    migration,
    /CREATE OR REPLACE FUNCTION public\.get_catalog_vendor_product_admin_detail\(\s*_organization_id uuid,\s*_catalog_vendor_product_id uuid\s*\)/,
  );
  assert.match(migration, /RETURNS jsonb[\s\S]*?LANGUAGE plpgsql[\s\S]*?STABLE/);
  assert.match(migration, /SECURITY DEFINER[\s\S]*?SET search_path = public/);
  assert.match(body, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(body, /USING ERRCODE = '42501'/);

  const authorizationAt = body.indexOf("public.is_org_admin");
  const protectedReadAt = Math.min(
    ...[
      "public.catalog_vendor_products",
      "public.catalog_products",
      "public.catalog_vendors",
      "public.catalog_source_records",
      "public.catalog_import_batches",
      "public.catalog_verification_overrides",
    ].map((table) => body.indexOf(table)),
  );
  assert.ok(authorizationAt >= 0 && authorizationAt < protectedReadAt);
});

test("Phase 5A.5 catalog provenance RPC reads only the exact global allowlist", () => {
  assert.ok(body);
  const readTables = [...body.matchAll(/\b(?:FROM|JOIN)\s+public\.([a-z_]+)/gi)].map(
    (match) => match[1],
  );
  assert.deepEqual([...new Set(readTables)].sort(), [
    "catalog_import_batches",
    "catalog_products",
    "catalog_source_records",
    "catalog_vendor_products",
    "catalog_vendors",
    "catalog_verification_overrides",
  ]);
  assert.doesNotMatch(
    body,
    /\bpublic\.(?:inventory|organizations?|organization_|vendors|products|vendor_products)\b/i,
  );
  assert.match(
    body,
    /source_record\.matched_catalog_vendor_product_id = catalog_vendor_product\.id/,
  );
  assert.match(
    body,
    /verification_override\.catalog_vendor_product_id = catalog_vendor_product\.id/,
  );
});

test("Phase 5A.5 catalog provenance RPC has an exact sanitized return allowlist", () => {
  assert.deepEqual(returnedJsonKeys, expectedJsonKeys);

  for (const restrictedField of [
    "raw_data",
    "evidence",
    "created_by",
    "artifact_name",
    "artifact_sha256",
    "metadata",
    "notes",
    "source_uri",
  ]) {
    assert.doesNotMatch(migration, new RegExp(`\\b${restrictedField}\\b`));
  }

  for (const restrictedJsonKey of [
    "artifactName",
    "artifactSha256",
    "createdBy",
    "evidence",
    "metadata",
    "notes",
    "rawData",
    "resolutionStatus",
    "secret",
    "sourceOrdinal",
    "sourceUri",
    "token",
  ]) {
    assert.ok(!returnedJsonKeys.includes(restrictedJsonKey));
  }
});

test("Phase 5A.5 catalog provenance RPC exposes normalized package data only when verified", () => {
  assert.ok(body);
  assert.match(
    body,
    /'verifiedQuantity', CASE\s+WHEN catalog_vendor_product\.package_status = 'verified'\s+THEN catalog_vendor_product\.package_quantity\s+ELSE NULL\s+END/,
  );
  assert.match(
    body,
    /'verifiedUnit', CASE\s+WHEN catalog_vendor_product\.package_status = 'verified'\s+THEN catalog_vendor_product\.package_unit\s+ELSE NULL\s+END/,
  );
  assert.match(body, /'rawDescription', catalog_vendor_product\.package_description/);
});

test("Phase 5A.5 catalog provenance migration is read-only with exact function ACLs", () => {
  assert.ok(body);
  assert.doesNotMatch(body, /\b(?:INSERT|UPDATE|DELETE|TRUNCATE|MERGE|COPY|CALL|EXECUTE)\b/i);
  assert.doesNotMatch(migration, /\b(?:GRANT|REVOKE)\b[\s\S]*?\bON TABLE\b/i);
  assert.doesNotMatch(
    migration,
    /\b(?:ALTER TABLE|CREATE TABLE|DROP TABLE|CREATE POLICY|CREATE TRIGGER|CREATE INDEX)\b/i,
  );
  assert.equal(migration.match(/CREATE OR REPLACE FUNCTION/g)?.length, 1);
  assert.equal(migration.match(/\bGRANT EXECUTE ON FUNCTION\b/g)?.length, 1);
  assert.equal(migration.match(/\bREVOKE EXECUTE ON FUNCTION\b/g)?.length, 2);
  assert.match(
    migration,
    /REVOKE EXECUTE ON FUNCTION public\.get_catalog_vendor_product_admin_detail\(uuid, uuid\) FROM anon;/,
  );
  assert.match(
    migration,
    /REVOKE EXECUTE ON FUNCTION public\.get_catalog_vendor_product_admin_detail\(uuid, uuid\) FROM PUBLIC;/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.get_catalog_vendor_product_admin_detail\(uuid, uuid\) TO authenticated;/,
  );
  assert.doesNotMatch(migration, /SUPABASE_SERVICE_ROLE_KEY|service[_-]?role credential/i);
});

test("Phase 5A.5 catalog provenance verification is one strict read-only PASS-FAIL query", () => {
  const executable = verification.replace(/^\s*--.*$/gm, "").trim();
  const structure = executable.replace(/'(?:''|[^'])*'/gs, "''");
  assert.match(executable, /^WITH\b/);
  assert.equal(structure.match(/;/g)?.length, 1);
  assert.doesNotMatch(
    structure,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL|DO)\b/im,
  );
  assert.match(
    verification,
    /procedure\.oid = pg_catalog\.to_regprocedure\(\s*'public\.get_catalog_vendor_product_admin_detail\(uuid,uuid\)'\s*\)/,
  );
  assert.match(verification, /expected_json_keys/);
  assert.match(verification, /sensitive_json_keys/);
  assert.match(verification, /restricted_table_acl/);
  assert.match(verification, /pg_catalog\.has_table_privilege/);
  assert.match(
    verification,
    /authenticated_can_execute[\s\S]*?AND NOT anon_can_execute[\s\S]*?AND NOT public_can_execute/,
  );

  for (const check of [
    "rpc_exists_with_exact_signature",
    "rpc_security_definer",
    "rpc_stable",
    "rpc_search_path_hardened",
    "security_definer_schema_not_client_writable",
    "rpc_authenticated_execute_only",
    "restricted_provenance_tables_remain_client_inaccessible",
    "rpc_owner_admin_authorization_present",
    "rpc_authorization_precedes_protected_access",
    "rpc_function_body_is_read_only",
    "rpc_returned_field_footprint_exact",
    "rpc_sensitive_fields_not_exposed",
    "rpc_named_schema_footprint_exact",
  ]) {
    assert.match(verification, new RegExp(`'${check}'`));
  }
});

test("Phase 5A.5 catalog provenance behavioral SQL is SQL-Editor compatible and rollback-only", () => {
  assert.match(behavior, /^\s*--[\s\S]*?\bBEGIN;/);
  assert.doesNotMatch(behavior, /^\s*\\/m);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  assert.doesNotMatch(behavior, /\bCREATE\s+(?:TEMP|TEMPORARY)\b/i);
  assert.doesNotMatch(behavior, /set_config\([\s\S]*?,\s*false\s*\)/i);
  assert.equal(behavior.match(/\bROLLBACK;/gi)?.length, 1);

  const rollbackAt = behavior.search(/\bROLLBACK;/i);
  const postRollback = behavior.slice(rollbackAt + "ROLLBACK;".length);
  assert.match(postRollback, /phase5a5_provenance_no_persistence/);
  assert.doesNotMatch(
    postRollback,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL)\b/im,
  );
});

test("Phase 5A.5 catalog provenance behavioral SQL covers roles, isolation, sanitization, and immutability", () => {
  assert.match(behavior, /SET LOCAL ROLE authenticated;/);
  assert.match(behavior, /SET LOCAL ROLE anon;/);
  for (const roleMarker of [
    "Provenance Owner",
    "Provenance Admin",
    "Provenance Staff",
    "Provenance Other Owner",
  ]) {
    assert.match(behavior, new RegExp(roleMarker));
  }
  assert.match(behavior, /Staff provenance access unexpectedly succeeded/);
  assert.match(behavior, /Anonymous provenance access unexpectedly succeeded/);
  assert.match(behavior, /Cross-organization provenance access unexpectedly succeeded/);
  assert.match(behavior, /Null organization provenance access unexpectedly succeeded/);
  assert.match(behavior, /Owner and admin received different provenance payloads/);
  assert.match(behavior, /Top-level provenance payload keys were not exact/);
  assert.match(behavior, /Source-only package data masqueraded as verified/);
  assert.match(behavior, /Requested source catalog\/version\/raw text was not preserved/);
  assert.match(behavior, /Active verification decision was not returned correctly/);
  assert.match(behavior, /Sensitive, inactive, or unrelated provenance leaked/);
  assert.match(behavior, /_global_rows_before jsonb/);
  assert.match(behavior, /_global_rows_after jsonb/);
  assert.match(behavior, /_organization_rows_before jsonb/);
  assert.match(behavior, /_organization_rows_after jsonb/);
  assert.match(behavior, /Provenance RPC mutated a global catalog or provenance table/);
  assert.match(behavior, /Provenance RPC mutated an organization or inventory table/);
  assert.match(behavior, /rollback-only test left persistent fixture rows/);
});
