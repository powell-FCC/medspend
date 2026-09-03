"""MedSpend Phase 1 acceptance test — Playwright + REST DB assertions."""
import asyncio, json, os, sys, urllib.request, urllib.parse
from pathlib import Path
from playwright.async_api import async_playwright, BrowserContext, Page

BASE = "http://localhost:8080"
OWNER_EMAIL = "phase1.owner@medspend.test"
STAFF_EMAIL = "phase1.staff@medspend.test"
PASSWORD = "Test123!phase"
ORG_NAME = "FC Cincinnati Phase 1 Test"
OWNER_ID = "c922b595-5b8e-41f4-bd12-91512f915309"
STAFF_ID = "a6900e53-f4b5-43c2-927d-5c070efb9757"
STORAGE_KEY = os.environ["LOVABLE_BROWSER_SUPABASE_STORAGE_KEY"]

SHOTS = Path("/tmp/browser/phase1"); SHOTS.mkdir(parents=True, exist_ok=True)
RESULTS = {"pass": [], "fail": []}

def check(label, cond, detail=""):
    (RESULTS["pass"] if cond else RESULTS["fail"]).append((label, str(detail)[:200]))
    print(("PASS " if cond else "FAIL ") + label + (f" — {detail}" if detail else ""))

SUPA_URL = os.environ["SUPABASE_URL"]
SR = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
PUB = os.environ["SUPABASE_PUBLISHABLE_KEY"]

def rest(path, params=None, method="GET", body=None):
    url = SUPA_URL + "/rest/v1/" + path
    if params: url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method=method, headers={
        "apikey": SR, "Authorization": f"Bearer {SR}", "Content-Type":"application/json",
        "Prefer":"return=representation"})
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data=data) as r:
            t = r.read().decode()
            return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        return {"__error__": e.read().decode(), "status": e.code}

def get_session(email):
    r = urllib.request.Request(SUPA_URL + "/auth/v1/token?grant_type=password", method="POST",
        headers={"apikey": PUB, "Content-Type":"application/json"},
        data=json.dumps({"email":email,"password":PASSWORD}).encode())
    return json.loads(urllib.request.urlopen(r).read().decode())

async def inject(page: Page, session: dict):
    """Seed the Supabase session BEFORE any app JS runs, via add_init_script on the context.
    This guarantees the Supabase client hydrates with the session on first load."""
    ctx = page.context
    await ctx.add_init_script(
        "window.localStorage.setItem(%s, %s);" % (json.dumps(STORAGE_KEY), json.dumps(json.dumps(session)))
    )
    # Fresh navigation so the init script runs before hydration.
    await page.goto(BASE + "/", wait_until="domcontentloaded")


async def ui_login(page: Page, email: str, expect_off_auth=True):
    """Sign in through the real /auth UI (closest to real user behavior)."""
    await page.goto(BASE + "/auth", wait_until="domcontentloaded")
    await page.wait_for_selector("input[type=email]")
    await page.wait_for_load_state("networkidle")
    await page.wait_for_timeout(400)
    await page.fill("input[type=email]", email)
    await page.fill("input[type=password]", PASSWORD)
    await page.get_by_role("button", name="Sign in").click()
    if expect_off_auth:
        await page.wait_for_function("() => !location.pathname.startsWith('/auth')", timeout=25000)


async def assert_session(page: Page, label: str, expect_id: str, expect_email: str):
    info = await page.evaluate(
        """async (k) => {
            const raw = localStorage.getItem(k);
            if (!raw) return null;
            try { const s = JSON.parse(raw); return { id: s.user?.id, email: s.user?.email, token: !!s.access_token }; }
            catch (e) { return { parseError: String(e) }; }
        }""",
        STORAGE_KEY,
    )
    check(f"{label}: session present in client storage", bool(info and info.get("token")), info)
    check(f"{label}: session user id matches", bool(info) and info.get("id") == expect_id, info)
    check(f"{label}: session email matches invited email", bool(info) and (info.get("email") or "").lower() == expect_email.lower(), info)

