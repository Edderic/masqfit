# Anonymous contributions

## User flows

From **Contribute Data**, choose **Measure only**, **Contribute anonymously**, or the existing **Use an account** flow.

Measure only shows five path measurements in millimeters, with copy, CSV sharing, rescan, and next-participant actions. It does not create an identity or queue a submission. Measurements remain in memory; an explicitly shared CSV is temporarily written with file protection and removed when sharing finishes. Clipboard copies expire after five minutes and do not use Universal Clipboard.

Anonymous contribution creates a participant-held 256-bit recovery code, or reads a saved code. Save it through the system share sheet as text and a QR image. The active code is forgotten when finishing or starting another participant. There is no name/email recovery. Possession of the code allows additional contributions under that identity and access to its latest saved facial measurements. It does not provide fit-test history.

Scan a face (or reuse saved measurements when returning), optionally import MFTC fit tests, review the five measurements and selected tests, and explicitly consent to submission. The queue is accessible from the anonymous workflow. Swipe a queued/failed item to remove it, or remove a submitted receipt. Local removal does not retract data already received by the server.

The app can retry while running and when reopened; iOS does not guarantee delivery while it is closed. Queued data and receipts use protected Application Support files excluded from backups. Queued credentials use Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility. Successful delivery deletes the queued payload and credential, retaining a local receipt. A corrupt queue is surfaced and never silently overwritten.

## Data contract

`POST https://www.breathesafe.xyz/anonymous_contributions`

- `Authorization: Bearer <64 lowercase hex characters>`; no account cookies.
- JSON envelope: `{"contribution": {...}}`.
- Contribution fields: `contribution_id` (UUID), `measurement_version` (`1`), `measurements`, `fit_tests`, `consent_version` (`anonymous-2026-09-14`), and `consent_accepted_at` (ISO-8601).
- Measurements: `nose_mm`, `strap_mm`, `top_cheek_mm`, `mid_cheek_mm`, `chin_mm`; all finite and positive.
- Fit test: `exercises` (keys `1`–`12`, numeric scores), optional `final`, `status` (`completed` or `incomplete`), reviewed `mask` and `protocol_name` strings, optional confirmed `mask_id`.
- A reported valid final yields `completed`. Aborted exercises are excluded from numeric scores; their test remains incomplete. No inferred final score or pass/fail classification is generated.
- Success: `{"contribution_id":"...","status":"submitted"}`. The same ID and payload can be retried safely. Conflicting reuse returns 409. Invalid fields return 422; missing credentials return 401; oversized bodies return 413.
- Request bodies are bounded to 256 KiB, at most 100 tests, and 200 characters per reviewed text field.

BreatheSafe stores anonymous participants and contributions separately from account-based users and fit tests. Only a SHA-256 digest of the recovery credential is stored. Request parameters containing contributions or credentials are filtered from Rails logs. Existing infrastructure access logs may still record connection metadata; an unnamed reusable identity is linkable across visits.

Catalog matching uses `GET /anonymous_contributions/masks?search=...&page=1`; it sends only a user-entered catalog search, not the original MFTC participant or mask label. Unmatched masks remain unresolved. Admin-only `GET /anonymous_contributions/export?after_id=...` returns up to 500 contributions plus `next_after_id`. It excludes credential and payload digests. This release does not automatically feed the records into model training.

## MFTC compatibility

Both `algorhythmical.github.io` and `emcee5601.github.io` exports encode a JSON array using LZ-string `compressToEncodedURIComponent` in the `data` query of `/view-results`, usually inside a URL fragment. The importer decodes the URL locally without opening it. It supports camera scanning and image import from Files, including screenshots containing multiple QR codes.

The bounded Swift decoder handles UTF-16, numeric values, numeric strings, and `aborted` exercise markers. Unknown formats are rejected. Raw participant labels appear only during local selection. Notes, original IDs/timestamps, device IDs, particle counts, and unknown fields are omitted from persisted contributions. Repeat-scan detection uses an in-memory source fingerprint; it is not uploaded.

Sources checked during implementation:

- https://github.com/algorhythmical/fit-test-console/blob/main/src/ReactTableQrCodeExportWidget.tsx
- https://github.com/emcee5601/fit-test-console/blob/main/src/ReactTableQrCodeExportWidget.tsx
- https://github.com/algorhythmical/fit-test-console/blob/main/src/SimpleResultsDB.ts

