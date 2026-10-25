# Spotify Web API layer
#
# Every call returns list(state, data, http_status, message) and never throws:
#   state "ok"           2xx; data is the parsed JSON (NULL for an empty body)
#         "reauth"       401: the token is no longer valid
#         "forbidden"    403: Spotify refuses this endpoint or account
#         "rate_limited" 429 that was still there after the retries
#         "error"        anything else, including a network failure or a timeout
# message is a plain sentence that is safe to show to the user; it never holds
# response bodies, tokens or other internals. Details go to the log (status code
# and path only).

library(httr2)

SPOTIFY_API_URL <- "https://api.spotify.com/v1"
SPOTIFY_USER_AGENT <- "TrackTeller (https://trackteller.youcanbeapirate.com)"

spotify_messages <- list(
    reauth       = "Your Spotify session has expired. Please log in again.",
    forbidden    = "Spotify didn't allow this request. It may not be available for your account.",
    rate_limited = "Spotify is busy right now. Please try again in a moment.",
    error        = "Couldn't get this from Spotify. Please try again."
)

# Seconds to wait before a retry: Spotify's Retry-After header, but never more
# than max_wait so that a session doesn't sit still for minutes. NA means "use
# the normal backoff".
spotify_retry_after <- function(resp, max_wait = 10) {
    wait <- suppressWarnings(as.numeric(resp_header(resp, "Retry-After")))
    if (length(wait) != 1 || is.na(wait)) return(NA_real_)
    min(wait, max_wait)
}

# Turn a response (or the error from a failed attempt) into the result list
spotify_result <- function(resp) {
    if (inherits(resp, "error")) {
        return(list(state = "error", data = NULL, http_status = NA_integer_,
                    message = spotify_messages$error))
    }

    status <- resp_status(resp)

    if (status >= 200 && status < 300) {
        data <- tryCatch(resp_body_json(resp, simplifyVector = FALSE),
                         error = function(e) NULL)
        return(list(state = "ok", data = data, http_status = status, message = NULL))
    }

    state <- switch(as.character(status),
        "401" = "reauth",
        "403" = "forbidden",
        "429" = "rate_limited",
        "error"
    )
    list(state = state, data = NULL, http_status = status,
         message = spotify_messages[[state]])
}

# One request to the Spotify API. `query` is a named list; `body` (for POST/PUT)
# a list that is sent as JSON. `backoff` is only changed by the tests.
spotify_call <- function(path, token, method = "GET", query = list(), body = NULL,
                         base_url = SPOTIFY_API_URL, timeout = 10, max_tries = 3,
                         backoff = NULL) {
    # Building the request is inside the tryCatch too: whatever goes wrong becomes
    # state "error" (details in the log), never an exception in the session
    resp <- tryCatch({
        req <- request(paste0(base_url, path)) |>
            req_method(method) |>
            req_auth_bearer_token(token) |>
            req_user_agent(SPOTIFY_USER_AGENT) |>
            req_timeout(timeout) |>
            req_retry(
                max_tries        = max_tries,
                retry_on_failure = TRUE,
                is_transient     = \(resp) resp_status(resp) %in% c(429L, 500L, 502L, 503L, 504L),
                after            = \(resp) spotify_retry_after(resp),
                backoff          = backoff
            )

        if (length(query) > 0) req <- req_url_query(req, !!!query)
        if (!is.null(body)) req <- req_body_json(req, body, auto_unbox = TRUE)

        req_perform(req)
    },
    # An HTTP error status: httr2 retries these (see req_retry) and raises the last
    # one. Its response is what we report.
    httr2_http = function(e) e$resp,
    error = function(e) e)

    result <- spotify_result(resp)

    if (result$state != "ok") {
        message("[spotify] ", method, " ", path, " -> ",
                if (is.na(result$http_status)) "no response" else result$http_status,
                " (", result$state, ")",
                if (inherits(resp, "error")) paste0(": ", conditionMessage(resp)) else "")
    }
    result
}

spotify_get <- function(path, token, query = list(), ...) {
    spotify_call(path, token, method = "GET", query = query, ...)
}

spotify_post <- function(path, token, body = NULL, ...) {
    spotify_call(path, token, method = "POST", body = body, ...)
}

# ---------------------------------------------------------------------------
# Parsers: Spotify JSON (as nested lists) -> tibbles. They never fail on a field
# that is missing, because Spotify has been removing fields (popularity and
# followers are optional here). Each returns NULL when there is nothing to show.
# ---------------------------------------------------------------------------

# First image url of an object that has an `images` list, or NA
first_image_url <- function(images) {
    if (length(images) > 0 && !is.null(images[[1]]$url)) images[[1]]$url else NA_character_
}

# Artist names of a track, comma separated
artist_names <- function(artists) {
    paste(vapply(artists, function(a) a$name %||% "", character(1)), collapse = ", ")
}

parse_top_artists <- function(data) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    dplyr::bind_rows(lapply(seq_along(items), function(i) {
        artist <- items[[i]]
        tibble::tibble(
            rank        = i,
            id          = artist$id %||% NA_character_,
            name        = artist$name %||% "(Unknown)",
            popularity  = as.integer(artist$popularity %||% NA_integer_),
            followers   = as.numeric(artist$followers$total %||% NA_real_),
            genres      = paste(unlist(artist$genres), collapse = ", "),
            image_url   = first_image_url(artist$images),
            spotify_url = artist$external_urls$spotify %||% NA_character_
        )
    }))
}