async def clear_all(ctx: BrowserContext, page: Page):
    await page.goto(BASE + "/", wait_until="domcontentloaded")
    await page.evaluate("() => { localStorage.clear(); sessionStorage.clear(); }")
    await ctx.clear_cookies()

async def main():
    # ---- Reset test data so the suite always runs from a clean slate ----
    for org in (rest("organizations", {"name": f"eq.{ORG_NAME}", "select": "id"}) or []):
        oid = org["id"]
        for t in ["supply_request_updates", "supply_requests", "organization_invites",
                  "organization_memberships", "teams", "locations", "products", "vendors"]:
            rest(f"{t}?organization_id=eq.{oid}", method="DELETE")
        rest(f"organizations?id=eq.{oid}", method="DELETE")
    rest(f"organization_memberships?user_id=eq.{STAFF_ID}", method="DELETE")
    rest(f"organization_memberships?user_id=eq.{OWNER_ID}", method="DELETE")

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)

        owner_ctx = await browser.new_context(viewport={"width":1280,"height":1800})
        owner_page = await owner_ctx.new_page()
        console_errs = []
        owner_page.on("pageerror", lambda e: console_errs.append(("owner-pageerror", str(e))))
        owner_page.on("console", lambda m: console_errs.append(("owner-console-"+m.type, m.text)))
        owner_page.on("response", lambda r: console_errs.append(("resp", f"{r.status} {r.url}")) if "/auth/v1/" in r.url or "supabase" in r.url else None)

        # 1. UI sign-in for owner — proves email/password flow works
        await owner_page.goto(BASE + "/auth", wait_until="domcontentloaded")
        await owner_page.wait_for_selector('input[type=email]')
        # Wait for React hydration so onSubmit is attached (avoid native form GET submit)
        await owner_page.wait_for_load_state("networkidle")
        await owner_page.wait_for_timeout(500)
        await owner_page.fill('input[type=email]', OWNER_EMAIL)
        await owner_page.fill('input[type=password]', PASSWORD)
        await owner_page.get_by_role("button", name="Sign in").click()
        # Wait up to 25s and capture debug if it fails
        try:
            await owner_page.wait_for_function("() => !location.pathname.startsWith('/auth')", timeout=25000)
            check("owner UI sign-in navigates off /auth", True)
        except Exception:
            await owner_page.screenshot(path=str(SHOTS/"owner_signin_fail.png"))
            check("owner UI sign-in navigates off /auth", False, f"url={owner_page.url}; console={console_errs[-15:]}")
            # Fallback to inject to allow the rest to run
            sess = get_session(OWNER_EMAIL)
            await inject(owner_page, sess)

        # 2. Onboarding -> create org. New user has no memberships, ShellSwitcher redirects to /onboarding.
        try:
            await owner_page.wait_for_url("**/onboarding", timeout=15000)
        except Exception:
            pass  # Already had memberships (shouldn't happen after cleanup)
        if "/onboarding" in owner_page.url:
            await owner_page.wait_for_selector('input[placeholder*="FC Cincinnati"]')
            await owner_page.fill('input[placeholder*="FC Cincinnati"]', ORG_NAME)
            await owner_page.get_by_role("button", name="Create organization").click()
            await owner_page.wait_for_url("**/dashboard", timeout=20000)

        await owner_page.wait_for_load_state("networkidle")
        await owner_page.screenshot(path=str(SHOTS/"01_owner_dashboard.png"))
        check("owner lands on /dashboard", owner_page.url.endswith("/dashboard"), owner_page.url)

        org_rows = rest("organizations", {"name": f"eq.{ORG_NAME}", "select": "id"})
        check("exactly one org exists with that name", isinstance(org_rows, list) and len(org_rows) == 1, org_rows)
        ORG_ID = org_rows[0]["id"] if isinstance(org_rows, list) and org_rows else None
        print("ORG_ID =", ORG_ID)

        shell = await owner_page.get_attribute('[data-shell]', 'data-shell')
        check("AdminAppShell renders for owner", shell == "admin", f"got={shell}")

        mems = rest("organization_memberships", {"organization_id": f"eq.{ORG_ID}", "select": "user_id,role,active"})
        owner_mems = [m for m in mems if m["user_id"] == OWNER_ID]
        check("owner has exactly one membership", len(owner_mems) == 1, owner_mems)
        check("owner membership role = owner", bool(owner_mems) and owner_mems[0]["role"] == "owner")

        # profiles must NOT store role
        profile_cols = rest("profiles", {"id": f"eq.{OWNER_ID}", "select": "*"})
        check("profiles row exists and has no 'role' column", isinstance(profile_cols, list) and profile_cols and "role" not in profile_cols[0], profile_cols[0].keys() if profile_cols else "")

        # 3. Settings + invite
        await owner_page.goto(BASE + "/settings")
        await owner_page.wait_for_selector('input[type=email]')
        await owner_page.fill('input[type=email]', STAFF_EMAIL)
        await owner_page.fill('input[placeholder*="Name"]', "Phase1 Staff")
        await owner_page.get_by_role("button", name="Create invite").click()
        link_el = await owner_page.wait_for_selector('a[href*="/join/"]', timeout=20000)
        invite_url = await link_el.get_attribute("href")
        check("invite link generated", bool(invite_url and "/join/" in invite_url), invite_url)

        # 3b. Teams / Locations CRUD (owner only)
        async def add_structure(section: str, value: str):
            for attempt in range(3):
                await owner_page.wait_for_selector(f'[data-section="{section}"] input')
                await owner_page.fill(f'[data-section="{section}"] input', value)
                await owner_page.click(f'[data-section="{section}"] form button')
                try:
                    await owner_page.wait_for_selector(
                        f'[data-section="{section}"] li:has-text("{value}")', timeout=10000
                    )
                    return True
                except Exception:
                    txt = await owner_page.inner_text(f'[data-section="{section}"]')
                    print(f"  retry {attempt+1} adding to {section}: {txt[:200]!r}")
                    await owner_page.reload()
                    await owner_page.wait_for_load_state("networkidle")
            return False

        check("owner can add a team", await add_structure("teams", "First Team"))
        check("owner can add a location", await add_structure("locations", "Main Training Room"))
        t_rows = rest("teams", {"organization_id": f"eq.{ORG_ID}", "select": "id,name,active"})
        l_rows = rest("locations", {"organization_id": f"eq.{ORG_ID}", "select": "id,name,active"})
        check("team created and scoped to org", len(t_rows) == 1 and t_rows[0]["name"] == "First Team", t_rows)
        check("location created and scoped to org", len(l_rows) == 1 and l_rows[0]["name"] == "Main Training Room", l_rows)
        TEAM_ID = t_rows[0]["id"] if t_rows else None

        # === STAFF context: inject staff session, then open invite ===
        staff_ctx = await browser.new_context(viewport={"width":390,"height":844})
        staff_page = await staff_ctx.new_page()
        staff_page.on("pageerror", lambda e: console_errs.append(("staff-pageerror", str(e))))
        # Real UI sign-in for staff (closest to real user behavior). New staff has no
        # memberships, so the app pushes to /onboarding — that's fine, we then open the invite.
        await ui_login(staff_page, STAFF_EMAIL)
        await assert_session(staff_page, "staff", STAFF_ID, STAFF_EMAIL)

        # Open invite URL (fresh navigation, session already hydrated)
        await staff_page.goto(invite_url, wait_until="domcontentloaded")
        try:
            await staff_page.wait_for_selector("text=Sign in to accept", timeout=2000)
            check("join page sees the authenticated session", False, "join page showed need-auth")
        except Exception:
            check("join page sees the authenticated session", True)
        # Should auto-accept and redirect to /staff
        await staff_page.wait_for_url("**/staff", timeout=20000)
        await staff_page.wait_for_load_state("networkidle")
        await staff_page.screenshot(path=str(SHOTS/"02_staff_after_join.png"))
        check("staff auto-accepts invite and lands on /staff", staff_page.url.rstrip("/").endswith("/staff"), staff_page.url)

        # DB assertions
        org_rows2 = rest("organizations", {"name": f"eq.{ORG_NAME}", "select": "id"})
        check("no duplicate organization created", len(org_rows2) == 1, org_rows2)
        staff_mems = rest("organization_memberships", {"user_id": f"eq.{STAFF_ID}", "select": "organization_id,role,active"})
        check("staff has exactly one membership", len(staff_mems) == 1, staff_mems)
        check("staff membership references ORG_ID", bool(staff_mems) and staff_mems[0]["organization_id"] == ORG_ID)
        check("staff membership role = staff", bool(staff_mems) and staff_mems[0]["role"] == "staff")

        # Invitation accepted_at is set
        invs = rest("organization_invites", {"organization_id": f"eq.{ORG_ID}", "invited_email": f"eq.{STAFF_EMAIL}", "select": "accepted_at,revoked_at,invited_role"})
        check("invitation accepted_at is set", bool(invs) and invs[0]["accepted_at"], invs)

        shell = await staff_page.get_attribute('[data-shell]', 'data-shell')
        check("StaffAppShell renders", shell == "staff", f"got={shell}")

        body = await staff_page.content()
        check("no 'Upload Invoice' in staff view", "Upload Invoice" not in body)
        check("no 'Purchases' admin nav in staff view", ">Purchases<" not in body)
        check("no 'Open requests' widget in staff view", "Open requests" not in body)

        # Submit out-of-stock request
        await staff_page.set_viewport_size({"width": 320, "height": 740})
        await staff_page.goto(BASE + "/staff/request?type=out_of_stock")
        await staff_page.get_by_text("Can't find the item?").click()
        await staff_page.fill('input[placeholder="Enter the item name"]', "Athletic tape 1.5in")
        for _ in range(11):
            await staff_page.get_by_role("button", name="Increase quantity").click()
        await staff_page.get_by_role("button", name="Add to Request").click()
        cart_name = staff_page.get_by_text("Athletic tape 1.5in", exact=True)
        await cart_name.wait_for()
        assert await cart_name.evaluate("el => el.scrollWidth <= el.clientWidth"), "Staff cart truncates the item name at 320px"
        assert await staff_page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), "Staff cart overflows at 320px"
        for action in ["Decrease", "Increase", "Remove"]:
            target = await staff_page.get_by_role("button", name=f"{action} Athletic tape 1.5in", exact=True).bounding_box()
            assert target and target["width"] >= 44 and target["height"] >= 44, f"{action} cart touch target is too small"
        await staff_page.fill('textarea', "Urgent — pregame")
        await staff_page.get_by_role("button", name="Submit Request").click()
        await staff_page.get_by_role("heading", name="Request Submitted").wait_for()
        await staff_page.get_by_role("link", name="View My Requests").click()
        await staff_page.wait_for_url("**/staff/requests", timeout=20000)
        await staff_page.wait_for_load_state("networkidle")
        await staff_page.get_by_text("Athletic tape 1.5in", exact=True).wait_for(timeout=15000)
        await staff_page.screenshot(path=str(SHOTS/"03_staff_submitted.png"))

        srs = rest("supply_requests", {"organization_id": f"eq.{ORG_ID}", "select": "id,organization_id,requested_by,request_type,status,team_id"})
        check("exactly one supply request in org", len(srs) == 1, srs)
        check("request stores selected team_id", bool(srs) and srs[0]["team_id"] == TEAM_ID, srs)
        REQ_ID = srs[0]["id"] if srs else None
        check("request organization_id == ORG_ID", bool(srs) and srs[0]["organization_id"] == ORG_ID)
        check("request requested_by == STAFF_ID", bool(srs) and srs[0]["requested_by"] == STAFF_ID)
        check("request type = out_of_stock", bool(srs) and srs[0]["request_type"] == "out_of_stock")
        body = await staff_page.content()
        check("staff sees request in /staff/requests", "Athletic tape 1.5in" in body)

        # Owner reviews and updates
        await owner_page.goto(BASE + "/supply-requests")
        await owner_page.get_by_role("heading", name="Athletic tape 1.5in", exact=True).wait_for(timeout=15000)
        await owner_page.get_by_role("button", name="Review Request", exact=True).click()
        request_dialog = owner_page.get_by_role("dialog")
        await request_dialog.wait_for(timeout=15000)
        await request_dialog.get_by_role("button", name="Review Request", exact=True).click()
        await request_dialog.wait_for(state="hidden", timeout=15000)

        await owner_page.get_by_role("button", name="Approve or Decline", exact=True).wait_for(timeout=15000)
        await owner_page.get_by_role("button", name="Approve or Decline", exact=True).click()
        await request_dialog.wait_for(timeout=15000)
        await request_dialog.get_by_role("button", name="Approve Request", exact=True).click()
        await request_dialog.wait_for(state="hidden", timeout=15000)

        await owner_page.get_by_role("tab", name="Awaiting Order").click()
        awaiting_order_item = owner_page.get_by_role("heading", name="Athletic tape 1.5in", exact=True)
        await awaiting_order_item.wait_for(timeout=15000)
        await owner_page.get_by_role("button", name="Mark Ordered", exact=True).click()
        await request_dialog.wait_for(timeout=15000)
        await request_dialog.get_by_label("Message to Staff (optional)", exact=True).fill("Ordered from McKesson, ETA 3 days")
        await request_dialog.get_by_role("button", name="Mark Ordered", exact=True).click()
        await request_dialog.wait_for(state="hidden", timeout=15000)
        await awaiting_order_item.wait_for(state="hidden", timeout=15000)
        await owner_page.screenshot(path=str(SHOTS/"04_owner_review.png"))
        srs2 = rest("supply_requests", {"id": f"eq.{REQ_ID}", "select": "status,ordered_at"})
        check("status updated to ordered", bool(srs2) and srs2[0]["status"] == "ordered", srs2)
        check("ordered_at set", bool(srs2) and srs2[0]["ordered_at"])
        updates = rest("supply_request_updates", {"supply_request_id": f"eq.{REQ_ID}", "select": "staff_visible_note,status_to"})
        check("staff-visible note recorded", any((u.get("staff_visible_note") or "").startswith("Ordered from McKesson") for u in updates), updates)

        # Staff sees update
        await staff_page.goto(BASE + "/staff/requests")
        await staff_page.wait_for_load_state("networkidle")
        staff_request_item = staff_page.get_by_text("Athletic tape 1.5in", exact=True)
        await staff_request_item.wait_for(timeout=15000)
        await staff_page.get_by_text("Ordered", exact=True).wait_for(timeout=15000)
        body = await staff_page.content()
        check("staff sees friendly status 'Ordered'", "ordered" in body.lower())
        await staff_request_item.click()
        await staff_page.wait_for_url("**/staff/requests/*", timeout=20000)
        await staff_page.get_by_role("heading", name="Athletic tape 1.5in", exact=True).wait_for(timeout=15000)
        # A fresh document at the detail URL must mount the nested route too.
        await staff_page.reload()
        await staff_page.get_by_role("heading", name="Athletic tape 1.5in", exact=True).wait_for(timeout=15000)
        latest_update = staff_page.locator("section").filter(has=staff_page.get_by_text("Latest Update", exact=True))
        staff_message = latest_update.get_by_text("Ordered from McKesson, ETA 3 days", exact=True)
        await staff_message.wait_for(timeout=15000)
        check("staff sees staff-visible update in request detail", await staff_message.is_visible())
        timeline = staff_page.locator("section").filter(has=staff_page.get_by_role("heading", name="Timeline", exact=True))
        ordered_event = timeline.get_by_role("listitem").filter(has=staff_page.get_by_text("Ordered", exact=True))
        await ordered_event.get_by_text("Ordered", exact=True).wait_for(timeout=15000)
        await ordered_event.get_by_text("Ordered from McKesson, ETA 3 days", exact=True).wait_for(timeout=15000)
        check("staff sees request timeline", await timeline.get_by_role("heading", name="Timeline", exact=True).is_visible() and await ordered_event.is_visible())

        # Route isolation: staff -> admin routes redirect to /staff
        for route in ["/dashboard", "/settings", "/upload", "/purchases", "/invoices", "/products", "/vendors", "/supply-requests"]:
            await staff_page.goto(BASE + route)
            saw_admin = False
            for _ in range(40):
                await staff_page.wait_for_timeout(150)
                if await staff_page.query_selector('[data-shell="admin"]'):
                    saw_admin = True
                if staff_page.url.rstrip("/").endswith("/staff"):
                    break
            check(f"staff visiting {route} redirects to /staff", staff_page.url.rstrip("/").endswith("/staff"), staff_page.url)
            check(f"staff visiting {route}: AdminAppShell never rendered", not saw_admin)
            shell_now = await staff_page.get_attribute("[data-shell]", "data-shell")
            check(f"staff visiting {route}: StaffAppShell rendered", shell_now == "staff", shell_now)
            # Let the redirect settle so we assert on the final staff DOM, not mid-transition markup.
            await staff_page.wait_for_load_state("networkidle")
            await staff_page.wait_for_timeout(500)
            b = await staff_page.content()
            check(f"staff visiting {route}: no Upload Invoice action", "Upload Invoice" not in b)
            check(f"staff visiting {route}: no admin nav labels", ">Vendors<" not in b and ">Purchases<" not in b)

        # Sign out through the UI and sign back in normally
        await staff_page.goto(BASE + "/staff")
        await staff_page.get_by_role("button", name="Sign out").click()
        await staff_page.wait_for_url("**/auth**", timeout=20000)
        check("staff sign-out returns to /auth", "/auth" in staff_page.url, staff_page.url)
        await ui_login(staff_page, STAFF_EMAIL)
        for _ in range(50):
            await staff_page.wait_for_timeout(150)
            if staff_page.url.rstrip("/").endswith("/staff"):
                break
        check("staff re-login lands directly on /staff", staff_page.url.rstrip("/").endswith("/staff"), staff_page.url)
        sess_staff2 = get_session(STAFF_EMAIL)
        await staff_page.goto(BASE + "/dashboard")  # will trigger role redirect
        for _ in range(50):
            await staff_page.wait_for_timeout(150)
            if staff_page.url.rstrip("/").endswith("/staff"):
                break
        check("staff re-login lands on /staff (role redirect from /dashboard)", staff_page.url.rstrip("/").endswith("/staff"), staff_page.url)
        active_id = await staff_page.evaluate("() => localStorage.getItem('medspend.activeOrgId')")
        check("active org auto-resolved to ORG_ID", active_id == ORG_ID, active_id)
        org_rows3 = rest("organizations", {"name": f"eq.{ORG_NAME}", "select": "id"})
        check("no duplicate organization created after re-login", len(org_rows3) == 1)

        # Stale/inaccessible localStorage active org
        await staff_page.evaluate("(id) => localStorage.setItem('medspend.activeOrgId', id)", "00000000-0000-0000-0000-000000000000")
        await staff_page.goto(BASE + "/staff")
        await staff_page.wait_for_load_state("networkidle")
        # It should not adopt the bogus id; only one real membership exists so the app should resolve to ORG_ID.
        active_id2 = await staff_page.evaluate("() => localStorage.getItem('medspend.activeOrgId')")
        check("app discards inaccessible active-org id (auto-resolves single membership)", active_id2 == ORG_ID, active_id2)
        n_orgs = len(rest("organizations", {"name": f"eq.{ORG_NAME}", "select": "id"}))
        check("stale localStorage did not spawn a new organization", n_orgs == 1)

        # Invite reuse blocked
        await staff_page.goto(invite_url)
        await staff_page.wait_for_load_state("networkidle")
        body = await staff_page.content()
        check("invite reuse blocked (already accepted)", "already accepted" in body.lower() or "already" in body.lower(), body[body.lower().find("invitation"):body.lower().find("invitation")+200] if "invitation" in body.lower() else body[:200])

        # Email mismatch invite
        await owner_page.goto(BASE + "/settings")
        await owner_page.wait_for_selector('input[type=email]')
        await owner_page.fill('input[type=email]', "other.person@example.com")
        await owner_page.fill('input[placeholder*="Name"]', "Someone Else")
        await owner_page.get_by_role("button", name="Create invite").click()
        link_el2 = await owner_page.wait_for_selector('a[href*="/join/"]', timeout=15000)
        mismatch_url = await link_el2.get_attribute("href")
        await staff_page.goto(mismatch_url)
        await staff_page.wait_for_load_state("networkidle")
        body = await staff_page.content()
        check("email-mismatch invite rejected", "does not match" in body.lower() or ("email" in body.lower() and "match" in body.lower()) or "not found" in body.lower(), body[body.lower().find("email"):body.lower().find("email")+300] if "email" in body.lower() else body[:300])

        # Negative test: staff cannot submit to another org — call submit RPC directly with a foreign org id
        # Use staff bearer token
        r = urllib.request.Request(BASE + "/_serverFn/", method="GET")
        # Simpler: call the server fn via HTTP directly is complex — instead exercise DB via authed REST:
        # PostgREST as staff: try inserting supply_request with organization_id = random UUID. Should be blocked by RLS.
        try:
            req = urllib.request.Request(SUPA_URL + "/rest/v1/supply_requests", method="POST",
                headers={"apikey": PUB, "Authorization": f"Bearer {sess_staff2['access_token']}",
                         "Content-Type":"application/json", "Prefer":"return=representation"},
                data=json.dumps({"organization_id":"00000000-0000-0000-0000-000000000000",
                                 "requested_by": STAFF_ID, "request_type":"reorder", "free_text_item":"foo"}).encode())
            urllib.request.urlopen(req).read()
            check("RLS blocks cross-org insert by staff (direct REST)", False, "insert unexpectedly succeeded")
        except urllib.error.HTTPError as e:
            check("RLS blocks cross-org insert by staff (direct REST)", e.code in (401,403,409,400,404,406,500,42501), f"status={e.code}")

        # Owner can read all requests in org (already validated via UI). Staff can read only their own via RLS:
        req = urllib.request.Request(SUPA_URL + "/rest/v1/supply_requests?select=id,requested_by",
            headers={"apikey": PUB, "Authorization": f"Bearer {sess_staff2['access_token']}"})
        with urllib.request.urlopen(req) as r:
            rows = json.loads(r.read().decode())
        check("staff RLS: only own requests visible", all(x["requested_by"] == STAFF_ID for x in rows) and len(rows) >= 1, rows)

        # Membership deactivation — mark staff membership inactive, verify staff loses access
        rest(f"organization_memberships?user_id=eq.{STAFF_ID}&organization_id=eq.{ORG_ID}",
             method="PATCH", body={"active": False})
        # Fresh session, fresh page
        await clear_all(staff_ctx, staff_page)
        await ui_login(staff_page, STAFF_EMAIL, expect_off_auth=False)
        await staff_page.wait_for_timeout(2500)
        await staff_page.goto(BASE + "/staff")
        await staff_page.wait_for_load_state("networkidle")
        # After deactivation, no active memberships => app should push to /onboarding
        for _ in range(40):
            await staff_page.wait_for_timeout(150)
            if "/onboarding" in staff_page.url:
                break
        check("inactive membership removes access (redirects to /onboarding)", "/onboarding" in staff_page.url, staff_page.url)
        # Reactivate for cleanup
        rest(f"organization_memberships?user_id=eq.{STAFF_ID}&organization_id=eq.{ORG_ID}",
             method="PATCH", body={"active": True})

        (SHOTS/"summary.json").write_text(json.dumps({
            "org_id": ORG_ID, "req_id": REQ_ID,
            "passes": len(RESULTS["pass"]), "fails": len(RESULTS["fail"]),
            "fail_list": RESULTS["fail"],
        }, indent=2))
        await browser.close()

    print("\n==== SUMMARY ====")
    print(f"PASS: {len(RESULTS['pass'])}   FAIL: {len(RESULTS['fail'])}")
    for l,d in RESULTS["fail"]:
        print(f"  FAIL: {l} — {d}")
    sys.exit(1 if RESULTS["fail"] else 0)

asyncio.run(main())
