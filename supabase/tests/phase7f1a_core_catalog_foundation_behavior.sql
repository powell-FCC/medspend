-- Phase 7F.1A core multi-vendor catalog foundation: rollback-only behavior suite.
-- Run on a disposable database with every migration applied. Every failure is raised as
-- "Check N failed: ..." so the mutation check can tell a killed mutant from a setup error.
BEGIN;

SET LOCAL client_min_messages = warning;

-- Users: 001 owner A, 002 admin A, 003 staff A, 004 staff B, 005 owner B, 006 removed staff A,
-- 007 outsider, 008 staff C.
INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT ('7f1a0000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated', 'authenticated',
  'phase7f1a-' || n || '@example.invalid', '', now(), '{}', '{}', now(), now()
FROM generate_series(1, 8) n;

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('7f1a0000-0000-4000-8000-000000000101', 'Phase 7F.1A Org A', '7f1a0000-0000-4000-8000-000000000001'),
  ('7f1a0000-0000-4000-8000-000000000102', 'Phase 7F.1A Org B', '7f1a0000-0000-4000-8000-000000000005'),
  ('7f1a0000-0000-4000-8000-000000000103', 'Phase 7F.1A Org C', '7f1a0000-0000-4000-8000-000000000008');
INSERT INTO public.organization_memberships (organization_id, user_id, role, active) VALUES
  ('7f1a0000-0000-4000-8000-000000000101', '7f1a0000-0000-4000-8000-000000000001', 'owner', true),
  ('7f1a0000-0000-4000-8000-000000000101', '7f1a0000-0000-4000-8000-000000000002', 'admin', true),
  ('7f1a0000-0000-4000-8000-000000000101', '7f1a0000-0000-4000-8000-000000000003', 'staff', true),
  ('7f1a0000-0000-4000-8000-000000000102', '7f1a0000-0000-4000-8000-000000000004', 'staff', true),
  ('7f1a0000-0000-4000-8000-000000000102', '7f1a0000-0000-4000-8000-000000000005', 'owner', true),
  ('7f1a0000-0000-4000-8000-000000000101', '7f1a0000-0000-4000-8000-000000000006', 'staff', false),
  ('7f1a0000-0000-4000-8000-000000000103', '7f1a0000-0000-4000-8000-000000000008', 'owner', true);

-- Two global catalogs. Both list a creatine product, and both use the vendor SKU SHARED-1.
INSERT INTO public.catalog_vendors (id, name, normalized_name, active) VALUES
  ('7f1a0000-0000-4000-8000-000000000201', 'Catalog Vendor Alpha', 'x', true),
  ('7f1a0000-0000-4000-8000-000000000202', 'Catalog Vendor Beta', 'x', true);

INSERT INTO public.catalog_products (id, name, normalized_name, description, active, verification_status) VALUES
  ('7f1a0000-0000-4000-8000-000000000301', 'Creatine Monohydrate Alpha', 'x', 'Unflavored 500 g', true, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000302', 'Shared Sku Widget Alpha', 'x', NULL, true, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000303', 'Glacier Tape Alpha', 'x', NULL, true, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000311', 'Creatine Monohydrate Beta', 'x', 'Unflavored 1 kg', true, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000312', 'Shared Sku Widget Beta', 'x', NULL, true, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000313', 'Zephyr Brace Beta', 'x', NULL, true, 'verified');

INSERT INTO public.catalog_vendor_products (id, catalog_product_id, catalog_vendor_id, vendor_sku,
  normalized_vendor_sku, manufacturer_sku, package_quantity, package_unit, package_status, active,
  discontinued, verification_status) VALUES
  ('7f1a0000-0000-4000-8000-000000000401', '7f1a0000-0000-4000-8000-000000000301', '7f1a0000-0000-4000-8000-000000000201', 'KA-100', 'x', NULL, 1, 'tub', 'verified', true, false, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000402', '7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000201', 'SHARED-1', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000403', '7f1a0000-0000-4000-8000-000000000303', '7f1a0000-0000-4000-8000-000000000201', 'GT-300', 'x', 'GLACIER-MPN', NULL, NULL, 'unknown', true, false, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000411', '7f1a0000-0000-4000-8000-000000000311', '7f1a0000-0000-4000-8000-000000000202', 'KB-100', 'x', NULL, 1, 'tub', 'verified', true, false, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000412', '7f1a0000-0000-4000-8000-000000000312', '7f1a0000-0000-4000-8000-000000000202', 'SHARED-1', 'x', NULL, NULL, NULL, 'unknown', true, false, 'verified'),
  ('7f1a0000-0000-4000-8000-000000000413', '7f1a0000-0000-4000-8000-000000000313', '7f1a0000-0000-4000-8000-000000000202', 'ZB-900', 'x', 'ZEPHYR-MPN', NULL, NULL, 'unknown', true, false, 'verified');

-- Org A uses Alpha, Org B uses Beta, Org C's Alpha vendor is inactive.
INSERT INTO public.vendors (id, organization_id, name, active, catalog_vendor_id) VALUES
  ('7f1a0000-0000-4000-8000-000000000501', '7f1a0000-0000-4000-8000-000000000101', 'Alpha Supply', true, '7f1a0000-0000-4000-8000-000000000201'),
  ('7f1a0000-0000-4000-8000-000000000502', '7f1a0000-0000-4000-8000-000000000102', 'Beta Supply', true, '7f1a0000-0000-4000-8000-000000000202'),
  ('7f1a0000-0000-4000-8000-000000000503', '7f1a0000-0000-4000-8000-000000000103', 'Alpha Supply', false, '7f1a0000-0000-4000-8000-000000000201');
-- Org C's own (unlinked) product stays searchable.
INSERT INTO public.products (id, organization_id, name, approved, active, staff_requestable)
VALUES ('7f1a0000-0000-4000-8000-000000000601', '7f1a0000-0000-4000-8000-000000000103', 'Creatine House Blend', true, true, true);

INSERT INTO public.catalog_import_batches (id, catalog_vendor_id, source_name, source_version) VALUES
  ('7f1a0000-0000-4000-8000-000000000701', '7f1a0000-0000-4000-8000-000000000201', 'Alpha price list', '2026-11'),
  ('7f1a0000-0000-4000-8000-000000000702', '7f1a0000-0000-4000-8000-000000000202', 'Beta catalog', '2026-11');

-- ---------------------------------------------------------------------------------------
-- Check 1: brand uniqueness (normalized), no blank brands.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _normalized text;
BEGIN
  INSERT INTO public.catalog_brands (id, name, manufacturer_name)
  VALUES ('7f1a0000-0000-4000-8000-000000000801', 'Thorne', 'Thorne HealthTech');
  SELECT normalized_name INTO _normalized FROM public.catalog_brands WHERE id = '7f1a0000-0000-4000-8000-000000000801';
  IF _normalized IS DISTINCT FROM 'thorne' THEN
    RAISE EXCEPTION 'Check 1 failed: brand normalized name is %', _normalized;
  END IF;
  BEGIN
    INSERT INTO public.catalog_brands (name) VALUES ('  THORNE ');
    RAISE EXCEPTION 'Check 1 failed: duplicate normalized brand accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_brands (name) VALUES ('  ');
    RAISE EXCEPTION 'Check 1 failed: blank brand accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO public.catalog_brands (id, name) VALUES
    ('7f1a0000-0000-4000-8000-000000000802', 'Klean Athlete'),
    ('7f1a0000-0000-4000-8000-000000000803', 'Mueller');
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 2: concept and synonym uniqueness.
-- ---------------------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO public.catalog_concepts (id, name) VALUES
    ('7f1a0000-0000-4000-8000-000000000901', 'Creatine Monohydrate'),
    ('7f1a0000-0000-4000-8000-000000000902', 'Athletic Tape'),
    ('7f1a0000-0000-4000-8000-000000000903', 'Kinesiology Tape');
  BEGIN
    INSERT INTO public.catalog_concepts (name) VALUES ('creatine-monohydrate');
    RAISE EXCEPTION 'Check 2 failed: duplicate normalized concept accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  INSERT INTO public.catalog_concept_synonyms (concept_id, synonym) VALUES
    ('7f1a0000-0000-4000-8000-000000000901', 'creatine'),
    ('7f1a0000-0000-4000-8000-000000000902', 'tape'),
    ('7f1a0000-0000-4000-8000-000000000903', 'tape');
  BEGIN
    INSERT INTO public.catalog_concept_synonyms (concept_id, synonym)
    VALUES ('7f1a0000-0000-4000-8000-000000000901', 'CREATINE ');
    RAISE EXCEPTION 'Check 2 failed: duplicate synonym within a concept accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_concept_synonyms (concept_id, synonym)
    VALUES ('7f1a0000-0000-4000-8000-000000000901', '--');
    RAISE EXCEPTION 'Check 2 failed: blank synonym accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 3: product <-> concept is many-to-many with provenance rules.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _count integer;
BEGIN
  INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source, assigned_by) VALUES
    ('7f1a0000-0000-4000-8000-000000000301', '7f1a0000-0000-4000-8000-000000000901', 'manual', '7f1a0000-0000-4000-8000-000000000001');
  INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source, import_batch_id) VALUES
    ('7f1a0000-0000-4000-8000-000000000311', '7f1a0000-0000-4000-8000-000000000901', 'imported', '7f1a0000-0000-4000-8000-000000000702');
  INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source, rule_key) VALUES
    ('7f1a0000-0000-4000-8000-000000000303', '7f1a0000-0000-4000-8000-000000000902', 'deterministic_rule', 'tape.width_and_roll'),
    ('7f1a0000-0000-4000-8000-000000000303', '7f1a0000-0000-4000-8000-000000000903', 'deterministic_rule', 'tape.width_and_roll');
  SELECT count(*) INTO _count FROM public.catalog_product_concepts WHERE concept_id = '7f1a0000-0000-4000-8000-000000000901';
  IF _count <> 2 THEN RAISE EXCEPTION 'Check 3 failed: concept should hold 2 products, has %', _count; END IF;
  SELECT count(*) INTO _count FROM public.catalog_product_concepts WHERE catalog_product_id = '7f1a0000-0000-4000-8000-000000000303';
  IF _count <> 2 THEN RAISE EXCEPTION 'Check 3 failed: product should be in 2 concepts, is in %', _count; END IF;
  BEGIN
    INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source)
    VALUES ('7f1a0000-0000-4000-8000-000000000301', '7f1a0000-0000-4000-8000-000000000901', 'manual');
    RAISE EXCEPTION 'Check 3 failed: duplicate product-concept link accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source)
    VALUES ('7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000902', 'imported');
    RAISE EXCEPTION 'Check 3 failed: imported link without an import batch accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source)
    VALUES ('7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000902', 'deterministic_rule');
    RAISE EXCEPTION 'Check 3 failed: rule link without a rule key accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source, rule_key)
    VALUES ('7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000902', 'manual', 'tape.rule');
    RAISE EXCEPTION 'Check 3 failed: manual link carrying a rule key accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source)
    VALUES ('7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000902', 'ai');
    RAISE EXCEPTION 'Check 3 failed: unknown assignment source accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 4: concepts are never inferred from names, in either insertion order.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _count integer;
