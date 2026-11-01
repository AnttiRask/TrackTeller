# TrackTeller — Refactor Plan (decisions made, most of it built; status in section 11)

> Bring TrackTeller in line with what FillariStatus, Gallery of the Day, TuneTeller and BiblioStatus now do (`fillaristatus-plan.md`, `gallery-of-the-day-refactor-plan.md`, `tuneteller-refactor-plan.md`, `bibliostatus-refactor-plan.md`): an API layer that never throws, explicit states, tests with mocked HTTP, security headers, keyless CI/CD that gates deploys on tests, and a least-privilege runtime.
>
> **For Claude Code:** sections 0-8 are the original proposal and are kept as written (they explain the *why*); section 9 holds the decisions the user made, section 10 the progress and findings as work went on, and **section 11 the current status: what is built and what is still open**. Open items are **not approved until the user says so, item by item**. Every change is checked with the user before it is committed, pushed or deployed. Cloud resources and GitHub settings need explicit approval. Never print secrets.

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
| 2 | Session loss on reload/reconnect: (a) re-login with no consent screen, (b) refresh token in the browser, (c) PKCE | (a) — **DECIDED by the user 2026-10-24: (a); built 2026-10-26** |
| 3 | Playlists private by default with a "make public" checkbox? | Yes — **DECIDED by the user 2026-10-24; SUPERSEDED 2026-10-25**: Spotify's API can't make private playlists for this app (probed), so playlists are always public and the dialogs say so |
| 4 | One shared time range instead of three synced selects? | Yes — **DECIDED by the user 2026-10-24** (bar above the tabs, hidden on Recently Played; "number to show" keeps resetting to 20) |
| 5 | Move the app into `app/` and use an allowlist Docker image like the siblings? | Yes — **DECIDED by the user 2026-10-24** (own mechanical `git mv` commit, no behaviour change) |
| 6 | Switch `httr` → `httr2`? | Yes — **DECIDED by the user 2026-10-24** (done together with the new API layer) |
| 7 | Enforce the OAuth `state` check (signed value)? | Yes — **DECIDED by the user 2026-10-24** (secure random, HMAC-signed with timestamp, 10 min expiry, unit-tested) |
| 8 | Add FillariStatus to the footer and the project page? | Yes — **DECIDED by the user 2026-10-24** (app footer with Phase 1; project page can go earlier) |
| 9 | Phase 2 (runtime account, keyless deploy, CI with tests gating, `--max-instances 3`, timeout 3600 + affinity)? | Yes, step by step with your approval each time — **DECIDED by the user 2026-10-24** |
| 10 | Repo hygiene settings and registry cleanup first, as a separate small step? | Yes — **DECIDED by the user 2026-10-24** (each command shown before it runs) |
| 11 | Light mode (Phase 3)? | Not now — **DECIDED by the user 2026-10-24** (stays an optional Phase 3 item) |
| 12 | The stray `themealot-app` service in the `trackteller-app` project: leave it, or look into it? | Read-only checks done 2026-10-24: created 2026-03-07 by you via `gcloud run deploy --source`; ready, public (`allUsers` invoker), runs as the default compute account; domain mapping `themealot.youcanbeapirate.com` exists but is **not ready**; **no requests in 30 days**. Nothing changed. Also found: the project has two pairs of secrets (`SPOTIFY_CLIENT_ID`/`SPOTIFY_CLIENT_SECRET` used by `deploy.sh`, and lowercase `spotify-client-id`/`spotify-client-secret`); which pair the live service reads is still to be checked before Phase 2 step 1. What to do with `themealot-app` was the user's call: **deleted 2026-10-26** (service and its failed domain mapping; its three old images are left to the registry cleanup) |

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

### Done and live, later (2026-10-25 to 2026-10-27)
| What | Where |
|---|---|
| Other tabs locked before login; always back to Top Artists when the login ends | PR #8 |
| My Playlists: all playlists, 50 to a page, loaded in the background, browser copy, Reload, honest count | PR #9 |
| OAuth `state` check (signed, 10 minutes, bound to the browser) | PR #10 |
| Re-login without the consent screen (`force_dialog` only after a Log out) | PR #11 |
| `server.R` split into `app/server/*.R`, `setup.R`, `strings.R`, `variables.R`, `list_card()`, server tests | PR #12 |
| CJK font for the share cards (`fonts-noto-cjk`) | PR #13 |
| `themealot-app` deleted (2026-10-26); registry cleanup policy applied (dry run switched off 2026-10-27) | by hand |

