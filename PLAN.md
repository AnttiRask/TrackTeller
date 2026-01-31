# Plan: Deploy Spotify Playlist Generator Online

## Overview

This project converts the local [spotify-playlist-generator-local](https://github.com/AnttiRask/spotify-playlist-generator-local) Shiny app into an online web application. The main challenge is redesigning the Spotify OAuth flow, which currently relies on `localhost:1410` callbacks that don't work in hosted environments.

**Recommended approach:** Docker deployment with custom OAuth implementation (ShinyApps.io has low feasibility due to OAuth limitations).

---

## Current State (Local Version)

- **Framework:** Shiny app (ui.R, server.R, run.R)
- **Spotify integration:** spotifyr package with OAuth to `localhost:1410`
- **Credential model:** Users enter their own Spotify Developer credentials in the UI
- **Dependencies:** renv with 104 packages (R 4.3.1)
- **Features:**
  - View audio features per album
  - Compare average features between artists
  - Mood quadrant visualization
  - Generate playlists based on target features

---

## Why ShinyApps.io Won't Work

ShinyApps.io has **low feasibility** for this app because:

1. The spotifyr package uses a browser pop-up OAuth flow that times out on hosted environments
2. The OAuth callback to `localhost:1410` cannot be received by the shinyapps.io container
3. Limited control over server configuration prevents custom OAuth handling

---

## Recommended Solution: Docker + Custom OAuth

### Architecture Changes

1. **Single Spotify Developer App** - One app registration (owner's credentials), not per-user
2. **Server-side OAuth** - Custom implementation using httr instead of spotifyr's built-in auth
3. **Function-based UI** - Converts static UI to handle OAuth redirects
4. **Session-based tokens** - Store access tokens in Shiny session, not environment variables
5. **Docker deployment** - Containerized for cloud hosting (DigitalOcean, AWS, etc.)

---

## Key Changes Required

### 1. Create Custom OAuth Module
**New file:** `scripts/spotify_oauth.R`

Implement Spotify OAuth 2.0 Authorization Code Flow:
- `spotify_authorize_url()` - Generate authorization URL with scopes
- `spotify_exchange_code()` - Exchange auth code for access/refresh tokens
- `spotify_refresh_token()` - Handle automatic token refresh
- `spotify_get_current_user()` - Verify token and get user info

### 2. Create Configuration Module
**New file:** `scripts/config.R`

Environment-based configuration:
- Read `SPOTIFY_CLIENT_ID` from environment
- Read `SPOTIFY_CLIENT_SECRET` from environment
- Read `SPOTIFY_REDIRECT_URI` from environment (production URL)

### 3. Convert UI to Function-Based
**Modify:** `ui.R`

- Change from static `fluidPage(...)` to `uiFunc <- function(req) {...}`
- Check URL for OAuth callback code parameter
- Redirect unauthenticated users to Spotify authorization
- Remove Client ID/Secret input fields
- Add "Login with Spotify" button
- Show user profile after authentication

### 4. Update Server for Session-Based Tokens
**Modify:** `server.R`

- Remove credential input handling (lines 29-45)
- Store access token in `session$userData$access_token`
- Store refresh token in `session$userData$refresh_token`
- Track token expiry in `session$userData$token_expires`
- Replace `get_authorized()` calls with session token usage
- Add automatic token refresh logic when token expires
- Remove env variable cleanup (lines 363-366)

### 5. Update Entry Point
**Modify:** `run.R`

- Use `shinyApp(ui = uiFunc, server = server)` instead of `runApp()`
- Source the OAuth module

### 6. Create Docker Configuration
**New files:**
- `Dockerfile` - Based on `rocker/shiny:4.3.1`
- `docker-compose.yml` - Local development with environment variables
- `.env.example` - Template for credentials (not committed)
- `.dockerignore` - Exclude unnecessary files from image

---

## Hosting Options Comparison

| Platform | Feasibility | Pros | Cons |
|----------|-------------|------|------|
| ShinyApps.io | LOW | Easy deployment | OAuth pop-up times out |
| Docker + Cloud | HIGH | Full control, scalable | Requires Docker knowledge |
| Self-hosted Shiny Server | MEDIUM | Complete control | More maintenance |

**Recommended:** Docker on DigitalOcean App Platform, AWS ECS, or similar managed container service.

---

## Implementation Order

1. **Copy base files** from spotify-playlist-generator-local
2. **Create Spotify Developer app** with production redirect URI
3. **Implement OAuth module** (`scripts/spotify_oauth.R`)
4. **Create config module** (`scripts/config.R`)
5. **Convert UI** to function-based approach
6. **Update Server** for session-based token management
7. **Update run.R** entry point
8. **Create Docker configuration** files
9. **Test locally** with Docker Compose
10. **Deploy to cloud** platform
11. **Configure SSL/HTTPS** (mandatory for Spotify after Nov 2025)

---

## Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `scripts/spotify_oauth.R` | Custom OAuth 2.0 implementation |
| `scripts/config.R` | Environment-based configuration |
| `Dockerfile` | Container definition |
| `docker-compose.yml` | Development orchestration |
| `.env.example` | Credential template |
| `.dockerignore` | Docker build exclusions |

### Modified Files (from local version)
| File | Changes |
|------|---------|
| `ui.R` | Convert to function-based, add login button, remove credential inputs |
| `server.R` | Session-based tokens, remove env vars, add token refresh |
| `scripts/functions.R` | Remove or refactor `get_authorized()` |
| `run.R` | Use shinyApp() with uiFunc |

---

## Verification Plan

1. **Local Docker test:** `docker-compose up` and verify OAuth flow works
2. **OAuth flow test:**
   - Click "Login with Spotify"
   - Verify redirect to Spotify authorization page
   - Approve access
   - Verify return to app with user authenticated
3. **Feature test:** Verify all tabs work:
   - Feature per Album (line plots)
   - Average Features (box plots)
   - Mood Quadrants (scatter plots)
   - Playlist Generator (creates playlist)
4. **Playlist creation:** Test creating a playlist on user's Spotify account
5. **Token refresh:** Keep app open past token expiry (1 hour) to verify refresh works
6. **Error handling:** Test invalid tokens, network errors, API rate limits

---

## Security Considerations

- Store Client ID/Secret as environment variables, never in code
- Use HTTPS (required by Spotify after November 27, 2025)
- Tokens stored only in Shiny session (not persistent storage)
- Never log access tokens
- Clear tokens on session end
- Use secure random state parameter for OAuth to prevent CSRF

---

## Spotify API Requirements

### Scopes Needed
- `user-top-read` - Read user's top artists and tracks
- `playlist-modify-public` - Create and modify public playlists

### Spotify Developer App Setup
1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/)
2. Create a new app
3. Add redirect URI: `https://your-production-domain.com` (must be HTTPS)
4. Note the Client ID and Client Secret
5. Store as environment variables

---

## References

- [Spotify Authorization Code Flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow)
- [Hadley Wickham's Shiny OAuth Pattern](https://gist.github.com/hadley/144c406871768d0cbe66b0b810160528)
- [Spotify OAuth Migration (Nov 2025)](https://developer.spotify.com/blog/2025-10-14-reminder-oauth-migration-27-nov-2025)
- [rocker/shiny Docker Image](https://hub.docker.com/r/rocker/shiny)
