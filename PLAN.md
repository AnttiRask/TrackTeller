# TrackTeller

## Status: ✅ IMPLEMENTED

TrackTeller is a Spotify-connected Shiny web app that provides insights into your listening habits. It evolved from [spotify-playlist-generator-local](https://github.com/AnttiRask/spotify-playlist-generator-local).

---

## Implementation Summary

### What Was Done

1. **Custom OAuth Implementation** - Replaced spotifyr's localhost OAuth with server-side Authorization Code Flow
2. **Docker Deployment** - Containerized app with environment-based configuration
3. **Redesigned Visualizations** - Replaced deprecated audio features with new artist/genre/track visualizations
4. **New Playlist Generator** - Uses top tracks instead of deprecated recommendations API
5. **My Playlists** - Browse existing Spotify playlists
6. **Production Deployment** - Google Cloud Run with Secret Manager for credentials
7. **Mobile Responsiveness** - CSS media queries for tablets and phones

### Why the Redesign?

Spotify deprecated key API endpoints in November 2024:
- `/audio-features` - Returns 403 Forbidden
- `/recommendations` - Returns 403 Forbidden

The original app relied heavily on these endpoints. The redesigned app uses only available endpoints:
- `/me/top/artists` - User's top artists ✅
- `/me/top/tracks` - User's top tracks ✅
- `/artists/{id}/top-tracks` - Artist's popular tracks ✅
- `/me/playlists` - User's playlists ✅
- `/me/player/recently-played` - Recently played tracks ✅

---

## Current Features

### Tabs

| Tab | Description |
|-----|-------------|
| **Top Artists** | Landing page with login. Shows ranked list of your most-listened artists with popularity and Spotify links |
| **Top Tracks** | Your most played tracks ranked by listening frequency |
| **Top Genres** | Genre distribution chart across your top artists |
| **My Playlists** | Browse all your Spotify playlists with alphabetical letter filter, incremental loading, and progress indicator |
| **Create Playlist** | Generate new playlists from your listening data |

### Playlist Generator

Three sources for creating playlists:

1. **My Top Tracks** - Creates playlist from your personal top tracks
2. **Top Tracks from My Top Artists** - Collects popular tracks from your favorite artists
3. **Recently Played** - Uses your recently played tracks

Features:
- Live preview before generating
- Configurable track count (10-50)
- Time range options (4 weeks, 6 months, all time)
- Custom playlist naming
- Playlists include TrackTeller attribution in description

---

## Architecture

### Files Created

| File | Purpose |
|------|---------|
| `scripts/spotify_oauth.R` | Custom OAuth 2.0 implementation |
| `scripts/config.R` | Environment-based configuration |
| `Dockerfile` | Container definition (rocker/shiny:4.3.1) |
| `docker-compose.yml` | Development orchestration |
| `.env.example` | Credential template |
| `.dockerignore` | Docker build exclusions |
| `www/redirect.js` | JavaScript for OAuth redirects |
| `DEPLOY.md` | Google Cloud Run deployment guide |
| `deploy.sh` | Deployment helper script |

### Files Modified

| File | Changes |
|------|---------|
| `ui.R` | Function-based UI, login on Top Artists tab, 5 content tabs |
| `server.R` | Session-based tokens, visualizations, My Playlists, playlist generator |
| `css/styles.css` | Spotify theming, mobile responsiveness |
| `run.R` | Uses shinyApp() with uiFunc |

---

## Running the App

### Local Development

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env with your Spotify credentials

# Build and run with Docker
sudo docker compose up --build

# Access at http://127.0.0.1:8080
```

### Spotify Developer Setup

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/)
2. Create a new app
3. Add redirect URI: `http://127.0.0.1:8080` (for local dev)
4. Select "Web API" under APIs
5. Copy Client ID and Client Secret to `.env`

### Production Deployment (Google Cloud Run)

See [DEPLOY.md](DEPLOY.md) for detailed instructions.

Quick deploy:

```bash
./deploy.sh
```

Required environment variables:

- `SPOTIFY_CLIENT_ID`
- `SPOTIFY_CLIENT_SECRET`
- `APP_URL` (your Cloud Run HTTPS URL or custom domain)

**Important:** Add your production URL to Spotify Developer Dashboard redirect URIs.

### Custom Domain

The app is deployed at `https://trackteller.youcanbeapirate.com` using Cloud Run domain mapping with a CNAME record pointing to `ghs.googlehosted.com`. SSL is auto-provisioned by Google.

---

## OAuth Flow

```
User clicks "Login with Spotify"
         ↓
Redirect to Spotify authorization page
         ↓
User approves access
         ↓
Spotify redirects back with auth code
         ↓
Server exchanges code for access token
         ↓
Token stored in Shiny session
         ↓
API calls use session token
```

### Scopes Used

- `user-top-read` - Read user's top artists and tracks
- `user-read-recently-played` - Access recently played tracks
- `playlist-read-private` - Read user's private playlists
- `playlist-modify-public` - Create public playlists
- `playlist-modify-private` - Create private playlists

---

## Planned Features

### Unfollow Playlists

Add an "Unfollow" button to playlist cards in the My Playlists tab. The Spotify API has no delete endpoint, but unfollowing (`DELETE /v1/playlists/{playlist_id}/followers`) effectively removes a playlist from the user's library. For playlists the user owns, this is the equivalent of deleting them.

- Add unfollow button to each playlist card
- Confirmation dialog before unfollowing (destructive action)
- Remove the playlist from the local data after successful unfollow
- Update the playlist count and letter filter if needed
- No new OAuth scopes needed (`playlist-modify-public` and `playlist-modify-private` already included)

---

## Known Limitations

### Deprecated Spotify APIs
The following features from the original app are no longer possible:
- Audio features analysis (acousticness, danceability, energy, etc.)
- Recommendations based on target features
- Mood quadrant visualizations

### Workarounds Implemented
- Replaced audio features with artist metadata (popularity, followers, genres)
- Replaced recommendations with top tracks from user/artists
- Genre distribution provides insight into music taste

---

## Security Notes

- Client credentials stored in Google Cloud Secret Manager
- Tokens stored in Shiny session (not persistent)
- HTTPS required for production (Spotify requirement)
- State parameter used to prevent CSRF attacks
- Tokens cleared on logout/session end

---

## References

- [Spotify Authorization Code Flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow)
- [Spotify Web API Reference](https://developer.spotify.com/documentation/web-api)
- [rocker/shiny Docker Image](https://hub.docker.com/r/rocker/shiny)