The former "Still open" list of this section is superseded by section 11.

### The UX pull request (decisions 3, 4, 8 and what follows from them)
Decided by the owner on 2026-10-25, in this order of discussion:
1. **Number sliders:** switching the time range must not reset "Number to show" to the default. Every list works like Top Artists: the choice is kept and only clamped to what is available (Recently Played showing 37 of 50 is the case that prompted this).
2. **One shared bar above the tabs** with **Time range** (hidden on Recently Played, which has none) and **Number to show** (slider 10-50, default 20). Both stay the same when moving between tabs, even though the lists differ (artists, tracks, genres). This replaces the three time-range dropdowns and the four separate sliders, and the sync observers.
3. **Clamping (option 1):** each list shows the smaller of the choice and what is available, with a short line under it ("Showing all 32 artists", "Showing 20 of 50"). Top Genres is capped at 20 (the chart is unreadable beyond that) and says so. (Moot with a fixed 10-50 slider: a shorter list just says "Showing all 7 artists".)
4. **Remembered across reloads:** both choices are kept in the browser (`localStorage`, per device, wrapped in try/catch so the app works without storage) and restored on load. They are only these two preferences; nothing about the account or listening. The Spotify login is not remembered (decision 2a).
5. **Playlists are public, and the dialogs say so** (decision 3 was "private by default with a Make it public box"; **superseded 2026-10-25**). The owner reported that private playlists came out public, and two probes showed why: Spotify makes every playlist created through its API public, reports the wrong visibility in the create response, and ignores later `PUT public=false` (200, no change), on both create endpoints. The owner decided: no toggle that does nothing; always public, and tell the user (in the dialog, and in the result, with how to make it private in Spotify). If a new probe ever shows that private works, the toggle can come back.
6. **FillariStatus in the footer** (decision 8); the project page `docs/index.html` gets the same link.

### Layout decisions after trying the UX build (2026-10-25)
1. **Cross-app links and the action buttons move into the sidebars** (as in BiblioStatus, where `create_app_footer()` is the last element of `sidebar()`), because the shared bar left the main area too short. The Share and Create Playlist buttons sit at the top of the sidebar of their tab; the page-level footer is gone.
2. **The genre chart gets a height of its own.** First version: 32 px per bar + 130. Replaced the same day (the owner had to zoom out to 70% to see 20 bars on a laptop) by: text 13 px instead of 20, and a container that fills the rest of the screen (`100vh - 235px`) but never gets less than 18 px per bar + 90. Measured at 660 px window height: the whole chart fits (420 px); at 520 px it falls back to the 450 px minimum and scrolls. Placed directly in bslib's fill layout the plot was squeezed to whatever height was left (340 px in a 600 px-tall window, about 250 px on the owner's screen), and 20 labels overlapped. It now sits in a plain container, so the page scrolls instead. The chart itself is `genre_chart()` in `app/scripts/charts.R`, with tests (including the white-panel regression).
3. The slider's tick labels are off, to save a little height in the bar.