BEGIN
  INSERT INTO public.catalog_products (id, name, normalized_name, active, verification_status)
  VALUES ('7f1a0000-0000-4000-8000-000000000321', 'Creatine Monohydrate', 'x', true, 'verified');
  INSERT INTO public.catalog_concepts (id, name) VALUES ('7f1a0000-0000-4000-8000-000000000904', 'Glacier Tape Alpha');
  UPDATE public.catalog_products SET name = 'Athletic Tape' WHERE id = '7f1a0000-0000-4000-8000-000000000302';
  SELECT count(*) INTO _count FROM public.catalog_product_concepts
  WHERE catalog_product_id IN ('7f1a0000-0000-4000-8000-000000000321', '7f1a0000-0000-4000-8000-000000000302')
     OR concept_id = '7f1a0000-0000-4000-8000-000000000904';
  IF _count <> 0 THEN
    RAISE EXCEPTION 'Check 4 failed: % concept links were inferred from names', _count;
  END IF;
  UPDATE public.catalog_products SET name = 'Shared Sku Widget Alpha' WHERE id = '7f1a0000-0000-4000-8000-000000000302';
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 5: families are optional, explicit and unique per brand.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _count integer;
BEGIN
  SELECT count(*) INTO _count FROM public.catalog_products
  WHERE id::text LIKE '7f1a0000-%' AND family_id IS NOT NULL;
  IF _count <> 0 THEN RAISE EXCEPTION 'Check 5 failed: products received a family implicitly'; END IF;
  INSERT INTO public.catalog_product_families (id, brand_id, name, import_batch_id) VALUES
    ('7f1a0000-0000-4000-8000-000000000a01', '7f1a0000-0000-4000-8000-000000000802', 'Klean Isolate', '7f1a0000-0000-4000-8000-000000000701'),
    ('7f1a0000-0000-4000-8000-000000000a02', '7f1a0000-0000-4000-8000-000000000801', 'Isolate', NULL),
    ('7f1a0000-0000-4000-8000-000000000a03', NULL, 'Unbranded Kit', NULL);
  BEGIN
    INSERT INTO public.catalog_product_families (brand_id, name)
    VALUES ('7f1a0000-0000-4000-8000-000000000802', 'KLEAN isolate');
    RAISE EXCEPTION 'Check 5 failed: duplicate family within a brand accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_families (brand_id, name) VALUES (NULL, 'unbranded kit');
    RAISE EXCEPTION 'Check 5 failed: duplicate brandless family accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  INSERT INTO public.catalog_products (id, name, normalized_name, active, verification_status, brand_id, family_id, attributes) VALUES
    ('7f1a0000-0000-4000-8000-000000000331', 'Klean Isolate Vanilla', 'x', true, 'verified',
     '7f1a0000-0000-4000-8000-000000000802', '7f1a0000-0000-4000-8000-000000000a01', '{"flavor": "Vanilla", "servings": 20}'),
    ('7f1a0000-0000-4000-8000-000000000332', 'Klean Isolate Chocolate', 'x', true, 'verified',
     '7f1a0000-0000-4000-8000-000000000802', '7f1a0000-0000-4000-8000-000000000a01', '{"flavor": "Chocolate", "servings": 20}');
  SELECT count(*) INTO _count FROM public.catalog_products WHERE family_id = '7f1a0000-0000-4000-8000-000000000a01';
  IF _count <> 2 THEN RAISE EXCEPTION 'Check 5 failed: family members %', _count; END IF;
  BEGIN
    INSERT INTO public.catalog_products (name, normalized_name, active, verification_status, family_id)
    VALUES ('Orphan', 'x', true, 'verified', gen_random_uuid());
    RAISE EXCEPTION 'Check 5 failed: dangling family accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 6: attributes are preserved as given, default to {}, and never hold certifications.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _attributes jsonb;
