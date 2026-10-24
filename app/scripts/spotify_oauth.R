# Spotify OAuth 2.0 Authorization Code Flow
# Custom implementation for web deployment

library(httr2)

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

# POST to Spotify's token endpoint. Returns list(state, token, message), never throws:
#   state "ok"     token is list(access_token, token_type, expires_in, refresh_token,
#                  scope, expires_at)
#         "reauth" Spotify rejected the code or refresh token (expired, used twice,
#                  or revoked): the user has to log in again
#         "error"  network failure, timeout or an unexpected answer
# message is a plain sentence for the user; Spotify's response body is never
# passed on (the log gets the status code only).
spotify_token_request <- function(params, previous_refresh_token = NULL,
                                  token_url = SPOTIFY_TOKEN_URL, timeout = 10,
                                  max_tries = 3, backoff = NULL) {
    resp <- tryCatch(
        request(token_url) |>
            req_user_agent("TrackTeller (https://trackteller.youcanbeapirate.com)") |>
            req_body_form(!!!params) |>
            req_timeout(timeout) |>
            req_retry(
                max_tries        = max_tries,
                retry_on_failure = TRUE,
                is_transient     = \(r) resp_status(r) %in% c(429L, 500L, 502L, 503L, 504L),
                backoff          = backoff
            ) |>
            req_perform(),
        httr2_http = function(e) e$resp,
        error = function(e) e
    )

    if (inherits(resp, "error")) {
        message("[spotify] token request -> no response")
        return(list(state = "error", token = NULL,
                    message = "Couldn't reach Spotify. Please try again."))
    }

    status <- resp_status(resp)
    if (status != 200) {
        message("[spotify] token request -> ", status)
        if (status %in% c(400L, 401L)) {
            return(list(state = "reauth", token = NULL,
                        message = "Spotify didn't accept this login. Please try logging in again."))
        }
        return(list(state = "error", token = NULL,
                    message = "Couldn't reach Spotify. Please try again."))
    }

    data <- tryCatch(resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(data$access_token) || is.null(data$expires_in)) {
        message("[spotify] token request -> 200 without an access token")
        return(list(state = "error", token = NULL,
                    message = "Couldn't reach Spotify. Please try again."))
    }

    list(
        state = "ok",
        token = list(
            access_token  = data$access_token,
            token_type    = data$token_type,
            expires_in    = data$expires_in,
            # Spotify may leave the refresh token out of a refresh: keep the old one
            refresh_token = data$refresh_token %||% previous_refresh_token,
            scope         = data$scope,
            expires_at    = Sys.time() + data$expires_in
        ),
        message = NULL
    )
}

# Exchange authorization code for access token
spotify_exchange_code <- function(code, client_id, client_secret, redirect_uri, ...) {
    spotify_token_request(
        list(
            grant_type    = "authorization_code",
            code          = code,
            redirect_uri  = redirect_uri,
            client_id     = client_id,
            client_secret = client_secret
        ),
        ...
    )
}

# Refresh an expired access token
spotify_refresh_token <- function(refresh_token, client_id, client_secret, ...) {
    spotify_token_request(
        list(
            grant_type    = "refresh_token",
            refresh_token = refresh_token,
            client_id     = client_id,
            client_secret = client_secret
        ),
        previous_refresh_token = refresh_token,
        ...
    )
}

# Check if token is expired (with 5 minute buffer)
token_is_expired <- function(token_info) {
    if (is.null(token_info) || is.null(token_info$expires_at)) {
        return(TRUE)
    }
    Sys.time() >= (token_info$expires_at - 300)
}
