"""Focused Phase 2A catalog and RLS checks against the owned development project."""
import json, os, sys, urllib.error, urllib.parse, urllib.request, uuid

URL = os.environ["SUPABASE_URL"]
SERVICE = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
PUBLISHABLE = os.environ["SUPABASE_PUBLISHABLE_KEY"]
assert "spbtykgpjjfjpmnedzjd" in URL and "sbihpdzthfpwjajqldls" not in URL
PASSWORD = "Test123!phase"
OWNER_EMAIL, STAFF_EMAIL = "phase1.owner@medspend.test", "phase1.staff@medspend.test"
OWNER_ID, STAFF_ID = "c922b595-5b8e-41f4-bd12-91512f915309", "a6900e53-f4b5-43c2-927d-5c070efb9757"
passed, failed = [], []

def check(label, condition, detail=""):
    (passed if condition else failed).append((label, str(detail)[:240]))
    print(("PASS " if condition else "FAIL ") + label + (f" — {detail}" if detail else ""))

def session(email):
    req = urllib.request.Request(URL + "/auth/v1/token?grant_type=password", method="POST", headers={"apikey": PUBLISHABLE, "Content-Type": "application/json"}, data=json.dumps({"email": email, "password": PASSWORD}).encode())
    return json.load(urllib.request.urlopen(req))["access_token"]

