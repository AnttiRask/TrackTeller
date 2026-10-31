# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

TrackTeller is an R Shiny web app that connects to Spotify via OAuth 2.0 to visualize listening habits and create playlists. It's stateless — no database or cache, all data fetched live from the Spotify API. Deployed on Google Cloud Run.

## Development Commands

```bash
# Local development with Docker (hot-reloads everything under app/)
cp .env.example .env   # first time only, fill in Spotify credentials
sudo docker compose up --build

# Access at http://127.0.0.1:8080

# Deploy to Google Cloud Run
./deploy.sh

# Packages are restored inside the Docker image; renv::restore() on a machine whose R
# version differs from renv.lock (4.5.2) may not work
```

Tests (testthat, no live Spotify calls) run inside the production image, so they see the R and package versions that run in production:

```bash
docker build -t trackteller-ci .
tests/run_in_docker.sh trackteller-ci
```

CI runs the same script (`tests.yml`). httr2's mocks skip its retry loop, so the retry tests talk to a real local server (`start_flaky_server()` in `tests/testthat/helper-setup.R`). The server is tested too (`test-server.R`: `testServer(server, ...)` with Spotify mocked by `spotify_router()` in `helper-setup.R`; the mock session computes every output, so every tab asks Spotify, and a request the test didn't list fails it). What the tests can't do is the page itself and a real login: check those by hand. There is no linting.

## Architecture