BEGIN
  SELECT attributes INTO _attributes FROM public.catalog_products WHERE id = '7f1a0000-0000-4000-8000-000000000301';
  IF _attributes IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'Check 6 failed: default attributes %', _attributes; END IF;
  UPDATE public.catalog_products
  SET attributes = '{"size": "16 oz", "net_weight": {"value": 454, "unit": "g"}, "count": 90, "side": "left", "body_region": "ankle", "future_key": "kept"}'
  WHERE id = '7f1a0000-0000-4000-8000-000000000301';
  SELECT attributes INTO _attributes FROM public.catalog_products WHERE id = '7f1a0000-0000-4000-8000-000000000301';
  IF _attributes IS DISTINCT FROM '{"size": "16 oz", "net_weight": {"value": 454, "unit": "g"}, "count": 90, "side": "left", "body_region": "ankle", "future_key": "kept"}'::jsonb THEN
    RAISE EXCEPTION 'Check 6 failed: attributes changed on write: %', _attributes;
  END IF;
  BEGIN
    UPDATE public.catalog_products SET attributes = '["size"]' WHERE id = '7f1a0000-0000-4000-8000-000000000301';
    RAISE EXCEPTION 'Check 6 failed: non-object attributes accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET attributes = '{"certification": "nsf_certified_for_sport"}'
    WHERE id = '7f1a0000-0000-4000-8000-000000000301';
    RAISE EXCEPTION 'Check 6 failed: certification stored in attributes';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.catalog_products SET attributes = '{}' WHERE id = '7f1a0000-0000-4000-8000-000000000301';
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 7: MPN / GTIN are conservative lookup evidence, never unique identity.
-- ---------------------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    UPDATE public.catalog_products SET brand_id = '7f1a0000-0000-4000-8000-000000000803', normalized_mpn = 'MT-150', gtin = '012345678905'
    WHERE id IN ('7f1a0000-0000-4000-8000-000000000303', '7f1a0000-0000-4000-8000-000000000313');
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Check 7 failed: MPN or GTIN evidence was treated as unique identity: %', SQLERRM;
  END;
  IF (SELECT count(*) FROM public.catalog_products WHERE normalized_mpn = 'MT-150') <> 2 THEN
    RAISE EXCEPTION 'Check 7 failed: two products could not share brand + MPN evidence';
  END IF;
  BEGIN
    UPDATE public.catalog_products SET normalized_mpn = 'mt 150' WHERE id = '7f1a0000-0000-4000-8000-000000000303';
    RAISE EXCEPTION 'Check 7 failed: unnormalized MPN accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET brand_id = NULL WHERE id = '7f1a0000-0000-4000-8000-000000000303';
    RAISE EXCEPTION 'Check 7 failed: MPN without a brand accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET gtin = '12-34' WHERE id = '7f1a0000-0000-4000-8000-000000000303';
    RAISE EXCEPTION 'Check 7 failed: malformed GTIN accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET brand_id = gen_random_uuid() WHERE id = '7f1a0000-0000-4000-8000-000000000303';
    RAISE EXCEPTION 'Check 7 failed: dangling brand accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 8: certifications attach to an exact product with provenance.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _count integer;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'catalog_product_certifications'
               AND column_name IN ('brand_id', 'family_id', 'concept_id')) THEN
    RAISE EXCEPTION 'Check 8 failed: certifications can attach to something other than an exact product';
  END IF;
  INSERT INTO public.catalog_product_certifications (id, catalog_product_id, certification_code, import_batch_id, evidence_url, verified_at, expires_at)
  VALUES ('7f1a0000-0000-4000-8000-000000000b01', '7f1a0000-0000-4000-8000-000000000331', 'nsf_certified_for_sport',
          '7f1a0000-0000-4000-8000-000000000701', 'https://example.invalid/nsf/klean-isolate-vanilla', now(), now() + interval '1 year');
  -- The sibling flavor is not certified by its family or brand.
  SELECT count(*) INTO _count FROM public.catalog_product_certifications WHERE catalog_product_id = '7f1a0000-0000-4000-8000-000000000332';
  IF _count <> 0 THEN RAISE EXCEPTION 'Check 8 failed: certification spread to a sibling variant'; END IF;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, verified_at)
    VALUES ('7f1a0000-0000-4000-8000-000000000332', 'nsf_certified_for_sport', now());
    RAISE EXCEPTION 'Check 8 failed: certification without evidence accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at)
    VALUES (NULL, 'nsf_certified_for_sport', 'NSF listing 123', now());
    RAISE EXCEPTION 'Check 8 failed: certification without a product accepted';
  EXCEPTION WHEN not_null_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference)
    VALUES ('7f1a0000-0000-4000-8000-000000000332', 'nsf_certified_for_sport', 'NSF listing 123');
    RAISE EXCEPTION 'Check 8 failed: certification without verified_at accepted';
  EXCEPTION WHEN not_null_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at)
    VALUES ('7f1a0000-0000-4000-8000-000000000332', 'invented_badge', 'x', now());
    RAISE EXCEPTION 'Check 8 failed: unknown certification type accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at)
    VALUES ('7f1a0000-0000-4000-8000-000000000331', 'nsf_certified_for_sport', 'second active', now());
    RAISE EXCEPTION 'Check 8 failed: two active certifications of one type accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at, expires_at)
    VALUES ('7f1a0000-0000-4000-8000-000000000332', 'nsf_certified_for_sport', 'x', now(), now() - interval '1 day');
    RAISE EXCEPTION 'Check 8 failed: expiry before verification accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Superseding keeps the old fact.
  UPDATE public.catalog_product_certifications SET active = false WHERE id = '7f1a0000-0000-4000-8000-000000000b01';
  INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at)
  VALUES ('7f1a0000-0000-4000-8000-000000000331', 'nsf_certified_for_sport', 'NSF listing renewed', now());
  SELECT count(*) INTO _count FROM public.catalog_product_certifications WHERE catalog_product_id = '7f1a0000-0000-4000-8000-000000000331';
  IF _count <> 2 THEN RAISE EXCEPTION 'Check 8 failed: superseded certification not retained'; END IF;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 9: bundle metadata.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _kind text;
