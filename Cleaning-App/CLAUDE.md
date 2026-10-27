# Silver Air Cleaning Desk

Web app Silver Air Private Jets uses to schedule aircraft cleanings with outside cleaning vendors.
Silver Air staff create cleaning jobs; each vendor signs in with a company passcode and only sees
and updates its own jobs (accept, decline, start, complete, invoice, photos, comments).

Owner: Austin (People and Culture, Silver Air). Austin is not a developer. When something has to be
done by hand (Supabase dashboard, GitHub settings, Resend, DNS), give short click by click steps.
Write user facing copy (UI text, emails, instructions) in plain, friendly language and avoid dashes.

## Where things live

| Thing | Location |
|---|---|
| Live app | https://silverairprivatejets.github.io/Cleaning-App/ (GitHub Pages, `main` branch, repo root) |
| Repo | github.com/SilverAirPrivateJets/Cleaning-App (PUBLIC, see Security) |
| Database | Supabase project `yosioojtuzvchvzdmrpt` (https://yosioojtuzvchvzdmrpt.supabase.co), free plan |
| Email | Resend (free plan, 3,000/month, 100/day), called from a Supabase Edge Function |

## Files

- `index.html`: the entire front end. Plain HTML, CSS and JS in one file, no build step.
  Loads `@supabase/supabase-js@2` from jsdelivr. Pushing to `main` deploys it (Pages takes 1 to 2 minutes).
  The file MUST stay named `index.html` at the repo root.
- `logo-email.png`: white logo used in the email header (loaded by URL from the live site). Keep the name.
- `brand/logo-full.svg`, `brand/logo-mark.svg`: logo rebuilt as vectors from the brand guide. Both use
  `fill="currentColor"`. The full logo is also inlined in `index.html` (header and sign in screen),
  and the mark is the favicon (orange).
- `supabase/01-setup.sql`: tables, row level security, passcode functions, all `desk_*` RPCs. Idempotent.
- `supabase/02-notifications.sql`: pg_net trigger that tells the Edge Function to email vendors. Idempotent.
- `supabase/03-invoices-billing-alerts.sql`: invoice uploads, the ASM billing question and answer, "seen"
  tracking for in app alerts, billing email settings, and a new version of the email trigger. Idempotent.
- `manifest.webmanifest`, `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`, `apple-touch-icon.png`:
  lets people add the app to their phone home screen (no service worker, no offline mode).
- `supabase/functions/notify-vendor/index.ts`: Edge Function that formats and sends emails through Resend.

01 and 02 have been run on the live project. 03 was delivered on Oct 27, 2026; confirm with Austin it was run. For schema changes, add a NEW numbered file
(`03-....sql`) rather than editing history, keep it idempotent (`create or replace`, `if not exists`),
and tell Austin to paste it into Supabase > SQL Editor > New query > Run. There is no Supabase CLI
link set up, so you cannot run SQL or deploy functions yourself unless that gets configured.

## Architecture

### Access model (passcodes, no user accounts)
- Nobody needs an account. People enter their name (stored only in the browser, used to label activity)
  and a passcode.
- Passcodes live in `private.codes` as bcrypt hashes (`pgcrypto` `crypt`, `gen_salt('bf', 8)`), keyed by
  `who`: `admin`, `staff`, or `vendor:<vendor id>`. All codes must be unique, at least 6 characters.
- Roles: `admin` (everything incl. Settings and passcodes), `staff` (all jobs, create and manage, no Settings),
  `vendor` (only jobs where `jobs.vendor_id` matches).
- Bootstrap admin code `ChangeMe123` (in 01-setup.sql). While it is in use, `desk_load` returns
  `mustChange` and every other RPC raises `must_change` until a new admin code is set. It has already
  been changed on the live project; the insert uses `on conflict do nothing` so re running is safe.
- The browser keeps the passcode in sessionStorage, or localStorage if "Keep me signed in" is checked.

### Database
- Every table has RLS on and NO grants to `anon`/`authenticated`. The front end never touches tables.
- All reads and writes go through `SECURITY DEFINER` functions in `public` named `desk_*`, each taking
  `p_code` first. `private.whoami(code)` resolves the role; `private.auth(code)` does the same but rejects
  the temporary admin code. Wrong code: `pg_sleep(0.5)` then `raise exception 'bad_code'`.
- Errors are raised as short snake_case codes (`bad_code`, `must_change`, `not_allowed`, `not_found`,
  `bad_transition`, `bad_vendor`, `bad_tail`, `code_in_use`, `code_too_short`, `photo_too_big`).
  `writeErr()` in index.html maps them to friendly messages. Keep that contract when adding functions,
  and remember to `grant execute ... to anon, authenticated` on any new `desk_*` function.
- Tables (most content is jsonb `data` so fields can be added without migrations):
  - `vendors(id text pk, data)`: name, legalName, contact, phone, email (comma separated list, gets alerts), address, airports[]
  - `fleet(tail text pk, data)`: type, model, year, serial, size, homeBase, notes, order
  - `config(id=1, data)`: services[], airports[{icao,fbo}]
  - `jobs(id text pk, vendor_id, data, updated_at)`: tail, airport, fbo, start, due (local airport time
    strings like `2026-09-26T08:00`, no time zone), services[], notes, ref (`SA-MMDD-XXXX`), status,
    quote, invoiceNo, invoiceAmount, declineReason, completionNote, requestedBy, timestamps,
    photos[{id,kind,at,by}], activity[{at,by,as,type,text}] (capped at last 150)
  - `photos(id, job_id fk cascade, kind before|after, data text)`: JPEG data URLs, resized in the browser
    to max 1400px at quality 0.72, max 2.5 MB each. Fetched on demand with `desk_photo_get`.
  - `invoices(id, job_id fk cascade, name, mime, data text)`: one per job (replacing deletes the old one).
    PDF as uploaded, or photos converted in the browser to JPEG up to 2400px. Max about 8 MB.
  - `private.codes`, `private.settings` (notify_url, notify_secret, billing_email, charge_notify_email)
  - `private.charge_tokens(token, job_id, created_at, used_at)`: the private link ASM uses, 48 hex chars,
    valid 120 days, one current token per job.
- Job data added in 03: `seen {vendor, silverair}` (timestamps), `invoiceFile {id,name,mime,size,at,by}`,
  `chargeRequestedAt`, `charge {to: owner|client, note, by, at, via: email|app}`.
- Status flow: requested > accepted > in_progress > completed > invoiced, plus declined and cancelled.
  `desk_job_update` enforces vendor transitions server side and whitelists which fields each role may change.
  Vendors can only reach "invoiced" by uploading a file through `desk_invoice_add`.

### In app alerts
- A job is "New" for a vendor until they open it, and "Updated" for either side when the newest activity
  from the other side is later than their `seen` timestamp. Opening the job calls `desk_job_seen`.
  The seen mark is shared by everyone on that side (all users of one vendor code, or all of Silver Air).
- Shown as: orange tag on the row, a banner with "Show them", a count on the Jobs tab, the count in the
  browser tab title, and a toast when the 30 second refresh finds something new. No push notifications.

### Invoices and billing
- After "completed", the vendor (or Silver Air on their behalf) uploads the invoice file with number and amount.
  This sets status invoiced, creates a new charge token, and sets `chargeRequestedAt`, which emails ASM.
- The invoice can be replaced until someone decides who to charge.
- ASM's email has the invoice attached (the Edge Function fetches it with `desk_notify_invoice`, which checks
  `DESK_SECRET`) and a button to `APP_URL?charge=<token>`. That page needs no passcode; it shows the job,
  lets ASM view the invoice, pick Owner or Client, add a note and their name. It uses `desk_charge_info`,
  `desk_charge_invoice`, `desk_charge_decide`. The link never acts on a plain click, so email link scanners
  (like Microsoft Safe Links) can't answer it by accident.