### Entry Point & File Roles
- `app/run.R` — changes into `app/`, then boots the Shiny app (sources setup.R, ui.R and server.R, binds to `0.0.0.0:PORT`)
- `app/ui.R` — function-based UI (`uiFunc(req)`) that parses OAuth callback query params and builds a `bslib::page_navbar` with 5 tabs: Top Artists, Top Tracks, Recently Played, Top Genres, My Playlists
- `app/setup.R` — loaded once when the app starts (and by the tests): packages, `conflict_prefer()`, then every file in `scripts/` and `server/`. Nothing is sourced per visitor
- `app/server.R` — only puts the parts of `app/server/` together; what a part needs from another comes in as an argument, what others need from it goes out as its result: `auth.R` (login, token renewal, `api_get()` / `api_request()`; returns `auth`), `shared.R` (time range, number to show, remembered choices), `artists.R`, `tracks.R`, `recent.R`, `genres.R`, `downloads.R` (stats card downloads), `create_playlist.R`. Output ids are global (no namespaces), so `ui.R` didn't change. `is_authenticated` changes only at login and logout, not when the token is renewed (the lists would fetch again)
- `app/scripts/security.R` — `with_security_headers(app)` (used in `run.R`) wraps the app's page handler so the page carries `X-Frame-Options: DENY`, `X-Content-Type-Options`, `Referrer-Policy: strict-origin-when-cross-origin` (the login's code and state are in the address's query when Spotify sends the browser back: other sites must never get it), `Permissions-Policy`, and HSTS only when `X-Forwarded-Proto` says https (Cloud Run). Shiny has no setting for response headers, and `shiny.http.response.filter` does nothing. Static files get `nosniff` from Shiny itself. CI checks the headers on the running image. A Content-Security-Policy and `/health` are not built yet (plan, section 11)
- `app/scripts/health.R` — `GET /health` (`with_health_check()` in `run.R`, inside the security headers): 200 `ok`, or 503 `unhealthy: <names>` when `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` aren't 32 lowercase hex characters or, in production (`SHINY_ENV=production`, set in the Dockerfile), `APP_URL` isn't https. Names only, never values; no call to Spotify, so an outage there can't turn a deploy red; never cached. CI checks it on an image with and without credentials, and the deploy's smoke test requires 200 from the live revision
- `app/scripts/strings.R` (`TXT`: what the server says to the user), `variables.R` (card styles, stats card layout, time labels), `list_cards.R` (the cards of the three lists, one `list_card()` for all), `stats_card.R` (the share image: data frame in, image out). ImageMagick sets a whole text in one font and has no per-character fallback, so `card_font()` picks the CJK font (`fonts-noto-cjk`, ~90 MB in the image) for any text with Chinese, Japanese or Korean in it and Liberation Sans for the rest; `trunc_str()` counts widths (a CJK character = two letters). Arabic, Thai, Devanagari and emoji are not covered and show as boxes
- `app/scripts/spotify_oauth.R` — custom OAuth 2.0 Authorization Code Flow with httr2 (authorize URL, token exchange, refresh, expiry check with 5-min buffer); never throws, and never passes Spotify's response text on to the user
- `app/scripts/display.R` — the shared choices (`TIME_RANGES`, `COUNT_*`, `GENRE_CHART_MAX`) and pure helpers: `displayed_count()` and `count_note()` ("Showing 20 of 50 artists") for the lists, `sanitise_prefs()` for what the browser remembered
- `app/www/playlists-cache.js` — keeps a copy of the playlist list in `localStorage` (key `trackteller.playlists.<spotify user id>`): the module asks for it once per login (`playlist_cache_load`), saves a fresh complete list (`playlist_cache_save`), and removes it on logout or session expiry (`playlist_cache_clear`). On a return visit the saved copy (already A–Z, with the letter filter) is on screen at once while the real list loads in the background, and the real one replaces it when complete. What comes back from the browser is untrusted: `sanitise_cached_playlists()` keeps only well-formed rows and https links. ~760 KB for 4,200 playlists; if storage is blocked or full nothing is kept and everything still works. Reading and writing it must stay column-based (see the `tibble()` note below)
- `app/www/tabs.js` — before login only the Top Artists tab works (the others are dimmed with a "Log in to see this" tooltip, `aria-disabled`, and clicks are stopped on `window`, because Bootstrap listens in the capture phase on `document`); the page starts in the signed-out state and `output.is_authenticated` switches it. Logging out or an expired session also does `nav_select("main_navbar", "top_artists")`, so the user never ends up on an empty tab
- `app/www/preferences.js` — saves the two shared choices in `localStorage` and sends what was saved when the page connects (see "Shared choices" below)
- `app/scripts/dialogs.R` — `logout_dialog()` (asks before logging out; Cancel green, Log out the brand red)
- `app/scripts/charts.R` — `genre_chart()` and its sizing (`genre_chart_css_height()`, `genre_chart_min_height()`)
- `app/scripts/playlists_module.R` + `app/scripts/playlists.R` — the My Playlists tab as a Shiny module (`playlists_ui()` / `playlists_server()`) and its pure helpers (paging, letters, Finnish A–Z order, validation of the browser copy). Spotify gives 50 playlists per request with no filter, and overlapping requests are throttled (probed 2026-10-25 on a 4,213-playlist account: 85 pages = 47 s one after another, 73–85 s with 3–5 at once, one request stalling ~68 s), so the loader asks for one page at a time **without blocking the R session** (`spotify_get_async()`, a chain of promises), shows the playlists as they arrive in Spotify's order, 50 to a page, and switches on A–Z order and the letter filter when everything is here. It is tested with a fake Spotify (`testServer()`), including a 4,213-playlist run
- `app/scripts/spotify_api.R` — the Spotify API layer: `spotify_get()` / `spotify_post()` return `list(state, data, http_status, message)` (`ok`, `reauth`, `forbidden`, `rate_limited`, `error`) with timeouts and retries; parsers turn the JSON into tibbles and tolerate fields Spotify has removed (`popularity`, `followers`); playlist writes try the current endpoint and fall back to the newer one on 403/404
- `app/scripts/config.R` — reads env vars (`SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `APP_URL`), validates config
- `app/scripts/global.R` — Spotify brand colors and `theme_spotify()` ggplot theme

### Key Patterns
- **OAuth flow**: Spotify redirects back with `code`/`state` in the address → the server checks the `state`, exchanges the code for a token (and clears the address) → session-scoped `reactiveVal(token_info)` with auto-refresh. The `state` is `<nonce>.<issued at>.<HMAC-SHA256 signed with the client secret>` (`oauth_state_new()` / `oauth_state_check()`, nothing kept on the server), good for 10 minutes, and its nonce must equal the one the browser kept in `sessionStorage` while it was away at Spotify (`redirect.js` stores it, then reports it as `input$oauth_nonce` on the next connect and forgets it): that binds the login to the browser that started it. If the browser blocks storage the login is refused with a plain message. The login doesn't force Spotify's consent screen (`show_dialog` is left out), so a return visit is one click when consent already exists; only the first login after a Log out in the same session asks again (`force_dialog`), because Spotify would otherwise sign the same account straight back in and there'd be no way to switch accounts. `redirect.js` is loaded with a content hash in its address, because server and script must agree on how a login is passed on
- **Spotify API calls from the server**: `api_get()` / `api_request()` in `server/auth.R` run a call with the current token and renew it once on a 401; `stop_if_failed()` turns a failed call into a plain message in the output. `current_token()` is a plain function, not a reactive, so renewing the token doesn't re-run the data reactives
- **Things that cost us a day in the playlists tab, so they are written down:** (1) a long job must not block the R session, or the page can't answer (use `spotify_get_async()`; httr2's `req_perform_promise()` does not retry, so `spotify_call_async()` retries itself); (2) Shiny decides that an output is hidden when the browser *sends an input*, and a tab switch sends it just before the tab is shown, so nothing re-checks: outputs of a tab that must update without other input need `outputOptions(..., suspendWhenHidden = FALSE)`; (3) buttons made by `renderUI` restart counting at 0 and a click can be ignored as "unchanged": create the buttons once and use `updateActionButton(disabled = )`; (4) an output that returns several elements (`tagList`) becomes transparent to the layout (`display: contents`), so the page's 24 px gap lands between *each* card on top of its margin (32 px instead of 8): put the cards in one `div` of their own; (5) a banner made by `renderUI` is rebuilt for every update and its spinner starts over, which looks like flashing: create it once (`conditionalPanel` on an output) and update only its text; (6) the count that arrives can be short of Spotify's total (playlists removed by Spotify still show in its app but the API has nothing for them, and a page can come back one short): the loader ends at the page without a `next` link, never at a short page, and the tab says how many can't be loaded; (7) build a page of results with **one** `tibble()` from columns (`column()` in spotify_api.R), not one per row: per-row `tibble()` took 230 ms per page inside the running app and blocked the session for seconds (a test guards it)
- **Outputs are defined once**, in the body of their part of the server (`server/*.R`), and observers only change reactive values (`auth_message`, `user_display_name`). An output assigned inside an observer is thrown away when the observer re-runs, and an output in a panel that starts hidden needs `outputOptions(..., suspendWhenHidden = FALSE)`
- **Shared choices**: one bar above the tabs holds Time range (on Recently Played a greyed-out field that says "Recently Played", so the bar keeps its shape) and Number to show; every tab reads `time_range()` and `shown_count()`. Each list shows `displayed_count()` of them (never more than exist; the genre chart at most 20) and a note under it. The browser remembers both: `preferences.js` sends `input$saved_prefs` once per session, the server validates it (`sanitise_prefs()`), updates the controls, and the data waits (`prefs_ready`) until the remembered time range is in place so the default range isn't fetched first (1.5 s fallback if the script never reports). The script saves changes only after the server has answered with `prefs_applied`, otherwise Shiny's startup defaults would overwrite what was saved. Shiny requires custom message handlers to take exactly one argument
- **Layout**: each tab's sidebar ends with the cross-app links (`create_app_footer()`, as in BiblioStatus) and holds that tab's Share / Create Playlist buttons; there is no page-level footer. "Signed in as <name>" and the Logout button are `output$account_ui`, top right of the navbar (`nav_spacer()` + `nav_item()`), so they show on every tab; on a phone they are at the end of the collapsed menu. The genre chart is `genre_chart()` (`scripts/charts.R`) inside a plain `uiOutput` container that fills the rest of the screen (`calc(max(100vh - 235px, <18 px per bar + 90>))`) but never gets less than the bars need. Placed directly in the fill layout, bslib squeezes a plot to the space left over. The chart's text is 13 px (`theme_spotify(base_size = 13)`); the theme's default is 20
- **Playlists are always public, and the dialogs say so.** Spotify's API can't make a private playlist for this app: one created with `public: false` reads back as `public: true` (its create response wrongly says false), and `PUT /playlists/{id}` with `public: false` returns 200 and changes nothing, on both the old (`/users/{id}/playlists`) and the new (`/me/playlists`) create endpoint. Probed 2026-10-25 with the owner's account, with read-backs after 4 s. So there is no private option; the Create Playlist dialog and the result tell the user to use "Make private" in Spotify. Don't promise private playlists unless a new probe shows it works
- **Conditional UI**: `conditionalPanel` toggled by `output.is_authenticated` — pre-login shows welcome, post-login shows data
- **Stats cards**: `magick`-based image composition for shareable 1200×630 PNG cards with Spotify artist/track images
- **Cross-app footer**: `create_app_footer()` links to sibling apps on youcanbeapirate.com

### Styling
- `app/css/styles.css` — Spotify dark theme, mobile-responsive
- bslib Bootstrap 5 theme configured inline in `app/ui.R` with Spotify brand colors
- Font: Gotham via CDN

### Deployment
- Docker image based on `rocker/r-ver:4.5.2` (R version matches `renv.lock`): system libraries for `magick` and the share-card font, packages restored from Posit Package Manager's Linux binaries, non-root user `trackteller`, started with `Rscript app/run.R`. `.dockerignore` is an allowlist.
- **Changing R packages:** regenerate `renv.lock` inside the image's base with `infra/regenerate_renv_lock.sh` (keep its package list in sync with the `library()` calls). Don't snapshot on the laptop: local R is 4.6.1, the lock is for 4.5.2, and `renv::restore()` won't work here.
- **CI/CD** (`.github/workflows/`): `tests.yml` builds the image and checks that the app starts (the testthat suite runs in the same job); `deploy_shiny_app.yml` runs it first, then deploys with a keyless Workload Identity login as `trackteller-deploy` and smoke-tests the revision's `git-sha` label and `GET /`. It deploys on pushes to `main` that touch `app/**` or the build files, and on demand (Actions tab, or `gh workflow run deploy_shiny_app.yml --ref main`). Actions are pinned to commit SHAs; `dependabot.yml` covers Actions and Docker.
- The service runs as `trackteller-runtime` (access to the two Spotify secrets only). Setup scripts and the permission test are in `infra/` (`setup_keyless_deploy.sh`, `test_deploy_identity.sh`); the registry cleanup policy is `infra/artifact-registry-cleanup.json`.
- `deploy.sh` is the manual fallback: it reads no `.env` and asks nothing; it uses the credentials in Secret Manager (or both from the environment, which it then stores), validates them (32 hex characters, never printed), and runs `gcloud run deploy` with the same flags as the workflow plus the `git-sha` label (`-dirty` for uncommitted changes). The production URL is fixed. `--dry-run` checks and prints without changing anything. Keep its flags and the workflow's in sync.
- `APP_URL` in `.env` is for local dev; `deploy.sh` hardcodes production URL
- `docs/index.html` is a static GitHub Pages landing page (not part of the Shiny app)

## Where things stand

The 2026 refactor is built and live; what is still open (a Content-Security-Policy, an uptime check on `/health`, idempotent playlist creation, parallel card images, cloud housekeeping) is listed in section 11 of `trackteller-refactor-plan.md`, with the reasons. None of it is approved until the user says so. Deploying and running the cloud setup are described in `DEPLOY.md`.

## R Coding Conventions

- Use Tidyverse syntax and packages (dplyr, purrr, stringr, tidyr, ggplot2)
- Package dependencies managed with `renv` (edit `renv.lock`, not manual installs)
- `conflicted` library used to resolve namespace clashes (e.g., `dplyr::filter` over `stats::filter`)