BEGIN
  SELECT product_kind INTO _kind FROM public.catalog_products WHERE id = '7f1a0000-0000-4000-8000-000000000301';
  IF _kind IS DISTINCT FROM 'single' THEN RAISE EXCEPTION 'Check 9 failed: default product kind %', _kind; END IF;
  BEGIN
    INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal, component_text)
    VALUES ('7f1a0000-0000-4000-8000-000000000301', 1, 'Scoop');
    RAISE EXCEPTION 'Check 9 failed: components on a single product accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET product_kind = 'kit' WHERE id = '7f1a0000-0000-4000-8000-000000000301';
    RAISE EXCEPTION 'Check 9 failed: unknown product kind accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO public.catalog_products (id, name, normalized_name, active, verification_status, product_kind)
  VALUES ('7f1a0000-0000-4000-8000-000000000341', 'Recovery Stack', 'x', true, 'verified', 'bundle');
  INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal, component_catalog_product_id, component_text, quantity) VALUES
    ('7f1a0000-0000-4000-8000-000000000341', 1, '7f1a0000-0000-4000-8000-000000000301', NULL, 1),
    ('7f1a0000-0000-4000-8000-000000000341', 2, NULL, 'Unresolved electrolyte sticks', NULL);
  BEGIN
    INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal) VALUES ('7f1a0000-0000-4000-8000-000000000341', 3);
    RAISE EXCEPTION 'Check 9 failed: empty component accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal, component_catalog_product_id)
    VALUES ('7f1a0000-0000-4000-8000-000000000341', 3, '7f1a0000-0000-4000-8000-000000000341');
    RAISE EXCEPTION 'Check 9 failed: bundle containing itself accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal, component_text, quantity)
    VALUES ('7f1a0000-0000-4000-8000-000000000341', 3, 'x', 0);
    RAISE EXCEPTION 'Check 9 failed: zero quantity accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET product_kind = 'single' WHERE id = '7f1a0000-0000-4000-8000-000000000341';
    RAISE EXCEPTION 'Check 9 failed: bundle with components turned single';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  -- Metadata only: no inventory, product or request rows appeared.
  IF EXISTS (SELECT 1 FROM public.products WHERE catalog_product_id IN ('7f1a0000-0000-4000-8000-000000000341', '7f1a0000-0000-4000-8000-000000000301')) THEN
    RAISE EXCEPTION 'Check 9 failed: bundle metadata created organization products';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 10: purchase restriction values.
