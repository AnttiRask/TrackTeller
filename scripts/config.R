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
    "playlist-modify-public"
)

# Validate configuration
validate_config <- function() {
    errors <- c()

    if (SPOTIFY_CLIENT_ID == "") {
        errors <- c(errors, "SPOTIFY_CLIENT_ID environment variable is not set")
    }

    if (SPOTIFY_CLIENT_SECRET == "") {
        errors <- c(errors, "SPOTIFY_CLIENT_SECRET environment variable is not set")
    }

    if (length(errors) > 0) {
        warning(paste("Configuration errors:", paste(errors, collapse = "; ")))
        return(FALSE)
    }

    TRUE
}

# Check if we're running in production mode
is_production <- function() {
    Sys.getenv("SHINY_ENV", "development") == "production"
}

# Get the port to run on
get_port <- function() {
    as.integer(Sys.getenv("PORT", "8080"))
}
