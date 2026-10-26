# 🎧 TrackTeller

**TrackTeller** is a Shiny web app that connects to your Spotify account to visualize your listening habits and create playlists from your personal data.

## 🔍 Features

- 🎤 View your top artists ranked by listening frequency (10–50, with popularity and follower count)
- 🎵 Browse your most played tracks with artist, album, duration, and Spotify links
- 🕐 See your recently played tracks
- 🎼 Explore genre distribution with interactive tooltips showing contributing artists
- 📋 Browse all your Spotify playlists (thousands are fine): 50 to a page, A–Z with a first-letter filter, loaded in the background, and kept in your browser so a return visit is instant
- ✨ Create new playlists from your top tracks, favorite artists, or recently played (they are always public: Spotify doesn't let apps make private ones, and the app tells you how to make them private)
- 📸 Download shareable stats cards (top 10 artists or tracks with Spotify images; names in Chinese, Japanese and Korean too)
- 🎚️ One time range and one "number to show" for every tab, remembered in your browser
- 📱 Mobile-responsive design
- 🔒 Secure OAuth with Spotify: signed, expiring `state` bound to your browser; nothing about you is stored on the server

## 📸 Screenshot

![TrackTeller screenshot](img/screenshot.png)

## 🚀 Live App

👉 [Try it live on Google Cloud Run](https://trackteller.youcanbeapirate.com)

## 🛠️ Project Structure

```text
TrackTeller/
├── app/                        # Everything that goes into the Docker image
│   ├── run.R                   # Entry point: sources setup.R, ui.R, server.R and starts the app
│   ├── setup.R                 # Packages and all code, loaded once at start
│   ├── ui.R                    # Function-based UI (5 tabs)
│   ├── server.R                # Puts the parts of server/ together
│   ├── server/                 # auth, shared choices, one file per tab, downloads, playlist creation
│   ├── scripts/
│   │   ├── spotify_oauth.R     # OAuth 2.0: signed state, token exchange and refresh (httr2)
│   │   ├── spotify_api.R       # Spotify API layer: states, retries, timeouts, parsers
│   │   ├── playlists_module.R  # My Playlists tab (Shiny module) and playlists.R, its helpers
│   │   ├── list_cards.R        # The cards of the three lists
│   │   ├── stats_card.R        # The share image (magick)
│   │   ├── display.R, charts.R, dialogs.R, strings.R, variables.R, config.R, global.R
│   ├── css/styles.css          # Spotify dark theme + mobile responsiveness
│   └── www/                    # redirect.js, preferences.js, tabs.js, playlists-cache.js, favicon
├── tests/                      # testthat suite (Spotify mocked), run inside the production image
├── infra/                      # Cloud setup scripts and the registry cleanup policy
├── .github/workflows/          # tests.yml and deploy_shiny_app.yml (CI/CD), Dependabot
├── docs/index.html             # Static landing page (GitHub Pages)
├── Dockerfile                  # rocker/r-ver:4.5.2 + magick, fonts, packages from renv.lock
├── docker-compose.yml          # Local development
├── deploy.sh                   # Manual deploy to Cloud Run (the workflow does it normally)
├── DEPLOY.md                   # How it is deployed and how to set it up
├── CLAUDE.md                   # Architecture notes and pitfalls, for contributors and Claude Code
├── PLAN.md                     # The original build plan (historical; the refactor plan below is the current one)
├── trackteller-refactor-plan.md  # The 2026 refactor: decisions, findings, what is open
├── .env.example                # Credential template
└── renv.lock                   # Package dependency lock file (R 4.5.2)
```

## 🔄 How It Works

1. **Login**: Click "Log in with Spotify" to authenticate via OAuth.
2. **Top Artists**: See your most-listened artists ranked with popularity scores and Spotify links.
3. **Top Tracks**: Browse your most played tracks with artist, album, and popularity info.
4. **Recently Played**: See what you've been listening to lately.
5. **Top Genres**: Visualize the genre distribution across your top artists.
6. **My Playlists**: Browse all your Spotify playlists, 50 to a page. They appear as they load; when everything is here you get A–Z order and the first-letter filter. A copy is kept in your browser (and removed at logout) so the next visit starts instantly. If Spotify counts playlists its API no longer has, the tab says how many can't be loaded.
7. **Create Playlist**: Generate new playlists from top artists, top tracks, or recently played — directly from each tab. They are public (Spotify's API can't make private ones); open one in Spotify and choose "Make private" if you want.
8. **Share Stats**: Download a 1200×630 PNG card for Top Artists or Top Tracks, complete with Spotify images.

## 🔐 API Keys Required

| Variable | Description |
| -------- | ----------- |
| `SPOTIFY_CLIENT_ID` | Spotify Developer app client ID |
| `SPOTIFY_CLIENT_SECRET` | Spotify Developer app client secret |
| `APP_URL` | Your app's URL (for OAuth redirect) |

Set these as environment variables or in a `.env` file.

## 🧪 Local Development

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env with your Spotify credentials

# Build and run with Docker (everything under app/ reloads on change)
sudo docker compose up --build

# Access at http://127.0.0.1:8080
```

Add `http://127.0.0.1:8080` as a redirect URI in your Spotify app (Spotify doesn't allow `localhost`).

### Tests

The tests run inside the production image, so they see the same R and package versions as production, and they never call Spotify (it is mocked):

```bash
docker build -t trackteller-ci .
tests/run_in_docker.sh trackteller-ci
```

They cover the API layer and its retries, the parsers, the OAuth flow, the server (`testServer()`), the My Playlists module (including a 4,213-playlist run) and the share cards. The page itself and a real login are checked by hand.

## 🚀 Deployment

Deployed on **Google Cloud Run**, with the Spotify credentials in **Secret Manager** and a least-privilege runtime account. A push to `main` that touches the app runs the tests and, if they pass, deploys through GitHub Actions with a keyless (Workload Identity) login, then smoke-tests the new revision. `./deploy.sh` is the manual fallback.

See [DEPLOY.md](DEPLOY.md) for how it is set up and run.

## 📦 Required R Packages

- [bslib](https://rstudio.github.io/bslib/) - Bootstrap 5 UI components and theming
- [conflicted](https://conflicted.r-lib.org/) - Conflict resolution for functions
- [dplyr](https://dplyr.tidyverse.org/) - Data manipulation
- [ggplot2](https://ggplot2.tidyverse.org/) - Data visualization
- [httr2](https://httr2.r-lib.org/) - HTTP requests, retries and OAuth token calls
- [jsonlite](https://github.com/jeroen/jsonlite) - JSON serialization
- [magick](https://docs.ropensci.org/magick/) - Image compositing for stats cards
- [plotly](https://plotly-r.com/) - Interactive plots
- [purrr](https://purrr.tidyverse.org/) - Functional programming helpers
- [shiny](https://shiny.posit.co/) - Web application framework
- [stringr](https://stringr.tidyverse.org/) - String manipulation
- [tidyr](https://tidyr.tidyverse.org/) - Data tidying
- [waiter](https://waiter.john-coene.com/) - Loading animations

Used directly and installed with the packages above: [openssl](https://jeroen.cloud/openssl/) (the signed OAuth `state`), [stringi](https://stringi.gagolewski.com/) (text width on the share cards), [promises](https://rstudio.github.io/promises/) and [later](https://r-lib.github.io/later/) (the playlist loader). Tests use [testthat](https://testthat.r-lib.org/) (not part of the image).

## 🎨 Tech Stack

| Component | Technology |
| --------- | ---------- |
| Language | R |
| Framework | Shiny + bslib |
| Music Data | Spotify Web API |
| Visualizations | plotly + ggplot2 |
| Image Processing | magick (ImageMagick) |
| Styling | Custom CSS (dark theme) |
| Tests | testthat 3, `testServer()`, httr2 mocks |
| Containerization | Docker (rocker/r-ver) |
| Deployment | Google Cloud Run, GitHub Actions (keyless) |
| Secrets | Google Cloud Secret Manager |

## 💡 How It Started

The inspiration for this project came from R User Group Helsinki's [workshop](https://github.com/eivicent/r-meetups-hki/tree/main/2023_03_28_SpotifyR) in March 2023. We learned to use the [Spotify API](https://developer.spotify.com/documentation/web-api) using the {spotifyr} package.

The original app relied on Spotify's audio features and recommendations APIs, which were [deprecated in November 2024](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api). TrackTeller is a complete redesign using only currently available endpoints.

## 📄 License

[MIT](https://opensource.org/license/mit)

## 👤 Author

Created by [Antti Rask](https://anttirask.github.io)