-- ---------------------------------------------------------------------------------------
DO $$
DECLARE _value text;
BEGIN
  SELECT purchase_restriction INTO _value FROM public.catalog_products WHERE id = '7f1a0000-0000-4000-8000-000000000301';
  IF _value IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'Check 10 failed: default restriction %', _value; END IF;
  FOREACH _value IN ARRAY ARRAY['none', 'licensed_professional', 'prescription', 'restricted', 'unknown'] LOOP
    UPDATE public.catalog_products SET purchase_restriction = _value WHERE id = '7f1a0000-0000-4000-8000-000000000313';
  END LOOP;
  BEGIN
    UPDATE public.catalog_products SET purchase_restriction = 'controlled' WHERE id = '7f1a0000-0000-4000-8000-000000000313';
    RAISE EXCEPTION 'Check 10 failed: unknown restriction accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_products SET purchase_restriction = NULL WHERE id = '7f1a0000-0000-4000-8000-000000000313';
    RAISE EXCEPTION 'Check 10 failed: NULL restriction accepted';
  EXCEPTION WHEN not_null_violation THEN NULL;
  END;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 11: listing availability is source-observed and never changes search eligibility.
-- ---------------------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    UPDATE public.catalog_vendor_products SET availability_status = 'in_stock' WHERE id = '7f1a0000-0000-4000-8000-000000000401';
    RAISE EXCEPTION 'Check 11 failed: availability without an observation time accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_vendor_products SET availability_status = 'plenty', availability_observed_at = now()
    WHERE id = '7f1a0000-0000-4000-8000-000000000401';
    RAISE EXCEPTION 'Check 11 failed: unknown availability accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_vendor_products SET listing_url = 'ftp://example.invalid/x' WHERE id = '7f1a0000-0000-4000-8000-000000000401';
    RAISE EXCEPTION 'Check 11 failed: non-http listing URL accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.catalog_vendor_products
  SET availability_status = 'out_of_stock', availability_observed_at = now() - interval '3 days',
      listing_url = 'https://example.invalid/ka-100'
  WHERE id = '7f1a0000-0000-4000-8000-000000000401';
END
$$;

-- ---------------------------------------------------------------------------------------
-- Check 12: provenance fields on listings and batches.
-- ---------------------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE public.catalog_vendor_products SET last_seen_batch_id = '7f1a0000-0000-4000-8000-000000000701', last_seen_at = now()
  WHERE id = '7f1a0000-0000-4000-8000-000000000401';
  BEGIN
    UPDATE public.catalog_vendor_products SET last_seen_batch_id = '7f1a0000-0000-4000-8000-000000000702', last_seen_at = now()
    WHERE id = '7f1a0000-0000-4000-8000-000000000402';
    RAISE EXCEPTION 'Check 12 failed: another catalog vendor''s batch accepted as last seen';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.catalog_vendor_products SET last_seen_batch_id = '7f1a0000-0000-4000-8000-000000000701'
    WHERE id = '7f1a0000-0000-4000-8000-000000000402';
    RAISE EXCEPTION 'Check 12 failed: last seen batch without a time accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.catalog_import_batches SET source_type = 'pdf', effective_date = DATE '2026-10-01'
  WHERE id = '7f1a0000-0000-4000-8000-000000000702';
  BEGIN
    UPDATE public.catalog_import_batches SET source_type = 'fax' WHERE id = '7f1a0000-0000-4000-8000-000000000701';
    RAISE EXCEPTION 'Check 12 failed: unknown source type accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  IF (SELECT source_type FROM public.catalog_import_batches WHERE id = '7f1a0000-0000-4000-8000-000000000701') IS NOT NULL
     OR (SELECT effective_date FROM public.catalog_import_batches WHERE id = '7f1a0000-0000-4000-8000-000000000701') IS NOT NULL THEN
    RAISE EXCEPTION 'Check 12 failed: batch provenance was guessed';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------------------
