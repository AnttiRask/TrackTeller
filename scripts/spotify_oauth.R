# Spotify OAuth 2.0 Authorization Code Flow
# Custom implementation for web deployment

library(httr)
library(jsonlite)

# Spotify OAuth endpoints
SPOTIFY_AUTH_URL <- "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_URL <- "https://accounts.spotify.com/api/token"

# Generate the Spotify authorization URL
spotify_authorize_url <- function(client_id, redirect_uri, scope, state = NULL) {
    if (is.null(state)) {
        state <- paste0(sample(c(letters, LETTERS, 0:9), 32, replace = TRUE), collapse = "")
    }

    params <- list(
        client_id = client_id,
        response_type = "code",
        redirect_uri = redirect_uri,
        scope = paste(scope, collapse = " "),
        state = state,
        show_dialog = "true"
    )

    query_string <- paste(
        names(params),
        sapply(params, URLencode, reserved = TRUE),
        sep = "=",
        collapse = "&"
    )

    list(
        url = paste0(SPOTIFY_AUTH_URL, "?", query_string),
        state = state
    )
}

# Exchange authorization code for access token
spotify_exchange_code <- function(code, client_id, client_secret, redirect_uri) {
    response <- POST(
        SPOTIFY_TOKEN_URL,
        body = list(
            grant_type = "authorization_code",
            code = code,
            redirect_uri = redirect_uri,
            client_id = client_id,
            client_secret = client_secret
        ),
        encode = "form"
    )

    if (status_code(response) != 200) {
        error_content <- content(response, "text", encoding = "UTF-8")
        stop(paste("Token exchange failed:", error_content))
    }

    token_data <- content(response, "parsed")

    list(
        access_token = token_data$access_token,
        token_type = token_data$token_type,
        expires_in = token_data$expires_in,
        refresh_token = token_data$refresh_token,
        scope = token_data$scope,
        expires_at = Sys.time() + token_data$expires_in
    )
}

# Refresh an expired access token
spotify_refresh_token <- function(refresh_token, client_id, client_secret) {
    response <- POST(
        SPOTIFY_TOKEN_URL,
        body = list(
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = client_id,
            client_secret = client_secret
        ),
        encode = "form"
    )

    if (status_code(response) != 200) {
        error_content <- content(response, "text", encoding = "UTF-8")
        stop(paste("Token refresh failed:", error_content))
    }

    token_data <- content(response, "parsed")

    list(
        access_token = token_data$access_token,
        token_type = token_data$token_type,
        expires_in = token_data$expires_in,
        refresh_token = if (!is.null(token_data$refresh_token)) token_data$refresh_token else refresh_token,
        scope = token_data$scope,
        expires_at = Sys.time() + token_data$expires_in
    )
}

# Check if token is expired (with 5 minute buffer)
token_is_expired <- function(token_info) {
    if (is.null(token_info) || is.null(token_info$expires_at)) {
        return(TRUE)
    }
    Sys.time() >= (token_info$expires_at - 300)
}

# Get valid access token, refreshing if needed
get_valid_token <- function(token_info, client_id, client_secret) {
    if (is.null(token_info)) {
        return(NULL)
    }

    if (token_is_expired(token_info)) {
        if (!is.null(token_info$refresh_token)) {
            token_info <- spotify_refresh_token(
                token_info$refresh_token,
                client_id,
                client_secret
            )
        } else {
            return(NULL)
        }
    }

    token_info
}

# Parse the callback URL to extract code and state
parse_callback <- function(query_string) {
    if (is.null(query_string) || query_string == "") {
        return(list(code = NULL, state = NULL, error = NULL))
    }

    params <- strsplit(query_string, "&")[[1]]
    parsed <- list()

    for (param in params) {
        parts <- strsplit(param, "=")[[1]]
        if (length(parts) == 2) {
            parsed[[parts[1]]] <- URLdecode(parts[2])
        }
    }

    list(
        code = parsed$code,
        state = parsed$state,
        error = parsed$error
    )
}
