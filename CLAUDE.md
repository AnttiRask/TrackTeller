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

# Restore R packages locally (if running outside Docker)
R -e "renv::restore()"
```

There are no tests or linting configured.

## Architecture

### Entry Point & File Roles
- `app/run.R` — changes into `app/`, then boots the Shiny app (sources ui.R and server.R, binds to `0.0.0.0:PORT`)
- `app/ui.R` — function-based UI (`uiFunc(req)`) that parses OAuth callback query params and builds a `bslib::page_navbar` with 5 tabs: Top Artists, Top Tracks, Recently Played, Top Genres, My Playlists
- `app/server.R` — all server logic: OAuth token exchange, Spotify API calls (`httr::GET/POST`), reactive data fetching, playlist creation, stats card image generation (`magick`)
- `app/scripts/spotify_oauth.R` — custom OAuth 2.0 Authorization Code Flow (authorize URL, token exchange, refresh, expiry check with 5-min buffer)
- `app/scripts/config.R` — reads env vars (`SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `APP_URL`), validates config
- `app/scripts/global.R` — Spotify brand colors and `theme_spotify()` ggplot theme

### Key Patterns
- **OAuth flow**: UI passes `code`/`state` via hidden inputs → server exchanges for token → session-scoped `reactiveVal(token_info)` with auto-refresh
- **Spotify API helper**: `spotify_api_call()` in server.R wraps all API requests with token refresh, pagination, and error handling
- **Conditional UI**: `conditionalPanel` toggled by `output.is_authenticated` — pre-login shows welcome, post-login shows data
- **Stats cards**: `magick`-based image composition for shareable 1200×630 PNG cards with Spotify artist/track images
- **Cross-app footer**: `create_app_footer()` links to sibling apps on youcanbeapirate.com

### Styling
- `app/css/styles.css` — Spotify dark theme, mobile-responsive
- bslib Bootstrap 5 theme configured inline in `app/ui.R` with Spotify brand colors
- Font: Gotham via CDN

### Deployment
- Docker image based on `rocker/shiny:4.3.1`
- **CI/CD** (`.github/workflows/`): `tests.yml` builds the image and checks that the app starts (a testthat suite comes later); `deploy_shiny_app.yml` runs it first, then deploys with a keyless Workload Identity login as `trackteller-deploy` and smoke-tests the revision's `git-sha` label and `GET /`. It deploys on pushes to `main` that touch `app/**` or the build files, and on demand (Actions tab, or `gh workflow run deploy_shiny_app.yml --ref main`). Actions are pinned to commit SHAs; `dependabot.yml` covers Actions and Docker.
- The service runs as `trackteller-runtime` (access to the two Spotify secrets only). Setup scripts and the permission test are in `infra/` (`setup_keyless_deploy.sh`, `test_deploy_identity.sh`); the registry cleanup policy is `infra/artifact-registry-cleanup.json`.
- `deploy.sh` is the manual fallback: Secret Manager credential storage, validation (32-char hex), and `gcloud run deploy` with the same flags as the workflow. Keep the two in sync.
- `APP_URL` in `.env` is for local dev; `deploy.sh` hardcodes production URL
- `docs/index.html` is a static GitHub Pages landing page (not part of the Shiny app)

## R Coding Conventions

- Use Tidyverse syntax and packages (dplyr, purrr, stringr, tidyr, ggplot2)
- Package dependencies managed with `renv` (edit `renv.lock`, not manual installs)
- `conflicted` library used to resolve namespace clashes (e.g., `dplyr::filter` over `stats::filter`)