-- Checks 13-17 run as signed-in users.
-- ---------------------------------------------------------------------------------------
SET LOCAL ROLE authenticated;

-- Check 13: staff A sees only catalog Alpha; staff B only Beta.
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000003', true);
DO $$
DECLARE _ids uuid[]; _row record;
BEGIN
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'creatine', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000401']::uuid[] THEN
    RAISE EXCEPTION 'Check 13 failed: staff A creatine results %', _ids;
  END IF;
  -- An exact SKU of the other catalog finds nothing.
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'KB-100', 50)) THEN
    RAISE EXCEPTION 'Check 13 failed: staff A found catalog Beta by SKU';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'ZEPHYR-MPN', 50)) THEN
    RAISE EXCEPTION 'Check 13 failed: staff A found catalog Beta by manufacturer SKU';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'zephyr', 50)) THEN
    RAISE EXCEPTION 'Check 13 failed: staff A found catalog Beta by name';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'ZB-9', 50)) THEN
    RAISE EXCEPTION 'Check 13 failed: staff A found catalog Beta by partial SKU';
  END IF;
  -- A vendor SKU both catalogs use returns only Alpha's listing.
  SELECT array_agg(catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'SHARED-1', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000402']::uuid[] THEN
    RAISE EXCEPTION 'Check 13 failed: staff A shared SKU results %', _ids;
  END IF;
  -- Alpha results keep their 5A.10 tiers and columns.
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals('7f1a0000-0000-4000-8000-000000000101', 'KA-100', 5);
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '7f1a0000-0000-4000-8000-000000000401'::uuid
     OR _row.match_tier <> 1 OR _row.identity_source <> 'global_catalog' OR _row.vendor_name <> 'Catalog Vendor Alpha'
     OR _row.package_display <> '1 tub' THEN
    RAISE EXCEPTION 'Check 13 failed: Alpha exact SKU row changed: % % % %', _row.catalog_vendor_product_id, _row.match_tier, _row.identity_source, _row.package_display;
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals('7f1a0000-0000-4000-8000-000000000101', 'glacier tape alpha', 5);
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '7f1a0000-0000-4000-8000-000000000403'::uuid OR _row.match_tier <> 2 THEN
    RAISE EXCEPTION 'Check 13 failed: Alpha exact name tier %', _row.match_tier;
  END IF;
  SELECT * INTO _row FROM public.search_supply_request_products_with_signals('7f1a0000-0000-4000-8000-000000000101', 'glacer', 5);
  IF _row.catalog_vendor_product_id IS DISTINCT FROM '7f1a0000-0000-4000-8000-000000000403'::uuid OR _row.match_tier <> 7 THEN
    RAISE EXCEPTION 'Check 13 failed: Alpha typo correction tier %', _row.match_tier;
  END IF;
  -- Availability metadata never removes a listing; out_of_stock KA-100 still appears.
END
$$;

SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000004', true);
DO $$
DECLARE _ids uuid[];
BEGIN
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'creatine', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000411']::uuid[] THEN
    RAISE EXCEPTION 'Check 13 failed: staff B creatine results %', _ids;
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'KA-100', 50))
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'GLACIER-MPN', 50))
     OR EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'glacier', 50)) THEN
    RAISE EXCEPTION 'Check 13 failed: staff B found catalog Alpha';
  END IF;
  SELECT array_agg(catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products_with_signals('7f1a0000-0000-4000-8000-000000000102', 'SHARED-1', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000412']::uuid[] THEN
    RAISE EXCEPTION 'Check 13 failed: staff B shared SKU results %', _ids;
  END IF;
END
$$;

-- Check 14: owners and admins follow the same rule; an inactive linked vendor enables nothing.
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000001', true);
DO $$
DECLARE _ids uuid[];
BEGIN
  SELECT array_agg(catalog_vendor_product_id ORDER BY catalog_vendor_product_id) INTO _ids
  FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'creatine', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000401']::uuid[] THEN
    RAISE EXCEPTION 'Check 14 failed: owner A creatine results %', _ids;
  END IF;
END
$$;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000002', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'KB-100', 50)) THEN
    RAISE EXCEPTION 'Check 14 failed: admin A found catalog Beta';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'KA-100', 50)) THEN
    RAISE EXCEPTION 'Check 14 failed: admin A lost catalog Alpha';
  END IF;
END
$$;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000005', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'KA-100', 50)) THEN
    RAISE EXCEPTION 'Check 14 failed: owner B found catalog Alpha';
  END IF;