parse_top_tracks <- function(data) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    dplyr::bind_rows(lapply(seq_along(items), function(i) {
        track <- items[[i]]
        tibble::tibble(
            rank            = i,
            id              = track$id %||% NA_character_,
            name            = track$name %||% "(Unknown)",
            artist          = artist_names(track$artists),
            album           = track$album$name %||% "",
            popularity      = as.integer(track$popularity %||% NA_integer_),
            duration_ms     = as.numeric(track$duration_ms %||% NA_real_),
            album_image_url = first_image_url(track$album$images),
            spotify_url     = track$external_urls$spotify %||% NA_character_
        )
    }))
}

# Recently played: the same track can appear many times, keep the first
# (most recent) one of each and return at most `count`
parse_recent_tracks <- function(data, count = 20) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    tracks <- dplyr::bind_rows(lapply(items, function(item) {
        t <- item$track
        tibble::tibble(
            id          = t$id %||% NA_character_,
            name        = t$name %||% "(Unknown)",
            artist      = artist_names(t$artists),
            album       = t$album$name %||% "",
            spotify_url = t$external_urls$spotify %||% NA_character_
        )
    }))

    head(dplyr::distinct(tracks, id, .keep_all = TRUE), count)
}

# One page of /me/playlists. The track count moved from `tracks` to `items` in
# Spotify's API (both exist for now), so read whichever is there.
parse_playlists_page <- function(items) {
    if (length(items) == 0) return(NULL)

    dplyr::bind_rows(lapply(items, function(playlist) {
        tibble::tibble(
            id          = playlist$id %||% NA_character_,
            name        = playlist$name %||% "(Untitled)",
            description = playlist$description %||% "",
            track_count = as.integer(playlist$items$total %||% playlist$tracks$total %||% 0L),
            owner       = playlist$owner$display_name %||% "Unknown",
            is_public   = isTRUE(playlist$public %||% TRUE),
            image_url   = first_image_url(playlist$images),
            spotify_url = playlist$external_urls$spotify %||% NA_character_
        )
    }))
}

# Genres across the user's top artists: one row per genre with how many artists
# have it, which artists (up to five named), and its share of all genre mentions
summarise_genres <- function(data) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    pairs <- dplyr::bind_rows(lapply(items, function(artist) {
        genres <- unlist(artist$genres)
        if (length(genres) == 0) return(NULL)
        tibble::tibble(genre = genres, artist_name = artist$name %||% "(Unknown)")
    }))
    if (nrow(pairs) == 0) return(NULL)

    pairs |>
        dplyr::group_by(genre) |>
        dplyr::summarise(count = dplyr::n(), all_artists = list(artist_name), .groups = "drop") |>
        dplyr::arrange(dplyr::desc(count), genre) |>
        dplyr::mutate(
            percentage    = round(count / sum(count) * 100, 1),
            genre_display = to_title_case(genre),
            artist_names  = purrr::map_chr(all_artists, function(nm) {
                if (length(nm) <= 5) paste(nm, collapse = ", ")
                else paste0(paste(nm[1:5], collapse = ", "), "...")
            })
        )
}

# Id and name of the first track in an artist's top-tracks response, or NULL
parse_first_track <- function(data) {
    if (length(data$tracks) == 0) return(NULL)
    t <- data$tracks[[1]]
    if (is.null(t$id)) return(NULL)
    tibble::tibble(id = t$id, name = t$name %||% "(Unknown)", artist = artist_names(t$artists))
}

# "3:07" for 187000 ms; "" when the duration is missing
format_duration <- function(ms) {
    if (length(ms) != 1 || is.na(ms)) return("")
    secs <- round(ms / 1000)
    sprintf("%d:%02d", secs %/% 60, secs %% 60)
}

# Words with a capital first letter, for genre names
to_title_case <- function(x) {
    vapply(x, function(s) {
        words <- strsplit(s, " ")[[1]]
        paste(toupper(substring(words, 1, 1)), substring(words, 2), sep = "", collapse = " ")
    }, character(1), USE.NAMES = FALSE)
}

# ---------------------------------------------------------------------------
# Writing: playlists. Spotify is replacing the user-scoped and /tracks endpoints
# (February 2026 changes for development-mode apps). Both still work in October
# 2026, so try the current one first and fall back to the newer one on 403/404.
# ---------------------------------------------------------------------------

spotify_create_playlist <- function(token, user_id, name, description, public = FALSE, ...) {
    body <- list(name = name, description = description, public = public)
    res <- spotify_post(paste0("/users/", user_id, "/playlists"), token, body = body, ...)
    if (res$http_status %in% c(403L, 404L)) {
        res <- spotify_post("/me/playlists", token, body = body, ...)
    }
    res
}

spotify_add_tracks <- function(token, playlist_id, track_ids, ...) {
    uris <- as.list(paste0("spotify:track:", track_ids))
    res <- spotify_post(paste0("/playlists/", playlist_id, "/tracks"), token,
                        body = list(uris = uris), ...)
    if (res$http_status %in% c(403L, 404L)) {
        res <- spotify_post(paste0("/playlists/", playlist_id, "/items"), token,
                            body = list(uris = uris), ...)
    }
    res
}
