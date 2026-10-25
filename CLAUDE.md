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

CI runs the same script (`tests.yml`). httr2's mocks skip its retry loop, so the retry tests talk to a real local server (`start_flaky_server()` in `tests/testthat/helper-setup.R`). The server code (`app/server.R`) is not covered by tests yet; check it by hand with a real login. There is no linting.

## Architecture

### Entry Point & File Roles
- `app/run.R` — changes into `app/`, then boots the Shiny app (sources ui.R and server.R, binds to `0.0.0.0:PORT`)
- `app/ui.R` — function-based UI (`uiFunc(req)`) that parses OAuth callback query params and builds a `bslib::page_navbar` with 5 tabs: Top Artists, Top Tracks, Recently Played, Top Genres, My Playlists
- `app/server.R` — all server logic: OAuth login and token renewal, reactive data fetching, playlist creation, stats card image generation (`magick`)
- `app/scripts/spotify_oauth.R` — custom OAuth 2.0 Authorization Code Flow with httr2 (authorize URL, token exchange, refresh, expiry check with 5-min buffer); never throws, and never passes Spotify's response text on to the user
- `app/scripts/display.R` — the shared choices (`TIME_RANGES`, `COUNT_*`, `GENRE_CHART_MAX`) and pure helpers: `displayed_count()` and `count_note()` ("Showing 20 of 50 artists") for the lists, `sanitise_prefs()` for what the browser remembered
- `app/www/preferences.js` — saves the two shared choices in `localStorage` and sends what was saved when the page connects (see "Shared choices" below)
- `app/scripts/charts.R` — `genre_chart()` and `genre_chart_height()`
- `app/scripts/spotify_api.R` — the Spotify API layer: `spotify_get()` / `spotify_post()` return `list(state, data, http_status, message)` (`ok`, `reauth`, `forbidden`, `rate_limited`, `error`) with timeouts and retries; parsers turn the JSON into tibbles and tolerate fields Spotify has removed (`popularity`, `followers`); playlist writes try the current endpoint and fall back to the newer one on 403/404
- `app/scripts/config.R` — reads env vars (`SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `APP_URL`), validates config
- `app/scripts/global.R` — Spotify brand colors and `theme_spotify()` ggplot theme

### Key Patterns
- **OAuth flow**: Spotify redirects back with `code`/`state` in the address → the server exchanges the code for a token (and clears the address) → session-scoped `reactiveVal(token_info)` with auto-refresh. The `state` value is not checked yet
- **Spotify API calls from the server**: `api_get()` / `api_request()` in server.R run a call with the current token and renew it once on a 401; `stop_if_failed()` turns a failed call into a plain message in the output. `current_token()` is a plain function, not a reactive, so renewing the token doesn't re-run the data reactives
- **Outputs are defined once**, at the top of `server()`, and observers only change reactive values (`auth_message`, `user_display_name_val`). An output assigned inside an observer is thrown away when the observer re-runs, and an output in a panel that starts hidden needs `outputOptions(..., suspendWhenHidden = FALSE)`
- **Shared choices**: one bar above the tabs holds Time range (not on Recently Played) and Number to show; every tab reads `time_range()` and `shown_count()`. Each list shows `displayed_count()` of them (never more than exist; the genre chart at most 20) and a note under it. The browser remembers both: `preferences.js` sends `input$saved_prefs` once per session, the server validates it (`sanitise_prefs()`), updates the controls, and the data waits (`prefs_ready`) until the remembered time range is in place so the default range isn't fetched first (1.5 s fallback if the script never reports). The script saves changes only after the server has answered with `prefs_applied`, otherwise Shiny's startup defaults would overwrite what was saved. Shiny requires custom message handlers to take exactly one argument
- **Layout**: each tab's sidebar ends with the cross-app links (`create_app_footer()`, as in BiblioStatus) and holds that tab's Share / Create Playlist buttons; there is no page-level footer. The genre chart is `genre_chart()` (`scripts/charts.R`) inside a plain `uiOutput` container whose height follows the number of bars: placed directly in the fill layout, bslib squeezes a plot to the space left over
- **Playlists** are private unless the box in the Create Playlist dialog is ticked
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
- **CI/CD** (`.github/workflows/`): `tests.yml` builds the image and checks that the app starts (a testthat suite comes later); `deploy_shiny_app.yml` runs it first, then deploys with a keyless Workload Identity login as `trackteller-deploy` and smoke-tests the revision's `git-sha` label and `GET /`. It deploys on pushes to `main` that touch `app/**` or the build files, and on demand (Actions tab, or `gh workflow run deploy_shiny_app.yml --ref main`). Actions are pinned to commit SHAs; `dependabot.yml` covers Actions and Docker.
- The service runs as `trackteller-runtime` (access to the two Spotify secrets only). Setup scripts and the permission test are in `infra/` (`setup_keyless_deploy.sh`, `test_deploy_identity.sh`); the registry cleanup policy is `infra/artifact-registry-cleanup.json`.
- `deploy.sh` is the manual fallback: Secret Manager credential storage, validation (32-char hex), and `gcloud run deploy` with the same flags as the workflow. Keep the two in sync.
- `APP_URL` in `.env` is for local dev; `deploy.sh` hardcodes production URL
- `docs/index.html` is a static GitHub Pages landing page (not part of the Shiny app)

## R Coding Conventions

- Use Tidyverse syntax and packages (dplyr, purrr, stringr, tidyr, ggplot2)
- Package dependencies managed with `renv` (edit `renv.lock`, not manual installs)
- `conflicted` library used to resolve namespace clashes (e.g., `dplyr::filter` over `stats::filter`)