END
$$;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000008', true);
DO $$
DECLARE _ids uuid[]; _sources text[];
BEGIN
  SELECT array_agg(product_id), array_agg(identity_source) INTO _ids, _sources
  FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000103', 'creatine', 50);
  IF _ids IS DISTINCT FROM ARRAY['7f1a0000-0000-4000-8000-000000000601']::uuid[] OR _sources <> ARRAY['organization_product'] THEN
    RAISE EXCEPTION 'Check 14 failed: org C (inactive vendor link) results % %', _ids, _sources;
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000103', 'KA-100', 50)) THEN
    RAISE EXCEPTION 'Check 14 failed: an inactive linked vendor enabled its catalog';
  END IF;
END
$$;

-- Check 15: removed members, outsiders and anon cannot search.
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000006', true);
DO $$
BEGIN
  PERFORM 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'creatine', 50);
  RAISE EXCEPTION 'Check 15 failed: removed member searched';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END
$$;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000003', true);
DO $$
BEGIN
  PERFORM 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000102', 'creatine', 50);
  RAISE EXCEPTION 'Check 15 failed: staff A searched org B';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END
$$;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000007', true);
DO $$
BEGIN
  PERFORM 1 FROM public.search_supply_request_products_with_signals('7f1a0000-0000-4000-8000-000000000101', 'creatine', 50);
  RAISE EXCEPTION 'Check 15 failed: outsider searched';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END
$$;

-- Check 16: Saved Items and discovery follow the same catalog scope.
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000003', true);
DO $$
DECLARE _payload text;
BEGIN
  BEGIN
    PERFORM public.save_staff_product('7f1a0000-0000-4000-8000-000000000101', NULL, '7f1a0000-0000-4000-8000-000000000411', NULL);
    RAISE EXCEPTION 'Check 16 failed: staff A saved a catalog Beta listing';
  EXCEPTION WHEN no_data_found THEN NULL;
  END;
  PERFORM public.save_staff_product('7f1a0000-0000-4000-8000-000000000101', NULL, '7f1a0000-0000-4000-8000-000000000401', NULL);
  SELECT string_agg(discovery::text, ' | ') INTO _payload
  FROM public.get_staff_product_discovery('7f1a0000-0000-4000-8000-000000000101', 10) discovery;
  IF _payload NOT LIKE '%7f1a0000-0000-4000-8000-000000000401%' OR _payload LIKE '%7f1a0000-0000-4000-8000-000000000411%' THEN
    RAISE EXCEPTION 'Check 16 failed: discovery payload %', _payload;
  END IF;
END
$$;

-- Check 17: global facts are readable; no organization user can write them.
DO $$
DECLARE _count integer;
BEGIN
  SELECT count(*) INTO _count FROM public.catalog_brands WHERE id::text LIKE '7f1a0000-%';
  IF _count <> 3 THEN RAISE EXCEPTION 'Check 17 failed: brands not readable (%)', _count; END IF;
  SELECT count(*) INTO _count FROM public.catalog_concepts WHERE id::text LIKE '7f1a0000-%';
  IF _count <> 4 THEN RAISE EXCEPTION 'Check 17 failed: concepts not readable (%)', _count; END IF;
  PERFORM 1 FROM public.catalog_concept_synonyms;
  PERFORM 1 FROM public.catalog_product_concepts;
  PERFORM 1 FROM public.catalog_product_families;
  PERFORM 1 FROM public.catalog_certification_types;
  PERFORM 1 FROM public.catalog_product_certifications;
  PERFORM 1 FROM public.catalog_bundle_components;
  PERFORM brand_id, normalized_mpn, gtin, family_id, attributes, product_kind, purchase_restriction FROM public.catalog_products LIMIT 1;
  PERFORM listing_url, availability_status, availability_observed_at, last_seen_at FROM public.catalog_vendor_products LIMIT 1;
END
$$;
DO $$
DECLARE _statement text; _failed text := '';
BEGIN
  FOREACH _statement IN ARRAY ARRAY[
    $s$INSERT INTO public.catalog_brands (name) VALUES ('Forged Brand')$s$,
    $s$UPDATE public.catalog_brands SET name = 'Renamed' WHERE id = '7f1a0000-0000-4000-8000-000000000801'$s$,
    $s$DELETE FROM public.catalog_brands WHERE id = '7f1a0000-0000-4000-8000-000000000803'$s$,
    $s$INSERT INTO public.catalog_concepts (name) VALUES ('Forged Concept')$s$,
    $s$INSERT INTO public.catalog_concept_synonyms (concept_id, synonym) VALUES ('7f1a0000-0000-4000-8000-000000000901', 'forged')$s$,
    $s$INSERT INTO public.catalog_product_concepts (catalog_product_id, concept_id, assignment_source) VALUES ('7f1a0000-0000-4000-8000-000000000302', '7f1a0000-0000-4000-8000-000000000901', 'manual')$s$,
    $s$DELETE FROM public.catalog_product_concepts$s$,
    $s$INSERT INTO public.catalog_product_families (name) VALUES ('Forged Family')$s$,
    $s$INSERT INTO public.catalog_certification_types (code, name) VALUES ('forged_badge', 'Forged')$s$,
    $s$INSERT INTO public.catalog_product_certifications (catalog_product_id, certification_code, evidence_reference, verified_at) VALUES ('7f1a0000-0000-4000-8000-000000000332', 'nsf_certified_for_sport', 'forged', now())$s$,
    $s$UPDATE public.catalog_product_certifications SET active = true$s$,
    $s$INSERT INTO public.catalog_bundle_components (bundle_catalog_product_id, ordinal, component_text) VALUES ('7f1a0000-0000-4000-8000-000000000341', 9, 'forged')$s$,
    $s$UPDATE public.catalog_products SET brand_id = '7f1a0000-0000-4000-8000-000000000801' WHERE id = '7f1a0000-0000-4000-8000-000000000301'$s$,
    $s$UPDATE public.catalog_products SET family_id = '7f1a0000-0000-4000-8000-000000000a01' WHERE id = '7f1a0000-0000-4000-8000-000000000301'$s$,
    $s$UPDATE public.catalog_vendor_products SET availability_status = 'in_stock', availability_observed_at = now()$s$,
    $s$UPDATE public.catalog_vendor_products SET source_catalog_price = 1$s$,
    $s$UPDATE public.catalog_import_batches SET source_type = 'manual'$s$
  ] LOOP
    BEGIN
      EXECUTE _statement;
      _failed := _failed || ' | ' || _statement;
    EXCEPTION
      WHEN insufficient_privilege THEN NULL;
      -- Any other error means the write got past the privilege layer.
      WHEN OTHERS THEN _failed := _failed || ' | ' || _statement || ' (' || SQLERRM || ')';
    END;
  END LOOP;
  IF _failed <> '' THEN RAISE EXCEPTION 'Check 17 failed: authenticated wrote global catalog facts:%', _failed; END IF;