- Once decided, `charge` is set and the billing contact is emailed. Silver Air can also set or change the
  choice in the job drawer (`desk_charge_set`) or email ASM again (`desk_charge_request`).
- Vendors never see `charge`, `chargeRequestedAt`, or activity of type `charge` (`private.for_vendor` strips them).
- Billing addresses are edited by the admin under Settings > Billing emails (`desk_settings_save`).
  Defaults: billing team `asm@silverair.com`, billing contact `austin.razor@silverair.com`.
- Live updates: the app polls `desk_load` every 30 seconds and when the tab regains focus (no Realtime,
  since RLS blocks it by design).

### Email notifications
- Trigger `jobs_notify` (after insert or update on `public.jobs`) runs `private.job_notify()`, which decides
  what to send and calls `net.http_post` (pg_net) to the Edge Function with header `x-desk-secret`.
  The whole trigger body is wrapped so email problems never block saving a job.
- Vendor emails go out for: `new` (job created), `assigned` (moved to them), `removed` (moved away
  while still open), `changed` (Silver Air edit), `cancelled`, `reopened`, `comment` (Silver Air comment).
  Vendor actions and Silver Air acting on the vendor's behalf do not email vendors.
- Billing emails: `invoice` to the billing team (with attachment and the charge link), and `charge` to the
  billing contact once Owner or Client is chosen. Detection uses the newest
  activity entry (`as = 'Silver Air'`, `type`) and status changes.