def rest(table, token=SERVICE, method="GET", params=None, body=None):
    path = "/rest/v1/" + table
    if params: path += "?" + urllib.parse.urlencode(params, safe=".*(),")
    req = urllib.request.Request(URL + path, method=method, headers={"apikey": PUBLISHABLE if token != SERVICE else SERVICE, "Authorization": "Bearer " + token, "Content-Type": "application/json", "Prefer": "return=representation"}, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read().decode()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()

owner, staff = session(OWNER_EMAIL), session(STAFF_EMAIL)
org_id, foreign_org = str(uuid.uuid4()), str(uuid.uuid4())
category_id = vendor_id = product_id = None
try:
    rest("organizations", method="POST", body={"id": org_id, "name": "Phase 2A Catalog Test", "created_by": OWNER_ID})
    rest("organizations", method="POST", body={"id": foreign_org, "name": "Phase 2A Foreign Org", "created_by": OWNER_ID})
    rest("organization_memberships", method="POST", body=[{"organization_id": org_id, "user_id": OWNER_ID, "role": "owner"}, {"organization_id": org_id, "user_id": STAFF_ID, "role": "staff"}, {"organization_id": foreign_org, "user_id": OWNER_ID, "role": "owner"}])

    status, rows = rest("product_categories", owner, "POST", body={"organization_id": org_id, "name": "Clinical Supplies", "normalized_name": "ignored"})
    category_id = rows[0]["id"] if status == 201 else None
    check("1 owner creates category", status == 201 and rows[0]["normalized_name"] == "clinical supplies", rows)
    status, _ = rest("product_categories", owner, "POST", body={"organization_id": org_id, "name": " Clinical--Supplies ", "normalized_name": "ignored"})
    check("2 duplicate category detection", status == 409, status)
    rest(f"product_categories?id=eq.{category_id}", owner, "PATCH", body={"active": False})
    status, rows = rest("product_categories", owner, params={"id": f"eq.{category_id}", "select": "active"})
    archived = status == 200 and rows == [{"active": False}]
    rest(f"product_categories?id=eq.{category_id}", owner, "PATCH", body={"active": True})
    _, rows = rest("product_categories", owner, params={"id": f"eq.{category_id}", "select": "active"})
    check("3 archive and restore category", archived and rows == [{"active": True}], rows)

    status, rows = rest("vendors", owner, "POST", body={"organization_id": org_id, "name": "Acme Medical", "normalized_name": "ignored", "account_number": "A-100"})
    vendor_id = rows[0]["id"] if status == 201 else None
    check("4 owner creates vendor", status == 201 and rows[0]["normalized_name"] == "acme medical", rows)
    status, candidates = rest("vendors", owner, params={"organization_id": f"eq.{org_id}", "normalized_name": "ilike.*acme*", "select": "id,name"})
    check("5 likely duplicate vendor is surfaced without merge", status == 200 and len(candidates) == 1, candidates)
    rest(f"vendors?id=eq.{vendor_id}", owner, "PATCH", body={"active": False}); _, rows = rest("vendors", owner, params={"id": f"eq.{vendor_id}", "select": "active"}); archived = rows == [{"active": False}]
    rest(f"vendors?id=eq.{vendor_id}", owner, "PATCH", body={"active": True}); _, rows = rest("vendors", owner, params={"id": f"eq.{vendor_id}", "select": "active"})
    check("6 archive and restore vendor", archived and rows == [{"active": True}], rows)

    status, rows = rest("products", owner, "POST", body={"organization_id": org_id, "name": "Pro Athletic Tape", "normalized_name": "ignored", "category_id": category_id, "preferred_vendor_id": vendor_id, "manufacturer": "MedCo", "vendor_item_number": "VEND-4242", "internal_item_code": "TAPE-01", "unit_of_measure": "roll", "staff_requestable": True})
    product_id = rows[0]["id"] if status == 201 else None
    check("7 owner creates product", status == 201 and rows[0]["normalized_name"] == "pro athletic tape", rows)
    status, rows = rest("product_aliases", owner, "POST", body={"organization_id": org_id, "product_id": product_id, "alias": "Trainer's Tape", "normalized_alias": "ignored"})
    check("8 owner creates alias", status == 201 and rows[0]["normalized_alias"] == "trainer s tape", rows)
    status, rows = rest("product_aliases", staff, params={"organization_id": f"eq.{org_id}", "normalized_alias": "ilike.*trainer*", "select": "product_id,alias"})
    check("9 staff alias search finds requestable product", status == 200 and rows and rows[0]["product_id"] == product_id, rows)
    status, rows = rest("products", staff, params={"organization_id": f"eq.{org_id}", "vendor_item_number": "ilike.*4242*", "select": "id"})
    check("10 vendor item number search", status == 200 and rows == [{"id": product_id}], rows)
    rest(f"products?id=eq.{product_id}", owner, "PATCH", body={"active": False}); _, rows = rest("products", owner, params={"id": f"eq.{product_id}", "select": "active"})
    check("11 owner archives product", rows == [{"active": False}], rows)
    _, rows = rest("products", staff, params={"id": f"eq.{product_id}", "select": "id"})
    check("12 archived product hidden from staff", rows == [], rows)
    rest(f"products?id=eq.{product_id}", owner, "PATCH", body={"active": True, "staff_requestable": False, "approved": False}); _, rows = rest("products", staff, params={"id": f"eq.{product_id}", "select": "id"})
    check("13 non-requestable product hidden from staff", rows == [], rows)
    status, _ = rest("vendors", staff, "POST", body={"organization_id": org_id, "name": "Forbidden Vendor", "normalized_name": "forbidden vendor"})
    check("14 staff denied vendor administration", status in (401, 403), status)
    status, _ = rest("products", staff, "POST", body={"organization_id": org_id, "name": "Forbidden Product", "normalized_name": "forbidden product"})
    check("15 staff denied product administration", status in (401, 403), status)
    status, rows = rest("products", staff, params={"organization_id": f"eq.{foreign_org}", "select": "id"})
    check("16 cross-organization reads blocked", status == 200 and rows == [], rows)
finally:
    rest(f"organizations?id=eq.{org_id}", method="DELETE")
    rest(f"organizations?id=eq.{foreign_org}", method="DELETE")

print(f"\nPHASE 2A SUMMARY: PASS {len(passed)} FAIL {len(failed)}")
for label, detail in failed: print("FAIL", label, detail)
sys.exit(1 if failed else 0)
