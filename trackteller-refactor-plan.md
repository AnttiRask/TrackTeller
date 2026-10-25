# TrackTeller — Refactor Plan (proposal, nothing approved or built yet)

> Bring TrackTeller in line with what FillariStatus, Gallery of the Day, TuneTeller and BiblioStatus now do (`fillaristatus-plan.md`, `gallery-of-the-day-refactor-plan.md`, `tuneteller-refactor-plan.md`, `bibliostatus-refactor-plan.md`): an API layer that never throws, explicit states, tests with mocked HTTP, security headers, keyless CI/CD that gates deploys on tests, and a least-privilege runtime.
>
> **For Claude Code:** this is a proposal. **Nothing here is approved until the user says so, item by item** (section 9). Every change is checked with the user before it is committed, pushed or deployed. Cloud resources and GitHub settings need explicit approval. Never print secrets.

*Written 2026-10-24 from the four sibling plans, the TrackTeller code at `e90dd0b` (local `main` equals `origin/main`), a read-only look at Cloud Run / Artifact Registry / GitHub settings, and one web search on Spotify's API changes. "(code)" = read in the files; "(live)" = read from Google Cloud or GitHub today; "(verify)" = suspected, to be proved before relying on it.*

---

## 0. Where TrackTeller stands compared with the siblings

TrackTeller is the only app that has none of the sibling hardening. It is still the original single-file design.

| Practice | Siblings | TrackTeller today |
|---|---|---|
| Split into `global.R`, `variables.R`, `strings.R`, `functions.R`, `api.R`, JS/CSS files | all | No: `server.R` is 1,313 lines; text, colours and inline CSS are repeated through it (code) |
| API layer that never throws, explicit states (ok / empty / error / stale) | all | No: each call has its own `tryCatch`; some return `NULL` silently, others show `e$message` (code) |
| Tests with mocked HTTP | all | **None** (no `tests/` folder) |
| CI: tests gate the deploy, deploy smoke test, SHA-pinned actions | all | **No `.github/` at all**; deploy is `./deploy.sh` by hand |
| Keyless deploy (Workload Identity), dedicated runtime account | all | No: runs as the default compute account, which **still has `roles/editor`** (live) |
| Security headers / CSP | all | None |
| Repo hygiene (secret scanning, push protection, Dependabot, protected `main`) | all | **All disabled**; `main` not protected (live). The repo is public |
| Websocket: `--timeout 3600`, `--session-affinity`, `allowReconnect("force")` | Fillari, Biblio, Tune | No: timeout 300 s, so the page greys out after 5 minutes (live) |
| `--max-instances 3` | all | 20 (live) |
| Artifact Registry cleanup policy | all | None: **80 image versions** in the repo (live) |
| FillariStatus in the footer | all | Missing in `ui.R` and `docs/index.html` (code) |
| Image | `rocker/r-ver` + Posit binaries, non-root, allowlist `.dockerignore` | `rocker/shiny:4.3.1`, root user, denylist `.dockerignore` (code) |
| Docs match reality | yes | `PLAN.md` and `DEPLOY.md` are the original plan (`DEPLOY.md` still shows secrets as `--set-env-vars`) |

Also seen in the live inventory: a service `themealot-app` sits in the `trackteller-app` project (probably a stray, like the ones the TuneTeller plan found), and `bibliostatus-app` / `tuneteller-app` there show "not ready". Not touched.

---

## 1. Phase 0 — find out what is actually broken (read-only, do this first)

### 1.1 Spotify changed its API in 2026 (verify before anything else)

A web search turned up Spotify's "February 2026 Web API Dev Mode Changes" migration guide ([Spotify](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)). Reports in the Spotify community thread and GitHub issues (secondary sources; I could not read the official list in full) say that for Development Mode apps:

- `GET /artists/{id}/top-tracks` was removed. **TrackTeller's "Create Playlist from Top Artists" depends on it** (`server.R:1228`).
- `popularity` and `followers` were stripped from artist/track objects. **The artist cards show both** (`server.R:269-277`, `356-360`), so they may now be blank or `NA`.
- `POST /users/{id}/playlists` and `/playlists/{id}/tracks` have replacements (`/me/playlists`, `/playlists/{id}/items`), with renamed response fields (`tracks` → `items`). TrackTeller uses the old ones (`server.R:1265`, `1289`) and reads `playlist$tracks$total` (`server.R:802`).
- Spotify also postponed some of these for *existing* Development Mode apps, and the sources disagree on the date. So the live app may be fine today and break on a date we don't control.
- Development Mode also has a Premium requirement and a cap on authorised users (the "Request access here" form in `ui.R` suggests this is already how the app is run).

**Proposal:** a throwaway probe script (not committed) that takes an access token from an environment variable and prints only HTTP status codes and which fields are present, never any personal data, for each endpoint the app uses. Or, simpler: the user logs in to the live app and tells me what each tab and each "Create Playlist" button does. Either result decides whether the API layer in Phase 1 only needs hardening or also needs **replacement endpoints and removed fields**. Treat that as the first and most valuable finding.