- Edge Function secrets (Supabase > Edge Functions > Secrets): `RESEND_API_KEY`, `DESK_SECRET` (must equal
  `private.settings.notify_secret`), optional `EMAIL_FROM`, `TEST_TO`, `APP_URL`, `REPLY_TO`.
  JWT verification is turned OFF for this function; the shared secret protects it.
- `TEST_TO` set = every email goes only to that address with a `[TEST for <vendor>]` subject. Until a domain
  is verified in Resend, Resend only delivers to the account owner's address.

## Brand (Silver Air Brand Style Guide, 06.2026, by AudienceX)
- Colors: Orange `#FD9600` (primary), Light Gray 1 `#A2A4A3`, Light Grey 2 `#CECFCB`, Cyan `#009CDD`.
- Headings: Zodiak (free, loaded from api.fontshare.com), regular or medium weight.
- Body: Suisse Int'l Mono is the brand body face but is a paid license, so the app uses IBM Plex Mono as a
  stand in for labels, buttons, pills, times and tail numbers, and Inter for longer body text and inputs.
  Swap in Suisse only if Silver Air provides licensed web font files.
- Logo: gray on white, white on black, or black on white only. App header is near black with the white
  logo and a 3px orange rule; sign in card uses the gray logo.
- Contrast rules used: orange buttons use dark text (white on orange fails contrast). Brand gray is too light
  for text, so muted text uses darker grays. Links use a darker cyan (`#00729F`).
- All colors are CSS variables on `:root` in index.html, with dark mode overrides.
- The brand guide PDF is internal. Do not commit it to this public repo.

## Security (repo is PUBLIC)
- Never commit secrets: Resend API key, the real `DESK_SECRET`, or any service_role / secret Supabase key.
  `02-notifications.sql` has the placeholder `REPLACE_WITH_DESK_SECRET` on purpose.
- The Supabase publishable key in index.html is meant to be public; RLS plus the passcode RPCs protect data.
- Do not commit vendor contact details, passcodes, or job data (seed data was loaded once and left out).
- Making the repo private would need a paid GitHub plan to keep Pages working.

## Testing approach used so far
- SQL: run the files against a local Postgres 16 with `anon`/`authenticated` roles and an `extensions`
  schema created first, and a stub `net.http_post` that records calls into a table. Check role isolation,
  transitions, idempotency (run twice), and that jobs still save when `net.http_post` throws.
- Front end: Playwright (Chromium) loading index.html, routing `https://yosioojtuzvchvzdmrpt.supabase.co/rest/v1/rpc/*`
  to the local database, and walking the admin and vendor flows plus a 390px mobile check.
- Edge Function: import the file in Node (it only calls `Deno.serve` when `Deno` exists), stub `fetch`,
  and check the 403 on a wrong secret, recipients, `TEST_TO` mode and the rendered HTML.

## Status and open items (as of late October 2026)
- Live: passcode login, jobs, calendar, fleet, settings, photos, branding.
- Delivered Oct 27, 2026 (confirm uploaded and 03 run): in app alerts, invoice upload, ASM billing
  question and answer emails, add to home screen.
- Until the sending domain is verified in Resend, emails only reach the Resend account owner (or TEST_TO),
  so ASM will not get billing emails until IT finishes the DNS step.
- Email: code done and tested locally; Austin was setting up Resend and the Edge Function. Confirm with him
  whether the secrets are set and a test email has arrived.
- Waiting on IT: verify `notify.silverair.com` in Resend (DNS records), then set `EMAIL_FROM` to
  `Silver Air Cleaning Desk <notifications@notify.silverair.com>` and remove `TEST_TO`.
- Text message alerts were considered and skipped for now (Twilio cost plus carrier registration).
- The old claude.ai artifact version is retired. Its two job photos were not migrated.
- Removed from the old version: live ADS-B position readout (ADS-B Exchange and FlightAware links remain).
