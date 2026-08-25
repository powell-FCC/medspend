-- Read-only post-migration verification for Phase 5A.4C.
-- Every top-level boolean should be true. The final JSON object exposes the
-- definitions of all untouched constraints for direct audit against Phase 5A.4A.

WITH identity_constraint AS (
  SELECT
    constraint_row.conname,
    regexp_replace(
      pg_get_constraintdef(constraint_row.oid, true),
      '\s+',
      ' ',
      'g'
    ) AS definition
  FROM pg_constraint AS constraint_row
  JOIN pg_class AS relation_row
    ON relation_row.oid = constraint_row.conrelid
  JOIN pg_namespace AS namespace_row
    ON namespace_row.oid = relation_row.relnamespace
  WHERE namespace_row.nspname = 'public'
    AND relation_row.relname = 'catalog_verification_overrides'
    AND constraint_row.conname = 'catalog_verification_overrides_identity_present'
),
expected_other_constraint_names (constraint_name) AS (
  VALUES
    ('catalog_verification_overrides_pkey'),
    ('catalog_verification_overrides_catalog_vendor_id_fkey'),
    ('catalog_verification_overrides_created_by_fkey'),
    ('catalog_verification_overrides_batch_vendor_fk'),
    ('catalog_verification_overrides_source_vendor_fk'),
    ('catalog_verification_overrides_product_vendor_fk'),
    ('catalog_verification_overrides_override_type_check'),
    ('catalog_verification_overrides_evidence_status_check'),
    ('catalog_verification_overrides_production_rule_check'),
    ('catalog_verification_overrides_evidence_check'),
    ('catalog_verification_overrides_sku_correction_complete'),
    ('catalog_verification_overrides_effective_order')
),
actual_other_constraints AS (
  SELECT
    constraint_row.conname AS constraint_name,
    regexp_replace(
      pg_get_constraintdef(constraint_row.oid, true),
      '\s+',
      ' ',
      'g'
    ) AS definition
  FROM pg_constraint AS constraint_row
  JOIN pg_class AS relation_row
    ON relation_row.oid = constraint_row.conrelid
  JOIN pg_namespace AS namespace_row
    ON namespace_row.oid = relation_row.relnamespace
  WHERE namespace_row.nspname = 'public'
    AND relation_row.relname = 'catalog_verification_overrides'
    AND constraint_row.conname <> 'catalog_verification_overrides_identity_present'
),
other_constraint_set_comparison AS (
  SELECT
    NOT EXISTS (
      SELECT constraint_name FROM expected_other_constraint_names
      EXCEPT
      SELECT constraint_name FROM actual_other_constraints
    )
    AND NOT EXISTS (
      SELECT constraint_name FROM actual_other_constraints
      EXCEPT
      SELECT constraint_name FROM expected_other_constraint_names
    ) AS unchanged
),
identity_truth_table (
  identity_path,
  source_record_id_present,
  normalized_source_vendor_sku_present,
  normalized_verified_vendor_sku_present,
  catalog_vendor_product_id_present,
  expected
) AS (
  VALUES
    ('source_record_id', true, false, false, false, true),
    ('normalized_source_vendor_sku', false, true, false, false, true),
    ('normalized_verified_vendor_sku', false, false, true, false, true),
    ('catalog_vendor_product_id', false, false, false, true, true),
    ('no identity', false, false, false, false, false)
),
identity_path_results AS (
  SELECT
    identity_path,
    expected,
    (
      source_record_id_present
      OR normalized_source_vendor_sku_present
      OR normalized_verified_vendor_sku_present
      OR catalog_vendor_product_id_present
    ) AS accepted
  FROM identity_truth_table
)
SELECT
  (SELECT count(*) = 1 FROM identity_constraint) AS constraint_exists_once,
  COALESCE(
    (
      SELECT
        position('source_record_id IS NOT NULL' IN definition) > 0
        AND position('normalized_source_vendor_sku IS NOT NULL' IN definition) > 0
        AND position('normalized_verified_vendor_sku IS NOT NULL' IN definition) > 0
        AND position('catalog_vendor_product_id IS NOT NULL' IN definition) > 0
      FROM identity_constraint
    ),
    false
  ) AS constraint_contains_all_four_identity_paths,
  (
    SELECT bool_and(accepted = expected)
    FROM identity_path_results
  ) AS conceptual_identity_truth_table_passes,
  (
    SELECT unchanged
    FROM other_constraint_set_comparison
  ) AS other_constraint_set_unchanged,
  (
    SELECT jsonb_object_agg(constraint_name, definition ORDER BY constraint_name)
    FROM actual_other_constraints
  ) AS other_constraint_definitions_for_audit;
