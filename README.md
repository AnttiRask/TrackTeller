# Spotify: Favorite Artist Analyzer and Playlist Generator :radio:

This app uses the Spotify API to...

* fetch 2 random artists from users' top 20 artists
* visualize and compare
    * average features per album
    * average features per artist
    * mood quadrants (scatterplot between two features)
* create new playlists
    * using user's top (1-5) artists as seed
    * choosing features (0-1) as targets


## Quick Start (Online Version)

Users simply click "Login with Spotify" - no developer credentials needed!

### For Developers: Deploying the App

#### Prerequisites

1. **Create a Spotify Developer App:**
   - Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/)
   - Create a new app
   - Add your deployment URL as a Redirect URI (e.g., `https://your-app.example.com/callback`)
   - Note your Client ID and Client Secret

2. **Set up environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your Spotify credentials and app URL
   ```

#### Deploy with Docker

```bash
# Build and run
docker-compose up --build

# The app will be available at http://localhost:8080
```

#### Deploy to Cloud Platforms

The app can be deployed to any platform supporting Docker:
- **DigitalOcean App Platform**
- **AWS ECS / Fargate**
- **Google Cloud Run**
- **Azure Container Instances**

Set these environment variables in your cloud platform:
- `SPOTIFY_CLIENT_ID`
- `SPOTIFY_CLIENT_SECRET`
- `APP_URL` (your production HTTPS URL)
- `SHINY_ENV=production`

**Important:** Spotify requires HTTPS for OAuth redirect URIs in production (as of November 2025).


## Local Development

For running the app locally during development:

```bash
# Install dependencies
R -e "renv::restore()"

# Set environment variables
export SPOTIFY_CLIENT_ID=your_client_id
export SPOTIFY_CLIENT_SECRET=your_client_secret
export APP_URL=http://127.0.0.1:8080

# Run the app
Rscript run.R
```


## How it started

The inspiration for this project came from R User Group Helsinki's [workshop](https://github.com/eivicent/r-meetups-hki/tree/main/2023_03_28_SpotifyR) in March 2023. We learned to use the [Spotify API](https://developer.spotify.com/documentation/web-api) using the {spotifyr} package.

I used some of the original functions, but also came up with some new ones. The biggest change, though, was creating a Shiny app to combine the different functions as a coherent whole.


## Architecture

The app consists of:

### 1. UI (`ui.R`)
* Function-based UI for OAuth handling
* Shiny theme ('cyborg') with custom CSS
* [Font Awesome](https://fontawesome.com/) Spotify icon
* autoWaiter() for loading animations
* Conditional panels based on authentication state

### 2. Server (`server.R`)
* OAuth token management with automatic refresh
* Session-based authentication (no credentials stored)
* Reactive expressions for:
    * Fetching top artists and track features
    * Summarizing album features
    * Creating interactive plots with {plotly}
* Playlist creation via Spotify API

### 3. OAuth Module (`scripts/spotify_oauth.R`)
* Custom implementation of Spotify Authorization Code Flow
* Token exchange and refresh handling
* Secure callback processing

### 4. Configuration (`scripts/config.R`)
* Environment-based configuration
* Support for development and production modes


## Tech Stack

* **R** with **Shiny** for the web framework
* **spotifyr** for Spotify API integration
* **httr** for OAuth and HTTP requests
* **plotly** and **ggplot2** for visualizations
* **Docker** for containerization
* **renv** for dependency management


## Contributing

Is there something you would like to see? Let me know by opening an issue!