The completed/aborted fixtures derive from the two supplied QR screenshots, with participant names, dates, IDs, notes, mask names, and particle counts replaced or removed before committing. Fixtures for both hosts use the same export encoding. Additional fixtures exercise Unicode, invalid types, and excessive decompression. LZ-string 1.5.0 generated the fixtures; no JavaScript runtime or downloaded decoder dependency is shipped in the app.

## Verification and release

Run the standalone macOS core and mocked queue tests:

```sh
sh scripts/test-anonymous-core.sh
```

In BreatheSafe, run the new migration against a local test database and:

```sh
bundle exec rspec spec/requests/anonymous_contributions_spec.rb
```

Before release:

1. Deploy BreatheSafe migration `20260915010000` and API, following that repository's deployment process. Verify a synthetic contribution, a retry with the same ID, and the authenticated admin export.
2. Build the app with a working Xcode installation. The implementation environment's `xcodebuild` fails loading `IDESimulatorFoundation` due to an incompatible `DVTDownloads` framework; direct Swift type-checking is available.
3. On a TrueDepth device, verify both modes, front/rear camera transitions, denied camera access, image import, saved-code recovery on another phone, participant switching, consent cancellation, airplane-mode submission, relaunch/retry, CSV sharing, and the existing account/recommendation flows.
4. Release the app after backend readiness. Positioning accuracy experiments and automatic research/model ingestion remain separate work.

## Deployment record

Deployed on September 15, 2026:

- Commit: `bd27b1305a0cc71793734d6a160333ba991d390a`, published on BreatheSafe's `anonymous-contributions-production` branch.
- Staging: Heroku release `v155`.
- Production: Heroku release `v554`, status `succeeded`.
- Migration `20260915010000` completed through the Heroku release phase in both environments.
- Release checks: 325 Ruby tests and 32 Python tests passed; lint passed for 239 Ruby files. Python checks required `OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1` to avoid a native crash in the local ML environment.
- Both environments passed creation, idempotent retry, and field-validation smoke tests. Synthetic records were rolled back. The public production POST route returned the expected 401 for a request without a participant credential.

The release branch has not been merged into `main`; include this commit in subsequent releases to retain the endpoint. The source workspace's existing changes were left in place.

An iPhone queue item already marked failed after the former 404 is still skipped by the current app's Retry action. Deployment enables new submissions but does not change that saved client-side state; preserve the item for a retry-handling update.

## Suggested masks and admin proposals

MFTC review now offers **Find matches** after the user removes identifying text. Only the reviewed mask name goes to the suggestion endpoint. The highest-ranked canonical catalog match is presented for explicit confirmation; users can reject it, search alternatives, keep the mask unresolved, or propose a new model. Even exact matches require confirmation. Proposing a mask does not submit anything: the proposal travels with the consented contribution and survives offline queueing.

Backend changes are implemented locally, **not yet deployed**:

- `GET /anonymous_contributions/mask_suggestions?name=...` returns up to five candidates. It uses the existing import similarity scorer on name tokens, including size-conflict penalties, without calling the predictor service. Scores are suggestions, not confidence probabilities.
- Optional `propose_mask: true` on a fit test requires a nonempty reviewed mask label and no `mask_id`. Existing unresolved/matched payloads remain compatible.
- Migration `20260917010000` creates proposals and links to contribution/test positions. Names are grouped by Unicode-normalized, case-insensitive, whitespace-normalized text. This conservative grouping avoids merging different sizes/colors.
- **Admin → Mask Proposals** (`/#/admin/masks/proposals`) lets admins suggest/search canonical entries or create a reviewed mask. A transaction updates all linked anonymous fit tests and records the reviewer. Future submissions of a previously resolved proposal inherit that decision. Original payload digests stay unchanged so lost-response retries remain valid.
- One background notification job is scheduled per new proposal. Confirmed admin accounts receive a review link and mask name only. A locked `notified_at` check suppresses normal duplicate job delivery; as with SMTP generally, a crash after email delivery but before recording success can still duplicate a message. `bundle exec rake mask_proposals:notify_pending` recovers unsent notifications after queue failures or when admin recipients become available.
- Deployment requires the migration, backend/frontend release, and a functioning Sidekiq worker before releasing the updated iOS app. Tests use test email delivery; no production emails were sent.