END
$$;

RESET ROLE;

-- Check 18: anon reads and executes nothing; service_role writes the global facts.
SET LOCAL ROLE anon;
DO $$
DECLARE _statement text; _failed text := '';
BEGIN
  FOREACH _statement IN ARRAY ARRAY[
    'SELECT 1 FROM public.catalog_brands', 'SELECT 1 FROM public.catalog_concepts',
    'SELECT 1 FROM public.catalog_concept_synonyms', 'SELECT 1 FROM public.catalog_product_concepts',
    'SELECT 1 FROM public.catalog_product_families', 'SELECT 1 FROM public.catalog_certification_types',
    'SELECT 1 FROM public.catalog_product_certifications', 'SELECT 1 FROM public.catalog_bundle_components',
    $s$SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000101', 'creatine', 5)$s$,
    $s$SELECT 1 FROM public.supply_request_product_search('7f1a0000-0000-4000-8000-000000000101', 'creatine', 5)$s$,
    $s$SELECT 1 FROM public.supply_request_product_identities('7f1a0000-0000-4000-8000-000000000101', NULL, NULL, NULL)$s$
  ] LOOP
    BEGIN
      EXECUTE _statement;
      _failed := _failed || ' | ' || _statement;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  IF _failed <> '' THEN RAISE EXCEPTION 'Check 18 failed: anon reached:%', _failed; END IF;
END
$$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM 1 FROM public.supply_request_product_search('7f1a0000-0000-4000-8000-000000000101', 'creatine', 5);
  RAISE EXCEPTION 'Check 18 failed: authenticated called the internal search directly';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END
$$;
DO $$
BEGIN
  PERFORM 1 FROM public.supply_request_product_identities('7f1a0000-0000-4000-8000-000000000101', NULL, ARRAY['7f1a0000-0000-4000-8000-000000000411']::uuid[], NULL);
  RAISE EXCEPTION 'Check 18 failed: authenticated called the internal identities directly';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END
$$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  INSERT INTO public.catalog_brands (name) VALUES ('Momentous');
  INSERT INTO public.catalog_concepts (name) VALUES ('Cohesive Wrap');
  UPDATE public.catalog_products SET purchase_restriction = 'none' WHERE id = '7f1a0000-0000-4000-8000-000000000301';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE EXCEPTION 'Check 18 failed: service_role cannot write global catalog facts';
END
$$;
RESET ROLE;

-- Check 19: enabling a catalog vendor through the existing link RPC is the only switch.
DO $$
BEGIN
  UPDATE public.vendors SET active = true WHERE id = '7f1a0000-0000-4000-8000-000000000503';
END
$$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '7f1a0000-0000-4000-8000-000000000008', true);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000103', 'KA-100', 50)) THEN
    RAISE EXCEPTION 'Check 19 failed: reactivated linked vendor did not enable its catalog';
  END IF;
  IF EXISTS (SELECT 1 FROM public.search_supply_request_products('7f1a0000-0000-4000-8000-000000000103', 'KB-100', 50)) THEN
    RAISE EXCEPTION 'Check 19 failed: org C found catalog Beta';
  END IF;
  -- Organization users cannot link a catalog vendor by writing the column directly.
  BEGIN
    UPDATE public.vendors SET catalog_vendor_id = '7f1a0000-0000-4000-8000-000000000202'
    WHERE id = '7f1a0000-0000-4000-8000-000000000503';
    RAISE EXCEPTION 'Check 19 failed: owner relinked a vendor directly';
  EXCEPTION WHEN insufficient_privilege OR raise_exception THEN
    IF SQLERRM LIKE 'Check 19 failed%' THEN RAISE; END IF;
  END;
END
$$;
RESET ROLE;

-- Check 20: no organization data was created or changed by catalog facts.
DO $$
BEGIN
  IF (SELECT count(*) FROM public.products WHERE organization_id::text LIKE '7f1a0000-%') <> 1
     OR EXISTS (SELECT 1 FROM public.vendor_products WHERE organization_id::text LIKE '7f1a0000-%') THEN
    RAISE EXCEPTION 'Check 20 failed: catalog foundation writes created organization rows';
  END IF;
END
$$;

ROLLBACK;
