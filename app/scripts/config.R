# Application Configuration
# Load settings from environment variables

# Spotify API credentials (set these as environment variables)
SPOTIFY_CLIENT_ID <- Sys.getenv("SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET <- Sys.getenv("SPOTIFY_CLIENT_SECRET", "")

# Application URL configuration
# For local development: http://127.0.0.1:8080
# For production: your deployed HTTPS URL
APP_URL <- Sys.getenv("APP_URL", "http://127.0.0.1:8080")

# Construct the redirect URI for OAuth callback
# Shiny doesn't have routes, so redirect to root URL
REDIRECT_URI <- APP_URL

# Spotify OAuth scopes needed by this app
SPOTIFY_SCOPES <- c(
    "user-top-read",
    "user-read-recently-played",
    "playlist-read-private",
    "playlist-modify-public",
    "playlist-modify-private"
)

# Check if we're running in production mode
is_production <- function() {
    Sys.getenv("SHINY_ENV", "development") == "production"
}