Additional device checks: reject a suggestion and choose an alternative; propose a new mask offline; cancel submission and verify no proposal is created; submit and confirm it appears in admin review; resolve it and verify the export includes the reviewed catalog ID/name.

Implementation validation: 338 Rails examples passed in the isolated release checkout; the final focused contribution/proposal suite passed 26 examples. All 133 Swift core/queue checks, full-app Swift type-checking, changed-file Ruby lint, and the Vue production build passed. The 20 backend source/documentation/test files were hash-verified when copied into the BreatheSafe source checkout. A full Xcode build and device interaction checks still require the working device-development setup described above.

## Optional testing mode

Each selected MFTC fit test displays **Testing mode: Unknown** and a **Change testing mode** button. Before submission, users can choose **N95**, **N99**, or **Unknown** independently for each test. The prompt distinguishes instrument mode from the mask's filtration rating. The final consent summary includes the choice; nothing is inferred from the mask label or protocol.

New fit-test payloads include `testing_mode: "n95"`, `"n99"`, or `"unknown"`. Backend validation accepts only these values when supplied and preserves them in the existing JSON field and admin export; no database migration is needed for this field. Missing mode fields remain valid for older clients. Old queued payloads retain an absent field when re-encoded, preserving their original retry digests.

Validation: 141 Swift core/queue checks and 28 focused Rails request examples passed, along with full-app Swift type-checking and changed-file Ruby lint. Backend deployment is required before testing new payloads against production; device UI testing remains pending.

## Classified search update

The catalog picker now prefills the reviewed imported name and automatically requests suggestions. Editing and submitting any nonempty search uses the same suggestion endpoint; an empty search browses the catalog. Original reviewed text is preserved for confirmation and proposals.

The accompanying backend change uses the existing trained token classifier and weighted component matcher, ignoring color during classified ranking while retaining fit-related attributes and model suffixes. Catalog annotations take priority over cached predictions. Missing classifications are prepared by a background job; prediction failures/timeouts fall back to name-based matching. Deploy the backend and warm the catalog cache before shipping this app update (see BreatheSafe's `MASK_PROPOSALS.md`). These new classification changes have not yet been deployed.

## Reusing previous facial measurements

Returning participants load their latest saved original measurements by default after scanning or pasting their participant code. The screen shows **Use my previous measurements**, the five values, their original submission date, and **Scan again**. The final consent review distinguishes reused measurements from a new scan. New participants and codes without saved measurements require a scan. Looking up measurements never submits data or creates a participant.

`GET /anonymous_contributions/previous_measurements` uses the same bearer code as submissions, has `Cache-Control: no-store`, and returns `{"previous_measurements": null}` or an object with `contribution_id`, `measurement_version`, `measurements`, and `consent_accepted_at`. It returns no fit-test history. Anyone holding the participant code can retrieve these measurements, so the app tells participants to keep the code private. Responses stay in memory until cleared or consented into the protected queue; the lookup uses no cookies or response cache.

Lookup requires connectivity and a successfully delivered original contribution. Pending offline scans are not available through lookup. Failures offer retry or a new scan; they are not treated as an empty history. Switching participants or starting a scan invalidates pending lookup responses. Canceling a rescan preserves already loaded previous measurements.

Reused submissions include optional `measurement_source_contribution_id` with the original contribution UUID, plus a fixed snapshot of all five measurements. The backend requires the source to belong to the same participant, be an original scan, and match the submitted version and values. Queue retries retain that exact snapshot and source, even after a newer scan is submitted. Older payloads omit the new field and keep their existing retry digests. Admin exports include provenance so reuse need not be counted as a new scan.

The latest original is selected by original consent/submission time, then database ID; reused submissions and older offline scans delivered later do not advance the original scan date. This is a submission date, not a claim about the exact capture time. No maximum age is enforced; participants can scan again when measurements change.

Deploy migration `20260929010000_add_measurement_source_to_anonymous_contributions.rb` and the backend lookup/validation before releasing this app update. Device checks: recover a code on a later visit; confirm default reuse; scan again; cancel a rescan; switch participants during lookup; test no history, unavailable network, offline queue retries, and consent cancellation.