**Probe result (2026-10-24, owner's account, read endpoints only; the two playlist-writing POSTs were not probed):** everything the app reads still works today, status 200 and the fields intact.

| Endpoint | Status | Notes |
|---|---|---|
| `GET /me` | 200 | `display_name`, `id`, `images` present |
| `GET /me/top/artists` | 200 | `popularity`, `followers`, `genres` all still present |
| `GET /me/top/tracks` | 200 | `popularity`, `duration_ms` present |
| `GET /me/player/recently-played` | 200 | |
| `GET /me/playlists` | 200 | has **both** `tracks` and the new `items` object (`{href, total}`): Spotify is mid-transition |
| `GET /playlists/{id}/items` (new) | 200 | |
| `GET /playlists/{id}/tracks` (old) | 200 | |
| `GET /artists/{id}/top-tracks` | 200 | still there |

So nothing is broken today; the risk is a future cut-over. Consequences for Phase 1: the API layer must tolerate both field shapes (`playlist$items$total %||% playlist$tracks$total`, new endpoints with the old as fallback), treat `popularity`/`followers` as optional (show nothing instead of `NA`), and treat a 403 from `top-tracks` as a handled state. This is the owner's account; a non-owner Development Mode user (or one without the Premium rule) was not tested. `http://127.0.0.1:8080` is now registered as a redirect URI in the Spotify dashboard.

### 1.2 Read-only inventory (already partly done)

Cloud Run: service `trackteller-app`, revision `00040-4v2`, runs as the default compute account, timeout 300 s, concurrency 80, max instances 20, no session affinity (live). Still to read: secrets and who can read them, the domain mapping, the billing budget (the Billing Budgets API may not be enabled in the project, as in the siblings), and the bucket sizes.

---

## 2. Phase 1 — code (one deploy)

### 2.1 Structure (mechanical first, behaviour changes in separate commits)

Mirror the siblings. Move the app into `app/` so the Docker image can use an allowlist:

```
app/
├── run.R              # entry: port, security-headers wrapper, /health
├── global.R           # packages, conflicted preferences (once), sources www/*.R
├── ui.R               # layout only (reads variables.R / strings.R)
├── server.R           # ~70 lines: state + sourcing of the parts below
├── server/            # auth.R, artists.R, tracks.R, recent.R, genres.R, playlists.R, cards.R
└── www/
    ├── variables.R    # colours, scopes, limits, time ranges, footer app list
    ├── strings.R      # ALL user-facing text
    ├── spotify_api.R  # spotify_get()/spotify_post(): token, retries, timeouts, states
    ├── spotify_oauth.R
    ├── functions.R    # pure helpers: parsing, to_title_case, duration, card text
    ├── cards.R        # build_stats_card() and image fetching
    ├── security.R     # headers + with_security_headers()
    ├── redirect.js  styles.css  favicon.png
tests/testthat/ ...
```

Things that follow from the code as it is:

- `server.R` runs `conflict_prefer()` and `source("scripts/...", local = TRUE)` **inside every session** (`server.R:25-31`); the sibling lesson (BiblioStatus Phase 2) is to load once at start and parse server parts once. Relative `source()` at session time also breaks under testthat.
- The same card markup (dark inline styles, ~20 lines) is copied into **four** `renderUI` blocks (artists, tracks, recent, playlists). One `card_row()` helper plus CSS classes removes ~300 lines and is the thing to test.
- Dead or leftover code: the hidden `oauth_code` / `oauth_state` / `oauth_error` inputs (nothing reads them), `refresh_trigger` (never changes), `max_artists_available` / `max_tracks_available` (written, never read), `get_valid_token()` and `parse_callback()` in `spotify_oauth.R` (unused), `SHINY_ENV`/`is_production()`/`get_port()`, `run.R`'s `addResourcePath` after the app is built, `docker-compose.yml`'s `SHINY_ENV`.
- `httr` → `httr2` (the siblings use `httr2` for timeouts, `req_retry`, `local_mocked_responses()`); needed for testing anyway.

### 2.2 A Spotify API layer that never throws (the core of the work)

Today there are ~10 hand-written `GET`/`POST` blocks with no timeout, no retry, no handling of 429/401, and three different error styles (code):

- `recently_played_data` returns `NULL` on any non-200 → the user sees "No recently played tracks found" when Spotify actually failed.
- The profile request swallows every error (`server.R:175`).
- Errors show `e$message` to the user (`server.R:283` etc.), and a failed token exchange shows Spotify's **raw response body** (`spotify_oauth.R:55`, shown via `server.R:80`).
- Playlist creation (`server.R:1265-1311`) has no `tryCatch`: a network error ends the session.

**Proposal:** one `spotify_get(path, token, query)` / `spotify_post()` returning `list(data, status, error)`:

- timeout (10 s), `req_retry` for 429 (honouring `Retry-After`), 5xx and network errors;
- 401 → refresh the token once, retry once, otherwise return `state = "reauth"`;
- states: `ok` / `empty` / `error` / `reauth` / `forbidden` (403: endpoint removed or user not allowed in Development Mode, with its own plain message);
- the UI never shows `e$message` or response bodies: plain sentences from `strings.R`, details go to the log;
- a failed tab shows a "Couldn't load this from Spotify. Try again" panel with a retry button instead of a toast that disappears.

### 2.3 OAuth correctness and session handling

Found in the code:

- **The `state` value is never checked.** The app stores it (`session$userData$oauth_state`, `server.R:105`) but the callback never compares it with `query$state`. The CLAUDE.md memory note claims "CSRF state (32 chars)"; only half of that exists. It is also generated with `sample()`, which is not a cryptographic source. Because Shiny sessions are per-websocket and the redirect leaves the page, the state has to survive the round trip: store it in a short-lived, signed value (cookie or the `state` itself as an HMAC of a nonce + timestamp using the client secret) and verify it on return. This is the one real security gap in the login.
- `show_dialog = "true"` forces Spotify's consent screen at every login. With the Shiny session lost on reload (below) it makes every return visit a full consent step. Dropping it lets Spotify skip the screen when consent already exists.
- **The login lives only in the session's memory.** A reload, a websocket drop, or a Cloud Run instance change logs the user out. With the 300 s timeout this happens after five minutes of idle. Options in order of effort: (a) just fix the timeout/affinity and show "Your session ended, log in again" with a one-click re-login (cheap, recommended); (b) keep the refresh token in the browser's `localStorage` and re-establish the session through the server (the user's own browser, but it widens the damage of any XSS; try/catch guarded); (c) PKCE so the client secret isn't needed for the browser flow (a bigger change). **Decision for the user.**
- `get_access_token` is a `reactive()` that **writes to `token_info`**, the `reactiveVal` it reads (`server.R:122-152`). It works by luck of the invalidation order; make it a plain function (or `observe`-driven refresh) so there is no reactive that has side effects.
- Tokens are held in memory and never logged; keep it that way (a test: the token string never appears in a rendered output).
- `allowReconnect("force")` as in Fillari/Biblio is safe here only after the playlist-creation observers are idempotent: the re-sent `confirm_create_playlist` click count would **create a second playlist**. Guard creation with a per-click token or disable the button while it runs.

### 2.4 Smaller correctness and UX items

- **Playlists are created `public = TRUE`** (`server.R:1273`), and the description advertises the site. A playlist built from someone's listening history being public by default is surprising. Proposal: private by default with a checkbox "Make it public" in the existing modal (the scopes already allow both).
- "Create Playlist from Top Artists" makes one **sequential** request per artist (up to 50 round trips) on the session thread, with no progress and no error handling (`server.R:1227-1244`). If `top-tracks` is gone (see 1.1) this needs a different source, e.g. each artist's tracks from the user's own top tracks, or search. Otherwise: show progress, cap the work, handle failures per artist.
- The three time-range selects are kept in sync with three `updateSelectInput` observers (`server.R:186-213`): the exact echo problem BiblioStatus spent a phase removing. One shared time range (a single control above the tabs, or a single `reactiveVal`) removes the observers and the risk of a loop.
- Each time range change resets "number to show" to 20 (`server.R:296-301`); decide whether that is wanted.
- Playlists tab: batch loading uses `invalidateLater(100)` with one request per tick; fine, but errors mid-way leave a half list with no message. Show "Loaded N of M" and a retry.
- Stats cards (`magick`): up to 10 image downloads, **sequentially, with no timeout** (`image_read(url)`, `server.R:1002`); a slow CDN blocks the download for a minute. Fetch in parallel with `httr2::req_perform_parallel()` (timeout 5 s each, placeholder on failure, as today), and only fetch from Spotify image hosts (`*.scdn.co`, `*.spotifycdn.com`). Cache per session so a second click is instant. Test: the card is 1200×630 and survives all-failed images.
- Links and images from the API (`spotify_url`, `image_url`) go straight into `href`/`src`. Allow only `https://` Spotify URLs, as TuneTeller's and BiblioStatus' plans do (`safe_http_url()`).
- `theme_spotify()` asks for the font "Gotham" (`global.R`), which is not installed in the container; the chart silently falls back. Pick a font that exists in the image or load one deliberately.
- Add FillariStatus to the footer list (one shared list in `variables.R`).
- Make the loading/empty/error text come from `strings.R` (the siblings did this so Finnish can be added later).

### 2.5 Security headers

Copy the pattern: `security.R` + wrapping `app$httpHandler` in `run.R` (`shiny.http.response.filter` does nothing). Enforce `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, HSTS, `nosniff`; then a full CSP first **report-only**, recorded in a throwaway copy with a violation recorder as the first script (the TuneTeller method), then enforced. Hosts needed: the font host, `*.scdn.co` / `*.spotifycdn.com` for images, `wss:`. Plotly may need `'unsafe-eval'`; check, don't assume. The `referrer` matters here: the OAuth `code` is in the URL on return, so `Referrer-Policy: strict-origin` and removing the query from the address right after the exchange (already done via `updateQueryString`) both matter.

### 2.6 `/health`

200 `ok` when the config is valid (client id/secret present, `APP_URL` is https in production). Cheap and honest; no Spotify call (a Spotify outage shouldn't turn a code deploy red, same reasoning as BiblioStatus). Optional uptime check + email alert afterwards (Phase 2).

### 2.7 Tests (there are none today)

`testthat` 3 with `httr2::local_mocked_responses()`, saved fixtures with **no personal data** (fabricate or scrub ids, names, images):

- API layer: ok / empty / 401→refresh→retry / 429 with `Retry-After` / 403 / timeout / malformed JSON.
- OAuth: authorise URL, state generate + verify (wrong, missing, expired), token exchange and refresh (mocked), expiry buffer.
- Pure helpers: parsing each endpoint, `to_title_case`, duration, genre aggregation, letter filter, `safe_http_url`.
- Card builder: dimensions, truncation, all-images-failed.
- `testServer()`: login → data → states; logout clears everything; playlist creation is idempotent; the token never appears in outputs.
- Security headers and handler wrapper (plain, NULL, promised responses).
- One real-browser check by hand before the deploy: login, each tab, a card download, a playlist, mobile width, a reconnect.

---

## 3. Phase 2 — infrastructure and CI (each step needs approval)

1. **Runtime account** `trackteller-runtime` with `secretAccessor` on the two secrets only; remove `roles/editor` from the default compute account (keep `cloudbuild.builds.builder`); confirm a build still works afterwards.
2. **Keyless deploy:** Workload Identity pool `trackteller`, provider restricted to `AnttiRask/TrackTeller` on `refs/heads/main`, service account `trackteller-deploy` with the narrow roles from the TuneTeller plan (5.2); test by impersonation and by negative tests before switching the workflow on.
3. **Workflows:** `tests.yml` (R version and packages from `renv.lock`), `deploy_shiny_app.yml` (needs tests, build, deploy, smoke test that checks the `git-sha` label and `GET /` = 200), triggered on `app/**` and build files only; actions pinned to SHAs, minimal `permissions`, `dependabot.yml` for Actions and Docker.
4. **Image:** `rocker/r-ver` (R version from the lock), system libraries from Posit's sysreqs API plus the `magick` libraries (`libmagick++-dev` to build, the runtime library in the final image) and `fonts-liberation` for the cards, Posit Linux binaries, renv cache disabled, non-root user, `CMD Rscript app/run.R`, **allowlist** `.dockerignore`. Regenerate `renv.lock` **inside the image** (the siblings' recipe): the current lock is for R 4.3.1 with shiny 1.8.0 and bslib 0.6.1, and local R is 4.6.1 so `renv::restore()` doesn't work here; check every `Requirements` entry is in the lock afterwards.
5. **Cloud Run settings:** `--timeout 3600 --session-affinity`, `--max-instances 3`, keep concurrency at 80 (lowering it breaks the page load, per the BiblioStatus lesson), no `--allow-unauthenticated` in the workflow. `APP_URL` stays the production URL.
6. **Deploy script:** replace the hand-written `.env` parser in `deploy.sh` (the memory note records it as the source of a production outage) with: read the two values from the environment or the existing secrets, never from a custom parser; keep the 32-hex validation; keep it as the manual fallback.
7. **Repo hygiene:** secret scanning, push protection, Dependabot alerts and security updates, `main` protected (no force-push or deletion) and read back. It is currently all disabled on a public repo.
8. **Cleanup:** Artifact Registry keeps the 5 newest versions (policy format and the 80 current images in section 0); lifecycle on the build buckets; a budget alert covering this project.
9. **Optional:** `/health` uptime check with an email alert (as Gallery and BiblioStatus have).

---

## 4. Phase 3 — optional improvements (only if wanted)

- Light mode and a toggle like the siblings (TrackTeller is dark-only; the ggplot theme and the card colours would need a light variant). Not needed for robustness.
- Cache `/me` and image downloads per session; a cap on how often the user can refresh.
- Finnish UI later (Phase 1 only prepares `strings.R`).
- Revoke note: Spotify has no token-revocation endpoint, so "Logout" only forgets the token; say so in the privacy line, and add a short privacy line to the footer (what is stored: nothing, tokens only in memory).
- Docs: rewrite `PLAN.md` (it is the original build plan, "IMPLEMENTED") and `DEPLOY.md` (secrets via Secret Manager, not `--set-env-vars`), update `CLAUDE.md`, `README.md` and the project page footer.

---

## 5. Suggested order

1. **Phase 0** (probe the Spotify API, inventory). Result may change the rest.
2. Repo hygiene and the Artifact Registry cleanup (small, independent, no app change) — can go first because they are risk reduction with no behaviour change.
3. Phase 1 in small commits: mechanical split → API layer + tests → OAuth state/session → UX items → security headers. Reviewed locally with the running app (`sudo docker compose up --build`, http://127.0.0.1:8080; note the sibling plans found Docker's bridge network unreliable on this machine, `--network host` worked there).
4. Phase 2 steps 1-5 together with the new image, then the first CI-driven deploy.
5. Phase 3 only as asked.

Verification after each push/deploy follows the user's rules: `git status` and `git ls-remote origin refs/heads/main` equal `HEAD`; read the workflow run result from GitHub; after a deploy check the revision and `git-sha` label, HTTP 200, the logs, and use the live app (login, each tab, a card, a playlist).

## 6. Risks and known gaps (to keep honest)

- Everything about the Spotify changes in 1.1 comes from secondary sources until the probe is run.
- Login needs a real Spotify account in the allowed list; automated browser checks can't log in, so the user has to run the login-dependent paths by hand. Phones, Safari and Firefox have not been checked in any sibling plan either.
- A new image changes R from 4.3.1 to 4.5/4.6, shiny 1.8 → 1.12+, bslib 0.6 → 0.9+: the look can change slightly (bslib/Bootstrap internals). Compare screenshots before and after.
- Any change to the OAuth flow has to be tested against the real Spotify redirect (the redirect URI must stay exactly as registered in the Spotify dashboard).

## 7. What I would drop or not do

- No database or server-side session store (the app is stateless on purpose; option (b) in 2.3 keeps it that way).
- No move to another cloud project (the TuneTeller plan reached the same conclusion: isolation is worth more than tidiness).
- No `min-instances` (cost; cold start ~3 s is accepted in the sibling plans).

## 8. Effort and value at a glance

| Item | Value | Effort | Risk |
|---|---|---|---|
| 1.1 Probe the Spotify API | Very high (may reveal broken features) | Small | None |
| 2.2 API layer + states | High | Medium | Low |
| 2.3 OAuth `state` check, session loss, idempotent playlist creation | High (security + user-visible) | Medium | Medium (login flow) |
| 2.7 Tests | High | Medium | None |
| 2.5 Security headers/CSP | Medium | Small-medium | Low (report-only first) |
| Phase 2 runtime account, keyless CI, tests gate | High | Medium | Low, with the staged tests |
| Repo hygiene, registry cleanup | Medium | Small | None |
| 2.4 UX items (private playlists, cards in parallel, one time range) | Medium | Small each | Low |
| 2.1 Structure split | Medium (enables the rest) | Medium | Low (mechanical) |
| Phase 3 | Low | varies | — |

## 9. Decisions for the user (please answer before any work starts)

| # | Question | Proposed |
|---|---|---|
| 1 | Run the Phase 0 API probe first (you log in / give me a token in an env var, I print only status codes)? | Yes — **DONE 2026-10-24**, see 1.1 |
| 2 | Session loss on reload/reconnect: (a) re-login with no consent screen, (b) refresh token in the browser, (c) PKCE | (a) — **DECIDED by the user 2026-10-24: (a)** |
| 3 | Playlists private by default with a "make public" checkbox? | Yes — **DECIDED by the user 2026-10-24** |
| 4 | One shared time range instead of three synced selects? | Yes — **DECIDED by the user 2026-10-24** (bar above the tabs, hidden on Recently Played; "number to show" keeps resetting to 20) |
| 5 | Move the app into `app/` and use an allowlist Docker image like the siblings? | Yes — **DECIDED by the user 2026-10-24** (own mechanical `git mv` commit, no behaviour change) |
| 6 | Switch `httr` → `httr2`? | Yes — **DECIDED by the user 2026-10-24** (done together with the new API layer) |
| 7 | Enforce the OAuth `state` check (signed value)? | Yes — **DECIDED by the user 2026-10-24** (secure random, HMAC-signed with timestamp, 10 min expiry, unit-tested) |
| 8 | Add FillariStatus to the footer and the project page? | Yes — **DECIDED by the user 2026-10-24** (app footer with Phase 1; project page can go earlier) |
| 9 | Phase 2 (runtime account, keyless deploy, CI with tests gating, `--max-instances 3`, timeout 3600 + affinity)? | Yes, step by step with your approval each time — **DECIDED by the user 2026-10-24** |
| 10 | Repo hygiene settings and registry cleanup first, as a separate small step? | Yes — **DECIDED by the user 2026-10-24** (each command shown before it runs) |
| 11 | Light mode (Phase 3)? | Not now — **DECIDED by the user 2026-10-24** (stays an optional Phase 3 item) |
| 12 | The stray `themealot-app` service in the `trackteller-app` project: leave it, or look into it? | Read-only checks done 2026-10-24: created 2026-03-07 by you via `gcloud run deploy --source`; ready, public (`allUsers` invoker), runs as the default compute account; domain mapping `themealot.youcanbeapirate.com` exists but is **not ready**; **no requests in 30 days**. Nothing changed. Also found: the project has two pairs of secrets (`SPOTIFY_CLIENT_ID`/`SPOTIFY_CLIENT_SECRET` used by `deploy.sh`, and lowercase `spotify-client-id`/`spotify-client-secret`); which pair the live service reads is still to be checked before Phase 2 step 1. What to do with `themealot-app` is **open (user's call)** |

---

## 10. Progress and later decisions (2026-10-25)

### Done and live
| What | Where |
|---|---|
| Spotify API probe: every read endpoint still works (section 1.1) | 2026-10-24 |
| App moved into `app/`, allowlist `.dockerignore` | PR #1 |
| CI/CD: `tests.yml`, keyless `deploy_shiny_app.yml`, Dependabot; runtime account `trackteller-runtime`, deploy account `trackteller-deploy` (Workload Identity pool `trackteller`), Editor removed from the default compute account (which keeps `cloudbuild.builds.builder`) | PR #2, `infra/` |
| Repo hygiene: secret scanning, push protection, Dependabot, protected `main` | 2026-10-24 |
| New image: `rocker/r-ver:4.5.2`, non-root, lock regenerated by `infra/regenerate_renv_lock.sh`; `theme_spotify()` panel border fix for ggplot2 4 | PR #4 |
| `httr2` API layer, OAuth on `httr2`, testthat suite run inside the production image in CI | PR #5 (revision 00046) |

### Still open
- Registry cleanup policy is in dry-run mode; read the result, then the owner applies it for real.
- `themealot-app` in this project: read-only checks say it is an unused duplicate (no requests in 60 days, its domain mapping never worked, `themealot.youcanbeapirate.com` is served from somewhere else). The owner decides; deleting is not reversible.
- OAuth `state` check, private-by-default and the secure random value (decision 7); re-login without the consent screen (decision 2a).
- Splitting `server.R` into files, `variables.R`, `strings.R`, the card helper (section 2.1).
- Non-Latin names are blank on the share cards (Liberation Sans has no CJK glyphs); a CJK font would fix it.
- `server.R` has no automated tests; `shiny::testServer()` tests are the next step for it.

### The UX pull request (decisions 3, 4, 8 and what follows from them)
Decided by the owner on 2026-10-25, in this order of discussion:
1. **Number sliders:** switching the time range must not reset "Number to show" to the default. Every list works like Top Artists: the choice is kept and only clamped to what is available (Recently Played showing 37 of 50 is the case that prompted this).
2. **One shared bar above the tabs** with **Time range** (hidden on Recently Played, which has none) and **Number to show** (slider 10-50, default 20). Both stay the same when moving between tabs, even though the lists differ (artists, tracks, genres). This replaces the three time-range dropdowns and the four separate sliders, and the sync observers.
3. **Clamping (option 1):** each list shows the smaller of the choice and what is available, with a short line under it ("Showing all 32 artists", "Showing 20 of 50"). Top Genres is capped at 20 (the chart is unreadable beyond that) and says so. (Moot with a fixed 10-50 slider: a shorter list just says "Showing all 7 artists".)
4. **Remembered across reloads:** both choices are kept in the browser (`localStorage`, per device, wrapped in try/catch so the app works without storage) and restored on load. They are only these two preferences; nothing about the account or listening. The Spotify login is not remembered (decision 2a).
5. **Playlists private by default** with a "Make it public" checkbox in the Create Playlist dialog (decision 3); the result dialog says which.
6. **FillariStatus in the footer** (decision 8); the project page `docs/index.html` gets the same link.

### Layout decisions after trying the UX build (2026-10-25)
1. **Cross-app links and the action buttons move into the sidebars** (as in BiblioStatus, where `create_app_footer()` is the last element of `sidebar()`), because the shared bar left the main area too short. The Share and Create Playlist buttons sit at the top of the sidebar of their tab; the page-level footer is gone.
2. **The genre chart gets a height that follows the number of bars** (`genre_chart_height()`, 32 px per bar + 130). Placed directly in bslib's fill layout the plot was squeezed to whatever height was left (340 px in a 600 px-tall window, about 250 px on the owner's screen), and 20 labels overlapped. It now sits in a plain container, so the page scrolls instead. The chart itself is `genre_chart()` in `app/scripts/charts.R`, with tests (including the white-panel regression).
3. The slider's tick labels are off, to save a little height in the bar.

### To think about: My Playlists takes a long time to load (raised by the owner, 2026-10-25)
Not designed or decided; this is the list of ideas to weigh, and a first step.
- **What happens now:** the tab loads 50 playlists per request, one request at a time (Spotify's maximum page is 50, and `/me/playlists` has no filter or search), pauses 100 ms between requests, and after every batch re-sorts everything, rebuilds the letter list and re-renders the visible list. With hundreds of playlists that is many sequential round trips plus a lot of repeated work.
- **Step 0, measure before changing anything:** log the time of each request and of each re-render for an account with many playlists, to see whether the time goes to waiting on Spotify (round trips) or to our own work (re-sorting and re-rendering growing lists). The right fix depends on that.
- **Ideas, roughly in order of value for effort:**
  1. *Fetch the rest in parallel.* The first page says how many playlists there are (`total`), so all other offsets are known; request them several at a time with `httr2::req_perform_parallel()` (a handful at once, to stay well inside Spotify's rate limits, with the existing retry and 429 handling). Likely cuts the time several-fold if round trips dominate.
  2. *Do less work per batch.* Update the letter list and the visible list only when loading is done or every few batches, not after each one; keep the batches in a list and bind once.
  3. *Start earlier.* Begin loading right after login (in the background) instead of when the tab is opened, so it is often ready by the time it is needed. Costs API calls for people who never open the tab.
  4. *Remember in the browser.* Keep a compact copy (id, name, owner, track count) in `localStorage`, show it immediately, and refresh in the background. Needs a decision: it stores playlist names on the device, and must be keyed to the account and cleared on logout.
  5. *Render less.* A letter such as "S" can hold many cards; page the list or render only the first N and add "show more".
  6. *Show progress honestly.* "Loaded 350 of 812" (the total is known after the first request) instead of "so far".
- **Not possible:** filtering by first letter on Spotify's side (no such parameter), or asking for fewer fields (`fields` is not supported on this endpoint).