### My Playlists loading time (raised by the owner, 2026-10-25; DONE, see the outcome below, the rest is the original analysis)
Not designed or decided; this is the list of ideas to weigh, and a first step.
- **What happens now:** the tab loads 50 playlists per request, one request at a time (Spotify's maximum page is 50, and `/me/playlists` has no filter or search), pauses 100 ms between requests, and after every batch re-sorts everything, rebuilds the letter list and re-renders the visible list. With hundreds of playlists that is many sequential round trips plus a lot of repeated work.
- **It also makes the page feel stuck (seen by the owner, 2026-10-25):** Shiny runs a session on one thread, so while the loader works through its batches, a click on Log out answered late. Whatever else we do, the loader should work in small steps with room for other input in between, or be parallel and short.
- **Step 0, measure before changing anything:** log the time of each request and of each re-render for an account with many playlists, to see whether the time goes to waiting on Spotify (round trips) or to our own work (re-sorting and re-rendering growing lists). The right fix depends on that.
- **Ideas, roughly in order of value for effort:**
  1. *Fetch the rest in parallel.* The first page says how many playlists there are (`total`), so all other offsets are known; request them several at a time with `httr2::req_perform_parallel()` (a handful at once, to stay well inside Spotify's rate limits, with the existing retry and 429 handling). Likely cuts the time several-fold if round trips dominate.
  2. *Do less work per batch.* Update the letter list and the visible list only when loading is done or every few batches, not after each one; keep the batches in a list and bind once.
  3. *Start earlier.* Begin loading right after login (in the background) instead of when the tab is opened, so it is often ready by the time it is needed. Costs API calls for people who never open the tab.
  4. *Remember in the browser.* Keep a compact copy (id, name, owner, track count) in `localStorage`, show it immediately, and refresh in the background. Needs a decision: it stores playlist names on the device, and must be keyed to the account and cleared on logout.
  5. *Render less.* A letter such as "S" can hold many cards; page the list or render only the first N and add "show more".
  6. *Show progress honestly.* "Loaded 350 of 812" (the total is known after the first request) instead of "so far".
- **Not possible:** filtering by first letter on Spotify's side (no such parameter), or asking for fewer fields (`fields` is not supported on this endpoint).

### My Playlists: what was measured, what was decided, what was built (2026-10-25)
**Measured** (read-only probe with the owner's login: 4,213 playlists = 85 pages of 50): one request after another 47 s (median 0.53 s per request); 3 at once 85 s; 5 at once 73 s, with one request stalling about 68 s each time. Spotify's response time is the floor (about 45 of the 47 s), and **fetching in parallel makes it worse**, so idea 1 of the list above is refuted for this endpoint.

**Decided with the owner:** an "All playlists" view next to the letter filter, 50 to a page with paging; while loading, show playlists as they arrive in Spotify's order, and switch on A-Z order and the letters when everything is here; a loader that never blocks the page; and a compact copy kept in the browser so that a return visit is instant.

**Built** (`playlists_module.R`, `playlists.R`, `playlists-cache.js`, `spotify_get_async()`): all of it. With the fake 4,213-playlist Spotify: first page after about a second, banner counting up, Next/Previous while loading, A-Z and letters at the end; a return visit shows the saved copy within 0.7 s with the letter filter working while the real list refreshes behind it; logout removes the copy; a damaged copy is ignored.

**Found on the way (each is now written in CLAUDE.md and has a test):** a blocked R session can't answer the browser (httr2's `req_perform_promise()` keeps it free but does not retry, so `spotify_call_async()` retries itself); Shiny decides an output is hidden when the browser sends an input and nothing re-checks after a tab switch; buttons re-created by `renderUI` can lose clicks; and **one `tibble()` per row is 20-30 times slower inside a running Shiny app than in a script** (230 ms per page of playlists, 20 s for the 4,213-row browser copy), so pages are built from columns.

**After the owner tried it (same day):** card spacing back to the old 8 px (the cards had picked up the page's 24 px gap on top of their margin); Previous/Next in green, with First and Last, and a box to type a page number ("Page [26] of 85"); the green loading banner no longer flashes (it is created once, only its text changes); and the 4,213 vs 4,212 difference was explained: Spotify's list changed while it was being fetched, so one playlist was seen twice and another never. The tab now says "Spotify says you have 4,213 playlists, but 4,212 arrived" and has a "Reload playlists" button, which keeps the list on screen while it reloads.

**Not done / still open:** the order while loading is Spotify's, not A-Z (A-Z needs everything); the whole load still takes about 45 s of Spotify's time on a first visit without a copy; starting the load right after login (idea 3) was not built (it would cost API calls for people who never open the tab).

**Correction (2026-10-26, after the owner's real account):** the 4,213 vs 4,212 difference was not a list that changed. It came back on every reload: Spotify counts a playlist in its total that the API no longer has (removed by Spotify, still visible in the Spotify app). The loader also stopped at the first page shorter than 50, which ended one real load at 2,599 of 4,213 when a page in the middle came back one short; it now ends at the page without a `next` link. The tab says how many playlists can't be loaded. Two flashing causes were found: Shiny's `recalculating` fade, and `autoWaiter()` putting a white spinner over every output (now limited to the other tabs' lists).

### OAuth `state` check (decision 7), built 2026-10-26
`state` = `<nonce>.<issued at>.<HMAC-SHA256 with the client secret>`, nothing stored on the server, valid 10 minutes, made with `openssl::rand_bytes()` (not `sample()`). Beyond the plan: the nonce is also kept in the browser's `sessionStorage` while it is away at Spotify and must match on return (`redirect.js` → `input$oauth_nonce`), so a login link prepared by someone else is refused even though its signature is ours. Refused logins show "Couldn't verify this login", log only the reason, and never reach Spotify's token endpoint. Also: the "authorization denied" message no longer prints text from the address, and the dead hidden `oauth_*` inputs are gone. `redirect.js` gets a content hash in its address so a cached older copy can't meet the new server. Unit tests cover new/valid/missing/malformed/tampered/wrong secret/expired/future/other browser; the server side was checked by hand (bogus state refused, address cleared) and still needs one real login.

### Re-login without the consent screen (decision 2a), built 2026-10-26
`show_dialog=true` is no longer sent, so Spotify skips its consent screen when the app already has consent: a return visit (new tab, reload, expired session) is one click on Log in. After a Log out in the same session the next login still asks (`force_dialog`), so the user can pick another account. A reload after logging out forgets that, and Spotify signs the same account back in; a "use a different account" option is possible later if it's wanted. A scope change later makes Spotify ask for consent again by itself.

### `server.R` split (2026-10-26)
`server.R` (954 lines) is now 25 lines that put together `app/server/{auth,shared,artists,tracks,recent,genres,downloads,create_playlist}.R`; packages, `conflict_prefer()` and all sourcing happen once in `app/setup.R` instead of in every session. The three copies of the list card markup are one `list_card()` (`scripts/list_cards.R`), the two download handlers one `card_download()`, the share image is `scripts/stats_card.R`, user-facing text of the server is `TXT` in `scripts/strings.R`, and card styles and layout numbers are in `scripts/variables.R`. Behaviour is the same, apart from two things the new tests found: (1) renewing the token re-ran everything that asks "logged in?", so every renewal (hourly) fetched all lists a second time (now `is_authenticated` changes only at login/logout); (2) the share card no longer fails on an unknown time range. New tests: `test-server.R` (login callback incl. state check, token renewal, 401 handling, lists, notes, logout, playlist creation), `test-list-cards.R`, `test-stats-card.R`. Not moved: the stats card image code itself (only de-indented), `ui.R` (layout only; its strings stay there).

### CJK font for the share cards (2026-10-26)
`fonts-noto-cjk` in the image (+91 MB installed, image 2.64 GB in total); `card_font()` chooses it per text, `trunc_str()` counts widths. Checked by rendering sample cards (Japanese, Chinese, Korean, Cyrillic, accented Latin) and by a test that two different CJK names don't render alike (missing glyphs would be identical boxes). Not covered: Arabic, Thai, Devanagari, emoji (boxes). `themealot-app` (service and its failed domain mapping) deleted the same day; its three old images are left to the registry cleanup policy.

---

## 11. Status on 2026-10-27: what is built, what is still open

### Against the sections of the proposal
| Item | State |
|---|---|
| 1.1 Spotify API probe | Done (2026-10-24); playlist-visibility probes 2026-10-25 |
| 2.1 Structure | Done: `app/`, `setup.R`, `server/*.R`, `strings.R`, `variables.R`, `list_card()`, one `card_download()`. Not done: `security.R`, a `www/`-style layout of R files (R code stays in `scripts/` and `server/`, never in `www/`, which is served to the public) |
| 2.2 API layer that never throws | Done (httr2, states, retries, timeouts; async variant for the playlist loader) |
| 2.3 OAuth | Done: signed `state`, no forced consent screen, token handling in plain functions (`current_token()`), `is_authenticated` stable across renewals. **Open:** idempotent playlist creation (see below) and `allowReconnect("force")`; (b) refresh token in the browser and (c) PKCE were not chosen |
| 2.4 Smaller items | Done: one shared time range and number to show (remembered), FillariStatus in the footer, text in `TXT`, links in the browser copy only accept https. **Open:** card images are still fetched one after another (each with a fallback, no timeout of their own); `spotify_url` / `image_url` from the API go into `href` / `src` without a check; `theme_spotify()` asks for the font "Gotham", which the image doesn't have (silent fallback) |
| 2.5 Security headers / CSP | Done: headers, and the CSP (enforced since 2026-11-01) |
| 2.6 `/health` | Done (uptime check and alert: see item 2 below) |
| 2.7 Tests | Done: API layer, retries (real local server), parsers, OAuth, display helpers, charts, playlists module (4,213 playlists), `testServer(server)`, list cards, stats card; run inside the production image in CI |
| Phase 2 (accounts, keyless deploy, CI, image, Cloud Run settings, repo hygiene) | Done and verified. Registry cleanup: applied 2026-10-27 (see below) |
| Phase 3 | Light mode: declined (2026-10-24). The rest not built |

### Still open (none is approved yet; each needs the user's yes)
1. ~~`deploy.sh` reads `.env` with a hand-written loop~~ **Done 2026-10-31** (branch `fix/deploy-sh-env-parser`): no `.env`, no prompts; stored secrets or both values from the environment; validation never prints the value; fixed production URL; no `gcloud config set`, no project creation, no project-wide IAM grant; `git-sha` label; `--dry-run`. Found on the way: the old script **re-granted the default compute account `secretAccessor` on the whole project on every run**, which undid the least-privilege setup. **1b, done 2026-10-31 with the user's approval:** that grant is removed (the old policy was saved first); the default compute account keeps only `cloudbuild.builds.builder`, the secret-level grants are unchanged, so `trackteller-runtime` reads its two secrets as before. The next deploy proves it end to end. **1c, done 2026-10-31:** `bibliostatus-app` and `tuneteller-app` in this project had never been ready since 2026-02-12 (an image in another project they couldn't read, a secret that didn't exist); the real apps live in their own projects and still answer 200. Both services are deleted. **Left over, the user's call:** the second, lowercase pair of secrets (`spotify-client-id`, `spotify-client-secret`; nothing running uses them, deleting a secret can't be undone) and the old images of `tuneteller-app` and `themealot-app` in the registry (3 each; the cleanup policy keeps up to five per image, so they stay unless deleted).
2. **Security headers and CSP (2.5)** and **`/health` (2.6)**, plus an uptime check with an email alert.
   - **Plain headers: done 2026-10-31** (branch `feat/security-headers`): `app/scripts/security.R`, `with_security_headers()` in `run.R`; `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` (camera, microphone, geolocation, payment, usb and sensors off), HSTS (one year, no includeSubDomains, no preload) only for requests that came over https. Unit tests, and CI checks the headers on the running image. Found: `shiny.http.response.filter` does nothing and Shiny only sets `nosniff` on static files, so the page handler is wrapped.
   - **`/health`: done 2026-10-31** (branch `feat/health-endpoint`): `app/scripts/health.R`; 200 `ok` or 503 `unhealthy: <names>`; checks the two credentials (32 lowercase hex) and, in production, an https `APP_URL`; no Spotify call; `Cache-Control: no-store`. CI checks it on the image with and without credentials, and the deploy smoke test requires 200 from the deployed revision. The unused `validate_config()` and `get_port()` were removed from `config.R` (`is_production()` is used now).
   - **Uptime check and alert: done 2026-10-31** with the user's approval (`infra/setup_uptime_alert.sh`, branch `feat/uptime-check`): email channel "TrackTeller alerts", uptime check "TrackTeller /health" (5 minutes, 10 s timeout, 200 with body `ok`, all default locations), alert policy "TrackTeller /health is failing" (two or more locations failing at once). Created through the Monitoring REST API with the project named as the quota project: `gcloud alpha` isn't installed here, and `gcloud`'s default quota project is `tuneteller-app`. Free tier at this volume. The probes keep an instance warm. It does not alert on Spotify outages (by design).
   - **Content-Security-Policy: built, in report-only mode, 2026-10-31** (branch `feat/csp`): `app/scripts/csp.R`, mode from `CSP_MODE` (`report-only` default, `enforce`, `off`; changeable on the running service without a rebuild, which is also the way back). Reports go to `POST /csp-report` and are logged as sanitized one-line summaries (never a query: the login's code and state are in the page address; at most 300 lines per instance and hour). Run through every feature with the owner's real account locally: **one violation kind only, `eval` from `shiny.min.js`** (Shiny's own), so the policy allows `'unsafe-eval'` next to `'unsafe-inline'` (Shiny has no nonce support); no violations for images, fonts, styles or the websocket. The embedded browser used for testing doesn't deliver reports; Chrome and Firefox do (`report-uri`).
   - **Enforcing: done 2026-11-01.** After a clean report-only stretch (the owner's real sessions locally and live, and the live logs) the live service was switched with `gcloud run services update --update-env-vars CSP_MODE=enforce` (revision 00059, no rebuild), the owner clicked through every feature live, and enforcing became the default in code (branch `feat/csp-enforce-default`; an unknown `CSP_MODE` now means enforce). Found on the way: the workflow's `--set-env-vars` replaces every variable on the service, so a `CSP_MODE` set by hand is wiped at the next deploy; that is why the default had to change. A changed policy goes out with `CSP_MODE=report-only` first.
3. ~~Creating a playlist is not idempotent~~ **Done 2026-11-01** (branch `fix/playlist-double-create`). It was not only a future risk with `allowReconnect`: today `removeModal()` is sent to the browser only when the handler finishes, and for the artists list the handler makes up to 50 requests one after another, so the dialog stays on screen with an active Create button and a second click was queued as a second creation. Fixed twice: `www/create-playlist.js` disables the button and says "Creating…" at the first click, and the server gives each opened dialog a number and handles its Create click once (three tests; with the guard removed, they fail). `allowReconnect` is still not on: the login would not survive a reconnect anyway (new session, token in memory).
4. **Share cards**: fetch the ten images in parallel with a timeout (a slow CDN can hold a download for a long time), and let only `https` Spotify addresses into `href` / `src` (as the browser copy already does).
5. **Chart font**: pick a font that exists in the image instead of "Gotham".
6. **Cloud housekeeping, partly done:** (2026-10-31, with the user's approval: the project-wide `secretAccessor` grant removed, the never-ready `bibliostatus-app` and `tuneteller-app` deleted, the unused lowercase secrets and the orphaned `themealot-app` / `tuneteller-app` images deleted; registry cleanup confirmed: `trackteller-app` 113 -> 39 versions.) **Still not verified:** a lifecycle rule on the build buckets (`run-sources-trackteller-app-europe-north1`, `trackteller-app_cloudbuild`; the listing showed none) and a budget alert for this project (the check could not be made: the Billing Budgets API is not enabled on the project `gcloud` uses as its quota project, and nothing was enabled).
7. **Registry cleanup:** the policy is live since 2026-10-27 (keep the 5 newest, delete after 14 days); Google runs it on its own schedule. Expected: `trackteller-app` from 113 versions to about 39 and the repository from about 14.4 GB to far less. Check in a day or two.
8. **Share cards:** Arabic, Thai, Devanagari and emoji still show as boxes.
9. **Spotify Development Mode:** only users added in the Spotify dashboard can log in. That is Spotify's rule, not a bug, but it limits who can use the app.
10. **Docs:** `PLAN.md` is the original build plan (status "IMPLEMENTED"); parts of it are out of date (files, `rocker/shiny:4.3.1`, time range sync, "incremental loading"). Left as it is on purpose; this file is the current plan.

### Where things are written down
`CLAUDE.md` (architecture and the pitfalls that cost time), `DEPLOY.md` (how it is deployed and set up), `README.md` and `docs/index.html` (what the app does), `infra/` (cloud setup scripts), and this file (decisions, findings, status).

### The frozen grey page (reported by the owner 2026-11-01, fixed on branch `fix/session-ended-message`)
**Symptom:** "sometimes the Top Artists page is frozen and has a gray filter when I come back to it". **Cause:** the websocket to the server had closed. Cloud Run ends a request at its 3600 s timeout, its maximum, and a Shiny session is one request: the logs show a session that ended at exactly 60.0 minutes; a sleeping device or a network change does the same sooner. Plain Shiny then puts an *empty* grey layer over the page (the "Disconnected from the server" box with a Reload link is a Shiny Server / Posit Connect feature), so nothing says what happened. It was not the CSP (report-only blocks nothing, and the live reports were empty). **Fix:** `app/www/session-ended.js` shows a message with a Reload button; a tab that was in the background when the connection dropped reloads itself on return; the next page says "Session expired. Please log in again." Tested by stopping the server under an open page, on all four paths (normal reload must say nothing; dropped connection; Reload button; background tab). **Not done:** keeping the login across a reload (refresh token in the browser, decision 2 option (b), not chosen: it widens the damage of any script injection); the timeout can't go above 3600 s.
