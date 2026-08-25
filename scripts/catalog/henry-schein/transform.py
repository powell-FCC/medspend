#!/usr/bin/env python3
"""Deterministic, offline Phase 5A.4B Henry Schein dry-run transformer."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Iterable, Sequence

from xlsx_reader import XlsxRecord, XlsxWorkbook


TRANSFORMER_VERSION = "phase5a4b-1.0.0"
VENDOR_KEY = "vendor:henry-schein"
IMPORT_BATCH_KEY = "import-batch:henry-schein:v28"
V28_FILENAME = "Henry_Schein_Product_Registry_Master_v28_QA_Final.xlsx"
V25_FILENAME = "Henry_Schein_Product_Registry_Master_v25.xlsx"
EXPECTED_SHA256 = {
    V28_FILENAME: "379e7f06f60c5c9cc796f5bee79ded759ec993ea87c2e35c881ec5d72691ac30",
    V25_FILENAME: "c3e94ab5c6973668807ac32ea3e93cb50d95de7966cc4a44901edfa4186dec9e",
}
EXPECTED = {
    "categories": 25,
    "raw_source_occurrences": 9268,
    "unique_raw_skus": 9058,
    "cross_category_repeated_skus": 43,
    "resolved_conflicts": 23,
    "identity_ready": 8712,
    "package_review": 346,
    "unkeyed": 53,
    "unresolved_conflicts": 0,
    "malformed_skus": 0,
    "orphan_records": 0,
    "source_count_mismatches": 0,
}

# v28 Category Metrics is the authoritative catalog-page sequence. The v25 tab
# order is not page ordered around the three diagnostic categories.
CATEGORY_SHEETS: list[tuple[str, str]] = [
    ("Athletic Tape", "SKU Occurrences"),
    ("Bandages & Dressings", "Bandages - SKU Occurrences"),
    ("Casting & Splinting", "Casting - SKU Occurrences"),
    ("Communication", "Communication - SKU Occurrences"),
    ("Dental", "Dental - SKU Occurrences"),
    ("Laboratory POC Testing", "Lab POC - SKU Occurrences"),
    ("Diagnostic Tests (LAB POC readers)", "Diag Tests - SKU Occurrences"),
    ("Diagnostic Instruments", "Diagnostic - SKU Occurrences"),
    ("EMS", "EMS - SKU Occurrences"),
    ("Equipment", "Equipment - SKU Occurrences"),
    ("Foot & Ankle", "Foot & Ankle - SKU Occurrences"),
    ("Gloves", "Gloves - SKU Occurrences"),
    ("Hot & Cold Therapy", "Hot & Cold - SKU Occurrences"),
    ("Hypodermics", "Hypodermics - SKU Occurrences"),
    ("Infection Control", "Infection - SKU Occurrences"),
    ("Instruments", "Instruments - SKU Occurrences"),
    ("Kits, Bags & Cases", "Kits Bags Cases - Occurrences"),
    ("Orthopedics", "Orthopedics - Occurrences"),
    ("Pharmaceuticals & Vaccines", "Pharma Vaccines - Occurrences"),
    ("Teaching & Educational Models", "Teaching Models - Occurrences"),
    ("Rehabilitation & Strength Conditioning", "Rehab - SKU Occurrences"),
    ("Recovery", "Recovery - SKU Occurrences"),
    ("Rehydration & Nutrition", "Rehydration - SKU Occurrences"),
    ("Topicals", "Topicals - SKU Occurrences"),
    ("Treatment Room Supplies", "Treatment - SKU Occurrences"),
]

UNKEYED_SHEETS: list[tuple[str, str]] = [
    ("Communication", "Communication - Unkeyed Models"),
    ("Diagnostic Instruments", "Diagnostic - Unkeyed Models"),
    ("EMS", "EMS - Unkeyed Models"),
    ("Equipment", "Equipment - Unkeyed Models"),
    ("Laboratory POC Testing", "Lab POC - Unkeyed Models"),
    ("Foot & Ankle", "Foot & Ankle - Unkeyed Models"),
    ("Hot & Cold Therapy", "Hot & Cold - Unkeyed Models"),
    ("Recovery", "Recovery - Unkeyed Models"),
    ("Topicals", "Topicals - Unkeyed Models"),
]

HELD_SKUS = {"128-5851", "570-0663", "570-0664", "570-0665", "570-0666"}
SKU_PATTERN = re.compile(r"^\d{3}-\d{4}$")


@dataclass(frozen=True)
class PackageState:
    description: str | None
    quantity: int | float | None
    unit: str | None
    status: str


@dataclass(frozen=True)
class Artifact:
    name: str
    record_count: int


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_sku(value: Any) -> str:
    return str(value or "").strip().upper()


def sku_match_key(value: Any) -> str:
    return re.sub(r"[^A-Z0-9]+", "", normalize_sku(value))


def normalize_text(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(value or "").lower()).strip()


def text_or_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value)
    return text if text.strip() else None


def page_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def number(value: Any) -> int | float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return int(value) if float(value).is_integer() else float(value)
    try:
        parsed = float(str(value).strip())
    except ValueError:
        return None
    if not math.isfinite(parsed):
        return None
    return int(parsed) if parsed.is_integer() else parsed


def first_value(values: dict[str, Any], names: Sequence[str]) -> Any:
    for name in names:
        if name in values and values[name] is not None:
            return values[name]
    return None


def normalized_unit(value: str) -> str:
    unit = re.sub(r"\s+", " ", value.strip().lower())
    aliases = {
        "ea": "each",
        "each": "each",
        "items": "item",
        "rolls": "roll",
        "pairs": "pair",
        "sets": "set",
        "kits": "kit",
        "bottles": "bottle",
        "vials": "vial",
        "tubes": "tube",
        "tablets": "tablet",
        "capsules": "capsule",
        "pads": "pad",
        "strips": "strip",
        "syringes": "syringe",
        "needles": "needle",
        "sheets": "sheet",
        "bags": "bag",
        "packs": "pack",
        "pkgs": "package",
    }
    return aliases.get(unit, unit[:-1] if unit.endswith("s") and len(unit) > 3 else unit)


def parse_package_description(description: str | None) -> tuple[int | float, str] | None:
    if not description:
        return None
    compact = description.strip().lower().replace("×", "x")
    if compact in {"ea", "each"}:
        return (1, "each")
    if compact in {"pair", "set", "kit"}:
        return (1, compact)
    match = re.fullmatch(
        r"(\d+(?:\.\d+)?)\s+([a-z][a-z .-]*?)/(?:case|box|pkg|package|pack|bag)",
        compact,
    )
    if match:
        quantity = number(match.group(1))
        unit = normalized_unit(match.group(2))
        if quantity and unit:
            return (quantity, unit)
    return None


def occurrence_package(record: dict[str, Any]) -> tuple[int | float, str] | None:
    quantity = number(record.get("Pack Qty"))
    unit_value = text_or_none(record.get("Base Unit Raw"))
    if quantity and quantity > 0 and unit_value:
        return (quantity, normalized_unit(unit_value))
    return parse_package_description(text_or_none(record.get("Package Raw")))


def derive_package(
    sku: str,
    master_package: str | None,
    occurrences: list[dict[str, Any]],
    package_review_skus: set[str],
    verified_override_package: str | None,
) -> PackageState:
    raw_descriptions = sorted(
        {
            description
            for occurrence in occurrences
            if (description := text_or_none(occurrence.get("Package Raw")))
        }
    )
    description = verified_override_package or master_package
    if not description and raw_descriptions:
        description = " | ".join(raw_descriptions)

    if sku in package_review_skus:
        return PackageState(
            description=description,
            quantity=None,
            unit=None,
            status="source_only" if description else "unknown",
        )

    if verified_override_package:
        parsed_override = parse_package_description(verified_override_package)
        if parsed_override:
            return PackageState(
                description=verified_override_package,
                quantity=parsed_override[0],
                unit=parsed_override[1],
                status="verified",
            )

    parsed = {value for record in occurrences if (value := occurrence_package(record))}
    if len(parsed) == 1:
        quantity, unit = next(iter(parsed))
        return PackageState(description, quantity, unit, "verified")

    parsed_master = parse_package_description(master_package)
    if not parsed and parsed_master:
        return PackageState(description, parsed_master[0], parsed_master[1], "verified")
    return PackageState(
        description=description,
        quantity=None,
        unit=None,
        status="source_only" if description else "unknown",
    )


def product_key(sku: str) -> str:
    return f"product:henry-schein:{sku.lower()}"


def vendor_product_key(sku: str) -> str:
    return f"vendor-product:henry-schein:{sku.lower()}"


def source_record_key(ordinal: int) -> str:
    return f"source-record:henry-schein:v28:{ordinal:05d}"


def json_value(value: Any) -> Any:
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("Non-finite number cannot be represented in JSON")
    return value


def exact_raw_data(record: XlsxRecord, workbook_name: str) -> dict[str, Any]:
    return {
        "source_workbook": workbook_name,
        "source_sheet": record.sheet_name,
        "source_row": record.row_number,
        "fields": {key: json_value(value) for key, value in record.values.items()},
    }


def assertion(name: str, expected: Any, actual: Any) -> dict[str, Any]:
    return {"name": name, "expected": expected, "actual": actual, "pass": actual == expected}


def ensure_input(path: Path, expected_filename: str) -> str:
    if path.name != expected_filename:
        raise ValueError(
            f"Expected exact filename {expected_filename!r}, received {path.name!r}"
        )
    if not path.is_file():
        raise ValueError(f"Required input does not exist: {path}")
    digest = sha256_file(path)
    if digest != EXPECTED_SHA256[expected_filename]:
        raise ValueError(
            f"SHA-256 mismatch for {expected_filename}: expected "
            f"{EXPECTED_SHA256[expected_filename]}, received {digest}"
        )
    return digest


def read_inputs(v28_path: Path, v25_path: Path) -> dict[str, Any]:
    v28_sha = ensure_input(v28_path, V28_FILENAME)
    v25_sha = ensure_input(v25_path, V25_FILENAME)
    v28 = XlsxWorkbook(v28_path)
    v25 = XlsxWorkbook(v25_path)

    metrics = v28.read_table("Category Metrics")
    metric_categories = [str(record.values["Category"]) for record in metrics]
    if metric_categories != [category for category, _ in CATEGORY_SHEETS]:
        raise ValueError("v28 Category Metrics order does not match the reviewed source map")

    source_occurrences: list[dict[str, Any]] = []
    occurrence_rows_by_sku: dict[str, list[dict[str, Any]]] = defaultdict(list)
    occurrence_categories_by_sku: dict[str, set[str]] = defaultdict(set)
    source_counter: Counter[str] = Counter()
    ordinal = 0
    category_counts: dict[str, int] = {}

    for metric, (category, sheet_name) in zip(metrics, CATEGORY_SHEETS):
        rows = v25.read_table(sheet_name)
        category_counts[category] = len(rows)
        expected_count = int(metric.values["Occurrences"])
        if len(rows) != expected_count:
            raise ValueError(
                f"Category count mismatch for {category}: expected {expected_count}, got {len(rows)}"
            )
        for row in rows:
            ordinal += 1
            values = row.values
            raw_sku_value = values.get("Vendor SKU")
            raw_sku = text_or_none(raw_sku_value)
            normalized = normalize_sku(raw_sku)
            if not normalized:
                raise ValueError(
                    f"Blank keyed SKU in {sheet_name} row {row.row_number}"
                )
            raw_category = text_or_none(
                first_value(values, ("Registry Category", "Catalog Category"))
            )
            raw_product = text_or_none(
                first_value(values, ("Product Family Raw", "Product Family"))
            )
            raw_variant = text_or_none(
                first_value(
                    values,
                    ("Variant / Size Raw", "Variant / Row Raw", "Variant / Model Raw", "Variant / Strength Raw"),
                )
            )
            source_page = page_text(values.get("Catalog Page"))
            target_sku = (
                "128-5852"
                if normalized == "128-5853"
                and category == "Athletic Tape"
                and source_page == "22"
                else normalized
            )
            source_counter[normalized] += 1
            occurrence_categories_by_sku[normalized].add(category)
            occurrence_rows_by_sku[normalized].append(values)
            source_occurrences.append(
                {
                    "source_record_key": source_record_key(ordinal),
                    "import_batch_key": IMPORT_BATCH_KEY,
                    "catalog_vendor_key": VENDOR_KEY,
                    "source_ordinal": ordinal,
                    "raw_vendor_sku": raw_sku,
                    "normalized_raw_vendor_sku": normalized,
                    "raw_vendor_sku_match_key": sku_match_key(raw_sku),
                    "raw_product_name": raw_product,
                    "raw_category": raw_category,
                    "raw_subsection": text_or_none(values.get("Catalog Subsection")),
                    "raw_variant": raw_variant,
                    "raw_package": text_or_none(values.get("Package Raw")),
                    "source_page": source_page,
                    "raw_data": exact_raw_data(row, V25_FILENAME),
                    "matched_catalog_vendor_product_key": vendor_product_key(target_sku),
                    "resolution_status": "matched",
                    "source_category_sequence_name": category,
                }
            )

    unkeyed: list[dict[str, Any]] = []
    for category, sheet_name in UNKEYED_SHEETS:
        for row in v25.read_table(sheet_name):
            values = row.values
            unkeyed.append(
                {
                    "unkeyed_record_key": f"unkeyed:henry-schein:v28:{len(unkeyed) + 1:03d}",
                    "source_sheet": sheet_name,
                    "source_row": row.row_number,
                    "raw_category": category,
                    "source_page": page_text(values.get("Catalog Page")),
                    "raw_product_name": text_or_none(
                        first_value(values, ("Product Family", "Product Family / Brand", "Description"))
                    ),
                    "raw_model_or_variant": text_or_none(
                        first_value(
                            values,
                            ("Model Number", "Model / Listing", "Printed Model", "Manufacturer / FEI SKU", "Model / Variant"),
                        )
                    ),
                    "raw_package": text_or_none(
                        first_value(values, ("Package / Source Detail", "Catalog Attributes"))
                    ),
                    "raw_vendor_sku": None,
                    "resolution_status": "unkeyed",
                    "raw_data": exact_raw_data(row, V25_FILENAME),
                }
            )

    return {
        "v28": v28,
        "v25": v25,
        "v28_sha": v28_sha,
        "v25_sha": v25_sha,
        "source_occurrences": source_occurrences,
        "occurrence_rows_by_sku": occurrence_rows_by_sku,
        "occurrence_categories_by_sku": occurrence_categories_by_sku,
        "source_counter": source_counter,
        "category_counts": category_counts,
        "unkeyed": unkeyed,
    }


def build_candidates(inputs: dict[str, Any]) -> dict[str, Any]:
    v28: XlsxWorkbook = inputs["v28"]
    master_records = v28.read_table("Master SKU Registry QA")
    package_queue_records = v28.read_table("Package Normalization Queue")
    resolved_records = v28.read_table("Resolved Conflict Log")
    explicit_override_records = v28.read_table("Verification Overrides")
    cross_category_records = v28.read_table("Cross-Category Repeats")
    open_conflict_records = v28.read_table("Open Conflict Queue")
    package_review_skus = {
        normalize_sku(record.values["Vendor SKU"]) for record in package_queue_records
    }
    resolved_skus = {
        normalize_sku(record.values["Vendor SKU"]) for record in resolved_records
    }
    explicit_overrides_by_verified_sku = {
        normalize_sku(record.values.get("Verified / Correct SKU")): record.values
        for record in explicit_override_records
        if record.values.get("Verified / Correct SKU") is not None
    }

    products: list[dict[str, Any]] = []
    vendor_products: list[dict[str, Any]] = []
    master_counter: dict[str, int] = {}
    master_rows_by_sku: dict[str, dict[str, Any]] = {}

    for record in master_records:
        values = record.values
        sku = normalize_sku(values["Vendor SKU"])
        if sku in master_rows_by_sku:
            raise ValueError(f"Duplicate master SKU {sku}")
        master_rows_by_sku[sku] = values
        master_counter[sku] = int(values["Source Occurrences"])

    promoted_skus = sorted(set(master_rows_by_sku) | {"128-5852"})
    promoted_skus = [sku for sku in promoted_skus if sku not in HELD_SKUS]
    if "128-5852" in master_rows_by_sku:
        raise ValueError("128-5852 unexpectedly exists in the raw master; override logic needs review")

    for sku in promoted_skus:
        master = master_rows_by_sku.get(sku)
        explicit = explicit_overrides_by_verified_sku.get(sku)
        if master:
            name = str(master["Primary Product Family"])
            description = text_or_none(master.get("Variant Examples"))
            master_package = text_or_none(master.get("Package Patterns"))
            qa_gate = str(master["Catalog QA Gate"])
        else:
            if sku != "128-5852" or explicit is None:
                raise ValueError(f"No source-backed master or approved override for {sku}")
            name = str(explicit["Product"])
            description = text_or_none(explicit.get("Dimensions"))
            master_package = None
            qa_gate = "READY - VERIFIED OVERRIDE"

        verified_override_package: str | None = None
        if explicit and str(explicit.get("Production Rule", "")).upper() != "HOLD FOR SECOND SOURCE":
            name = str(explicit["Product"])
            override_dimensions = text_or_none(explicit.get("Dimensions"))
            if override_dimensions:
                description = override_dimensions
            verified_override_package = text_or_none(explicit.get("Packaging"))

        manufacturer = "Felix Storch (Summit)" if sku == "139-7157" else None
        active = sku != "364-0444"
        discontinued = sku == "364-0444"
        package = derive_package(
            sku,
            master_package,
            inputs["occurrence_rows_by_sku"].get(sku, []),
            package_review_skus,
            verified_override_package,
        )
        products.append(
            {
                "product_key": product_key(sku),
                "name": name,
                "normalized_name": normalize_text(name),
                "description": description,
                "manufacturer": manufacturer,
                "normalized_manufacturer": normalize_text(manufacturer) if manufacturer else None,
                "catalog_category_key": None,
                "active": active,
                "verification_status": "verified",
                "source_vendor_sku": sku,
            }
        )
        vendor_products.append(
            {
                "vendor_product_key": vendor_product_key(sku),
                "catalog_product_key": product_key(sku),
                "catalog_vendor_key": VENDOR_KEY,
                "vendor_sku": sku,
                "normalized_vendor_sku": normalize_sku(sku),
                "vendor_sku_match_key": sku_match_key(sku),
                "manufacturer_sku": None,
                "normalized_manufacturer_sku": None,
                "package_description": package.description,
                "package_quantity": package.quantity,
                "package_unit": package.unit,
                "package_status": package.status,
                "source_catalog_price": None,
                "currency_code": None,
                "active": active,
                "discontinued": discontinued,
                "verification_status": "verified",
                "qa_gate": qa_gate,
            }
        )

    vendor_products_by_sku = {
        row["normalized_vendor_sku"]: row for row in vendor_products
    }
    for source in inputs["source_occurrences"]:
        raw_sku = source["normalized_raw_vendor_sku"]
        source["resolution_status"] = (
            "verified_match"
            if raw_sku in resolved_skus or source["source_page"] == "22" and raw_sku == "128-5853"
            else "matched"
        )

    overrides: list[dict[str, Any]] = []
    for record in explicit_override_records:
        values = record.values
        source_sku = normalize_sku(values.get("Source SKU")) or None
        verified_sku = normalize_sku(values.get("Verified / Correct SKU")) or None
        production_rule = str(values["Production Rule"])
        if production_rule == "OVERRIDE CATALOG TYPO":
            override_type = "sku_correction"
        elif "PURCHAS" in production_rule:
            override_type = "purchasing_status"
        elif production_rule == "HOLD FOR SECOND SOURCE":
            override_type = "source_disposition"
        else:
            override_type = "identity_decision"
        source_ordinals = [
            row["source_ordinal"]
            for row in inputs["source_occurrences"]
            if source_sku and row["normalized_raw_vendor_sku"] == source_sku
        ]
        catalog_or_user_item = str(values["Catalog / User Item"])
        if source_sku == "128-5853" and catalog_or_user_item in {
            "Catalog page 7 listing",
            "Catalog page 22 listing",
        }:
            expected_page = "7" if catalog_or_user_item == "Catalog page 7 listing" else "22"
            source_ordinals = [
                row["source_ordinal"]
                for row in inputs["source_occurrences"]
                if row["normalized_raw_vendor_sku"] == source_sku
                and row["source_page"] == expected_page
            ]
        overrides.append(
            {
                "override_key": f"override:verification-overrides:{record.row_number:03d}",
                "catalog_vendor_key": VENDOR_KEY,
                "import_batch_key": IMPORT_BATCH_KEY,
                "source_record_key": source_record_key(source_ordinals[0]) if len(source_ordinals) == 1 else None,
                "catalog_vendor_product_key": (
                    vendor_product_key(verified_sku)
                    if verified_sku in vendor_products_by_sku
                    else None
                ),
                "source_vendor_sku": source_sku,
                "normalized_source_vendor_sku": source_sku,
                "verified_vendor_sku": verified_sku,
                "normalized_verified_vendor_sku": verified_sku,
                "override_type": override_type,
                "evidence_status": "pending" if production_rule == "HOLD FOR SECOND SOURCE" else "verified",
                "production_rule": production_rule,
                "evidence": {
                    "source_sheet": record.sheet_name,
                    "source_row": record.row_number,
                    "source_ordinals": source_ordinals,
                    "catalog_or_user_item": catalog_or_user_item,
                    "product": values.get("Product"),
                    "dimensions": values.get("Dimensions"),
                    "packaging": values.get("Packaging"),
                    "evidence_status_raw": values.get("Evidence Status"),
                },
                "notes": text_or_none(values.get("Notes")),
                "active": True,
            }
        )

    for record in resolved_records:
        values = record.values
        sku = normalize_sku(values["Vendor SKU"])
        overrides.append(
            {
                "override_key": f"override:resolved-conflict-log:{record.row_number:03d}",
                "catalog_vendor_key": VENDOR_KEY,
                "import_batch_key": IMPORT_BATCH_KEY,
                "source_record_key": None,
                "catalog_vendor_product_key": vendor_product_key(sku),
                "source_vendor_sku": sku,
                "normalized_source_vendor_sku": sku,
                "verified_vendor_sku": sku,
                "normalized_verified_vendor_sku": sku,
                "override_type": "identity_decision",
                "evidence_status": "verified",
                "production_rule": str(values["Import Status"]),
                "evidence": {
                    "source_sheet": record.sheet_name,
                    "source_row": record.row_number,
                    "catalog_categories": values.get("Catalog Categories"),
                    "source_occurrences": values.get("Source Occurrences"),
                    "primary_product_family": values.get("Primary Product Family"),
                    "product_families_seen": values.get("Product Families Seen"),
                    "source_pages": values.get("Source Pages"),
                    "variant_examples": values.get("Variant Examples"),
                    "package_patterns": values.get("Package Patterns"),
                    "conflict_status": values.get("Duplicate / Conflict Status"),
                },
                "notes": None,
                "active": True,
            }
        )

    package_review = []
    for sku in sorted(package_review_skus):
        vendor_product = vendor_products_by_sku[sku]
        raw_packages = sorted(
            {
                package
                for occurrence in inputs["occurrence_rows_by_sku"][sku]
                if (package := text_or_none(occurrence.get("Package Raw")))
            }
        )
        package_review.append(
            {
                "vendor": "Henry Schein",
                "vendor_sku": sku,
                "catalog_vendor_product_key": vendor_product["vendor_product_key"],
                "package_status": vendor_product["package_status"],
                "package_description": vendor_product["package_description"],
                "raw_package_evidence": raw_packages,
                "disposition": "retain identity; normalize package before unit-price intelligence",
            }
        )

    collisions: list[dict[str, Any]] = []
    by_match_key: dict[str, list[str]] = defaultdict(list)
    for row in vendor_products:
        by_match_key[row["vendor_sku_match_key"]].append(row["normalized_vendor_sku"])
    for match_key, skus in sorted(by_match_key.items()):
        distinct_skus = sorted(set(skus))
        if len(distinct_skus) > 1:
            collisions.append(
                {
                    "vendor": "Henry Schein",
                    "match_key": match_key,
                    "count": len(distinct_skus),
                    "vendor_skus_involved": distinct_skus,
                    "normalized_identity_relationship": "different normalized identities",
                    "disposition": "informational / review; do not auto-merge",
                }
            )

    return {
        "master_records": master_records,
        "master_rows_by_sku": master_rows_by_sku,
        "master_counter": master_counter,
        "package_queue_records": package_queue_records,
        "package_review_skus": package_review_skus,
        "resolved_records": resolved_records,
        "resolved_skus": resolved_skus,
        "explicit_override_records": explicit_override_records,
        "cross_category_records": cross_category_records,
        "open_conflict_records": open_conflict_records,
        "products": products,
        "vendor_products": vendor_products,
        "vendor_products_by_sku": vendor_products_by_sku,
        "overrides": overrides,
        "package_review": package_review,
        "collisions": collisions,
        "rejected": [],
    }


def reconcile(inputs: dict[str, Any], candidates: dict[str, Any]) -> dict[str, Any]:
    source_counter: Counter[str] = inputs["source_counter"]
    master_counter: dict[str, int] = candidates["master_counter"]
    master_skus = set(master_counter)
    source_skus = set(source_counter)
    malformed = sorted(sku for sku in source_skus | master_skus if not SKU_PATTERN.fullmatch(sku))
    orphan_count = len(source_skus - master_skus) + len(master_skus - source_skus)
    mismatch_skus = sorted(
        sku for sku in source_skus | master_skus if source_counter.get(sku, 0) != master_counter.get(sku, 0)
    )
    computed_cross_category = sum(
        1 for categories in inputs["occurrence_categories_by_sku"].values() if len(categories) > 1
    )
    qa_gates = Counter(
        str(record.values["Catalog QA Gate"])
        for record in candidates["master_records"]
    )
    package_counts = Counter(row["package_status"] for row in candidates["vendor_products"])
    normalized_skus = [row["normalized_vendor_sku"] for row in candidates["vendor_products"]]
    source_ordinals = [row["source_ordinal"] for row in inputs["source_occurrences"]]
    raw_128_5853 = [
        row for row in inputs["source_occurrences"] if row["raw_vendor_sku"] == "128-5853"
    ]
    promoted_skus = set(normalized_skus)
    vp_364 = candidates["vendor_products_by_sku"].get("364-0444")
    product_139 = next(
        (row for row in candidates["products"] if row["source_vendor_sku"] == "139-7157"),
        None,
    )
    verified_package_invalid = sum(
        1
        for row in candidates["vendor_products"]
        if row["package_status"] == "verified"
        and (
            row["package_quantity"] is None
            or row["package_quantity"] <= 0
            or not text_or_none(row["package_unit"])
        )
    )

    assertions = [
        assertion("category count", EXPECTED["categories"], len(inputs["category_counts"])),
        assertion("raw source occurrence count", EXPECTED["raw_source_occurrences"], len(inputs["source_occurrences"])),
        assertion("unique raw keyed SKU count", EXPECTED["unique_raw_skus"], len(source_skus)),
        assertion("master SKU count", EXPECTED["unique_raw_skus"], len(master_skus)),
        assertion("cross-category repeated SKU count (computed)", EXPECTED["cross_category_repeated_skus"], computed_cross_category),
        assertion("cross-category repeat log count", EXPECTED["cross_category_repeated_skus"], len(candidates["cross_category_records"])),
        assertion("unkeyed source listing count", EXPECTED["unkeyed"], len(inputs["unkeyed"])),
        assertion("resolved conflict record count", EXPECTED["resolved_conflicts"], len(candidates["resolved_records"])),
        assertion("identity-ready master rows", EXPECTED["identity_ready"], qa_gates["READY - IDENTITY"]),
        assertion("package-review master rows", EXPECTED["package_review"], qa_gates["REVIEW - PACKAGE NORMALIZATION"]),
        assertion("package-review output rows", EXPECTED["package_review"], len(candidates["package_review"])),
        assertion("unresolved keyed conflicts", EXPECTED["unresolved_conflicts"], 0 if len(candidates["open_conflict_records"]) == 1 and candidates["open_conflict_records"][0].values.get("Vendor SKU") == "NO OPEN CONFLICTS" else len(candidates["open_conflict_records"])),
        assertion("malformed keyed SKUs", EXPECTED["malformed_skus"], len(malformed)),
        assertion("orphan occurrence/master identities", EXPECTED["orphan_records"], orphan_count),
        assertion("source occurrence count mismatches", EXPECTED["source_count_mismatches"], len(mismatch_skus)),
        assertion("proposed source record count", EXPECTED["raw_source_occurrences"], len(inputs["source_occurrences"])),
        assertion("source ordinal minimum", 1, min(source_ordinals)),
        assertion("source ordinal maximum", EXPECTED["raw_source_occurrences"], max(source_ordinals)),
        assertion("distinct source ordinals", EXPECTED["raw_source_occurrences"], len(set(source_ordinals))),
        assertion("duplicate vendor + normalized SKU", 0, len(normalized_skus) - len(set(normalized_skus))),
        assertion("blank promoted normalized SKU", 0, sum(1 for sku in normalized_skus if not sku)),
        assertion("verified/source_only/unknown package sum", len(candidates["vendor_products"]), sum(package_counts.values())),
        assertion("invalid verified package rows", 0, verified_package_invalid),
        assertion("128-5852 verified normalized candidate", True, candidates["vendor_products_by_sku"].get("128-5852", {}).get("verification_status") == "verified"),
        assertion("raw 128-5853 occurrences preserved", 2, len(raw_128_5853)),
        assertion("raw page-22 128-5853 maps to 128-5852", 1, sum(1 for row in raw_128_5853 if row["source_page"] == "22" and row["matched_catalog_vendor_product_key"] == vendor_product_key("128-5852"))),
        assertion("legitimate 128-5853 remains separate", True, "128-5853" in promoted_skus and any(row["matched_catalog_vendor_product_key"] == vendor_product_key("128-5853") for row in raw_128_5853)),
        assertion("held overrides not promoted", [], sorted(HELD_SKUS & promoted_skus)),
        assertion("364-0444 inactive and discontinued", True, bool(vp_364 and vp_364["active"] is False and vp_364["discontinued"] is True)),
        assertion("139-7157 verified Accucold identity", True, bool(product_139 and product_139["name"] == "Accucold Performance Series Pharmacy/Vaccine Refrigerator 2.83 Cu Ft 2 to 8C" and product_139["manufacturer"] == "Felix Storch (Summit)")),
        assertion("rejected record count", 0, len(candidates["rejected"])),
    ]
    result = "PASS" if all(item["pass"] for item in assertions) else "FAIL"
    counts = {
        "categories": len(inputs["category_counts"]),
        "raw_source_records": len(inputs["source_occurrences"]),
        "unique_raw_skus": len(source_skus),
        "normalized_vendor_products": len(candidates["vendor_products"]),
        "canonical_products": len(candidates["products"]),
        "unkeyed_records": len(inputs["unkeyed"]),
        "verification_overrides": len(candidates["overrides"]),
        "explicit_verification_override_rows": len(candidates["explicit_override_records"]),
        "resolved_conflict_decision_rows": len(candidates["resolved_records"]),
        "package_verified": package_counts["verified"],
        "package_source_only": package_counts["source_only"],
        "package_unknown": package_counts["unknown"],
        "package_review": len(candidates["package_review"]),
        "match_key_collision_groups": len(candidates["collisions"]),
        "rejected_rows": len(candidates["rejected"]),
    }
    return {
        "result": result,
        "transformer_version": TRANSFORMER_VERSION,
        "source_artifacts": {
            "v28": {"name": V28_FILENAME, "sha256": inputs["v28_sha"]},
            "v25": {"name": V25_FILENAME, "sha256": inputs["v25_sha"]},
        },
        "strategies": {
            "canonical_products": "One conservative canonical product per promoted Henry Schein vendor SKU; no fuzzy or cross-vendor merging.",
            "source_ordinals": "v28 Category Metrics catalog-page order, then original v25 occurrence-sheet row order.",
            "packages": "Verified only from a trusted explicit override or one consistent positive quantity/unit interpretation; otherwise source_only or unknown.",
            "categories": "Raw source categories are preserved; catalog_category_key remains null because no approved MedSpend taxonomy mapping exists.",
            "prices": "No unambiguous catalog price field exists in the reviewed source tables; source_catalog_price remains null.",
        },
        "counts": counts,
        "category_counts": inputs["category_counts"],
        "assertions": assertions,
        "diagnostics": {
            "malformed_skus": malformed,
            "orphan_source_only_skus": sorted(source_skus - master_skus),
            "orphan_master_only_skus": sorted(master_skus - source_skus),
            "source_count_mismatch_skus": mismatch_skus,
        },
    }


def csv_scalar(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, dict)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return value


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: csv_scalar(row.get(field)) for field in fieldnames})


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            output.write("\n")


def build_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Henry Schein Phase 5A.4B dry-run reconciliation",
        "",
        f"Result: **{report['result']}**",
        "",
        "## Counts",
        "",
        "| Metric | Count |",
        "|---|---:|",
    ]
    for name, count in report["counts"].items():
        lines.append(f"| {name.replace('_', ' ')} | {count} |")
    lines.extend(["", "## Required invariants", "", "| Assertion | Expected | Actual | Result |", "|---|---:|---:|---|"])
    for item in report["assertions"]:
        expected = json.dumps(item["expected"], ensure_ascii=False)
        actual = json.dumps(item["actual"], ensure_ascii=False)
        lines.append(f"| {item['name']} | {expected} | {actual} | {'PASS' if item['pass'] else 'FAIL'} |")
    lines.extend(
        [
            "",
            "## Guardrails",
            "",
            "This output is offline and dry-run-only. It contains logical keys, not database UUIDs, and omits lifecycle timestamps that must be supplied only by a separately approved promotion workflow.",
            "No catalog categories are proposed, no source/list prices are inferred, and match-key collisions are never auto-merged.",
            "The 53 unkeyed listings are preserved separately and are not assigned synthetic SKUs or source ordinals in the 9,268 keyed occurrence batch.",
            "",
        ]
    )
    return "\n".join(lines)


def write_outputs(output_dir: Path, inputs: dict[str, Any], candidates: dict[str, Any], report: dict[str, Any]) -> None:
    if report["result"] != "PASS":
        failures = [item for item in report["assertions"] if not item["pass"]]
        raise ValueError(f"Reconciliation failed; no outputs written: {failures}")
    output_dir.mkdir(parents=True, exist_ok=True)

    package_counts = report["counts"]
    import_batch = {
        "import_batch_key": IMPORT_BATCH_KEY,
        "catalog_vendor_key": VENDOR_KEY,
        "source_name": "Henry Schein Sports Medicine, Foot & Ankle, Student Health Product Guide",
        "source_version": "2023-2024 / registry v28 QA Final",
        "artifact_name": V28_FILENAME,
        "artifact_sha256": inputs["v28_sha"],
        "source_uri": None,
        "status": "pending",
        "raw_record_count": report["counts"]["raw_source_records"],
        "unique_key_count": report["counts"]["unique_raw_skus"],
        "matched_record_count": report["counts"]["raw_source_records"],
        "unmatched_record_count": 0,
        "warning_count": report["counts"]["package_review"] + report["counts"]["unkeyed_records"],
        "error_count": 0,
        "metadata": {
            "dry_run": True,
            "dry_run_status": "validated",
            "v28_artifact": {"name": V28_FILENAME, "sha256": inputs["v28_sha"]},
            "v25_raw_archive": {"name": V25_FILENAME, "sha256": inputs["v25_sha"]},
            "proposed_normalized_vendor_product_count": report["counts"]["normalized_vendor_products"],
            "unkeyed_source_listing_count": report["counts"]["unkeyed_records"],
            "package_state_counts": {
                "verified": package_counts["package_verified"],
                "source_only": package_counts["package_source_only"],
                "unknown": package_counts["package_unknown"],
            },
            "verification_override_count": report["counts"]["verification_overrides"],
            "transformer_version": TRANSFORMER_VERSION,
        },
    }
    vendor = {
        "catalog_vendor_key": VENDOR_KEY,
        "name": "Henry Schein",
        "normalized_name": "henry schein",
        "website": "https://www.henryschein.com",
        "domain": "henryschein.com",
        "active": True,
    }

    write_json(output_dir / "import_batch.json", import_batch)
    write_json(output_dir / "catalog_vendor.json", vendor)
    write_csv(
        output_dir / "catalog_products.csv",
        candidates["products"],
        [
            "product_key", "name", "normalized_name", "description", "manufacturer",
            "normalized_manufacturer", "catalog_category_key", "active",
            "verification_status", "source_vendor_sku",
        ],
    )
    write_csv(
        output_dir / "catalog_vendor_products.csv",
        candidates["vendor_products"],
        [
            "vendor_product_key", "catalog_product_key", "catalog_vendor_key", "vendor_sku",
            "normalized_vendor_sku", "vendor_sku_match_key", "manufacturer_sku",
            "normalized_manufacturer_sku", "package_description", "package_quantity",
            "package_unit", "package_status", "source_catalog_price", "currency_code",
            "active", "discontinued", "verification_status", "qa_gate",
        ],
    )
    write_jsonl(output_dir / "catalog_source_records.jsonl", inputs["source_occurrences"])
    write_jsonl(output_dir / "catalog_verification_overrides.jsonl", candidates["overrides"])
    write_csv(
        output_dir / "unkeyed_source_records.csv",
        inputs["unkeyed"],
        [
            "unkeyed_record_key", "source_sheet", "source_row", "raw_category", "source_page",
            "raw_product_name", "raw_model_or_variant", "raw_package", "raw_vendor_sku",
            "resolution_status", "raw_data",
        ],
    )
    write_csv(
        output_dir / "package_normalization_review.csv",
        candidates["package_review"],
        [
            "vendor", "vendor_sku", "catalog_vendor_product_key", "package_status",
            "package_description", "raw_package_evidence", "disposition",
        ],
    )
    write_csv(
        output_dir / "rejected_records.csv",
        candidates["rejected"],
        ["record_type", "source_reference", "reason", "raw_data"],
    )
    write_csv(
        output_dir / "sku_match_key_collisions.csv",
        candidates["collisions"],
        [
            "vendor", "match_key", "count", "vendor_skus_involved",
            "normalized_identity_relationship", "disposition",
        ],
    )
    write_json(output_dir / "reconciliation_report.json", report)
    (output_dir / "reconciliation_report.md").write_text(build_markdown(report), encoding="utf-8")

    artifacts = [
        Artifact("catalog_products.csv", len(candidates["products"])),
        Artifact("catalog_source_records.jsonl", len(inputs["source_occurrences"])),
        Artifact("catalog_vendor.json", 1),
        Artifact("catalog_vendor_products.csv", len(candidates["vendor_products"])),
        Artifact("catalog_verification_overrides.jsonl", len(candidates["overrides"])),
        Artifact("import_batch.json", 1),
        Artifact("package_normalization_review.csv", len(candidates["package_review"])),
        Artifact("reconciliation_report.json", 1),
        Artifact("reconciliation_report.md", 1),
        Artifact("rejected_records.csv", len(candidates["rejected"])),
        Artifact("sku_match_key_collisions.csv", len(candidates["collisions"])),
        Artifact("unkeyed_source_records.csv", len(inputs["unkeyed"])),
    ]
    manifest = {
        "transformer_version": TRANSFORMER_VERSION,
        "deterministic": True,
        "generated_at": None,
        "determinism_notes": [
            "No generation timestamp is emitted.",
            "Logical external keys are deterministic; database UUIDs and lifecycle timestamps are omitted.",
            "The manifest cannot include its own SHA-256 because that would be circular; every other generated artifact is hashed.",
        ],
        "source_artifacts": [
            {"name": V28_FILENAME, "sha256": inputs["v28_sha"]},
            {"name": V25_FILENAME, "sha256": inputs["v25_sha"]},
        ],
        "artifacts": [
            {
                "name": artifact.name,
                "record_count": artifact.record_count,
                "sha256": sha256_file(output_dir / artifact.name),
            }
            for artifact in sorted(artifacts, key=lambda item: item.name)
        ],
        "manifest_self_hash": None,
    }
    write_json(output_dir / "dry_run_manifest.json", manifest)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--v28", type=Path, required=True)
    parser.add_argument("--v25", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        inputs = read_inputs(args.v28.resolve(), args.v25.resolve())
        candidates = build_candidates(inputs)
        report = reconcile(inputs, candidates)
        write_outputs(args.output_dir.resolve(), inputs, candidates, report)
    except (OSError, ValueError) as error:
        print(f"Henry Schein transform failed: {error}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(json.dumps({"result": report["result"], "counts": report["counts"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
