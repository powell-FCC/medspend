# Phase 7A.2: QR inventory physical counts

SportSpend does not ask staff to log routine consumption. It asks them to periodically correct reality: scan a storage location's QR label, check every item there, and save one count.

## The model

- **A count is a complete snapshot of one storage location.** Saving means "I physically checked every item shown here". Fields start at the system quantity; staff change only what differs. A blank field is an error, never zero, unchanged or skipped. The server requires the submitted items to be exactly the location's countable items.
- **Counts are absolute.** System 12, counted 9: the location becomes 9 and the organization total drops by 3. Nothing is inferred about why (used, lost, damaged).
- **Every line is recorded, unchanged ones included.** `inventory_count_sessions` (who, where, when, how many lines and changes, request key and hash) and `inventory_count_lines` (previous, counted, delta, observed version, item snapshot) are immutable. Each line also writes one `physical_count` row in `inventory_adjustments` (reason `Physical count`), even when the delta is 0, linked one-to-one by `inventory_count_line_id`.
- **Zero-change counts are checkpoints.** The existing 7A.1 invoice-deletion guard refuses to delete a receipt that a later `physical_count` row covers. Because zero-delta lines write that row, "counted 12, still 12" blocks deleting an earlier receipt just like a correction does. `delete_invoice_permanently` is unchanged.
- **Unassigned is never counted.** It isn't a physical place and has no labels.

## Which items appear

A storage location's balance rows are its V1 membership:

| Item     | Balance at the location | Countable               |
| -------- | ----------------------- | ----------------------- |
| active   | any, including 0        | yes                     |
| archived | above 0                 | yes (shown as Archived) |
| archived | 0                       | no                      |

Count history never changes membership: an item confirmed at zero stays on the list, so stock that was never recorded can still be entered against a zero system balance. (Removing an item from a location is future Inventory Admin work.)

## Staleness and concurrency

The count page returns each item's balance `version`; the submission echoes them. `submit_inventory_count` locks items (id order), then the location (`FOR UPDATE`, which waits for in-flight moves, adjustments and archives touching it), recomputes the countable set and rejects the count unless the item set and every version match exactly: "Inventory changed while you were counting. Reload this location and confirm the quantities again." No merging. Zero-delta lines still bump versions, so two simultaneous counts of one location cannot both succeed. Receipts land in Unassigned and never make a storage-location count stale.

Idempotency: the request hash is SHA-256 over organization, location and the sorted (item, observed version, canonical quantity) lines, with quantities `trim_scale`d so `1`, `1.0` and `1.00` are one count. The same key with the same hash returns the original summary (`replayed: true`); the same key with anything else is refused.

The stale error uses SQLSTATE `55000`, not `40001`: PostgREST retries serialization failures, which would leave the person waiting instead of telling them to reload.

## QR labels

- A label is a 32-byte random token, base64url (43 characters), in the URL `https://app.sport-spend.com/count/<token>`. It encodes no organization, user or quantity.
- Only its SHA-256 hash is stored (`inventory_location_labels`); the raw token is returned once, when issued. Printing another copy means issuing another label; a location may have several active labels.
- **A token never authorizes anything.** `resolve_inventory_count_label` hashes the token, finds the label, and returns details only to an active member of the label's organization. Unknown tokens, malformed input and other organizations' labels all return the same bare `unavailable`. Members see `replaced` for a revoked label and `location_unavailable` while its location is archived (restoring makes it work again; revocation is permanent).
- Owners issue labels, issue additional ones, and "Replace labels" (revoke every label for the location, then issue a new one) from the Inventory page's locations panel. Admins and staff cannot.

## Routes and sign-in

- `/count`: Scan Inventory QR (in both the staff and admin shells, so owners and admins can count too). The camera starts on a tap (rear camera). If it can't (denied, no camera, unsupported browser), the page explains how to use the phone's own camera app and lists the organization's storage locations.
- `/count/<token>`: a scanned label. The server resolves the token for members only; the page then makes that organization active and opens the count. It skips the usual `/select-organization` step so multi-organization users don't lose the link.
- `/count/location/<id>`: a location chosen from the list.
- Signed-out users go through `/auth?redirect=…`. Google sign-in returns to the site root, so the path waits in `sessionStorage` (15 minutes, same-site paths only, re-validated when read) and the root route resumes it once a session exists.

## Scanner

- The printed label works with the ordinary phone camera; no app code is involved.
- In the app: the browser's `BarcodeDetector` when it supports `qr_code` (Chrome on Android, Chrome on macOS); otherwise (Safari on iPhone, Firefox) the `barcode-detector` ponyfill and its zxing-wasm decoder. That code and `zxing_reader.wasm` (~1.1 MB) load only when the scanner opens, and the `.wasm` is emitted into this app's own assets: `prepareZXingModule({ overrides: { locateFile } })` replaces the library's default jsDelivr URL. Only count links (`/count/<43-char token>`) or bare tokens are accepted; the scanner extracts the token and opens it inside the app, never following the scanned URL.
- Pinned: `barcode-detector` 3.2.2, `zxing-wasm` 3.1.3 (the version 3.2.2 bundles), `qrcode` 1.5.4 for printing labels.

## Staff read hardening (7A.2-0)

`inventory_items_member_select` let every member read active inventory rows directly through the API, including purchase prices. Staff now read request-line inventory names through `get_supply_request_inventory_identities` (name, unit, manufacturer, vendor name, SKU, active; active items only unless the caller is an owner), and the policy is dropped by a separate migration applied after the deploy. Counts never expose prices, vendors, par levels, organization totals, other locations or history.

## 7A.1 polish

- The move dialog no longer keeps an emptied source after a move: when refreshed balances leave the chosen source without stock, it falls back to the first location that has some and clears the destination.
- The inventory table names Unassigned whenever it holds stock: `Unassigned`, `<Location>`, `<Location> + Unassigned`, `N locations`, `N locations + Unassigned`, or `No stock`.

## Deferred

The intermittent React hydration warning (#418) and the Low Stock filter overflow at narrow widths predate 7A.1 and 7A.2; no evidence ties them to either. Not changed here.

## Tests

- `supabase/tests/phase7a2_inventory_physical_counts_behavior.sql`: labels, resolution, countable rule, every invalid submission, a mixed count, idempotency, staleness, checkpoints, hardening, grants.
- `phase7a2_mutation_check.sh`, `phase7a2_race_check.sh` (two sessions: moves, adjustments, receipts, archives, simultaneous counts and retries during a count), `phase7a2_release_check.sh` (release scripts as the SQL Editor sends them).
- `run_phase7a2_count_integration.sh`: the same calls through PostgREST with real JWTs for owner, admin, staff, another organization's owner, a non-member and anon.
- `run_phase7a1_old_app_compat.sh`: the deployed 7A.1 application against the 7A.2 schema.
- `tests/phase7a2-inventory-physical-counts.test.ts`: helpers, an offline QR encode/decode round trip with the bundled `.wasm`, sign-in return, routing, structure, rendered UI.
