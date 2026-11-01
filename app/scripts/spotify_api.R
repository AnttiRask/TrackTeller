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

    spotify_logged_result(resp, method, path)
}

# The result list for a response (or an error), with a line in the log when it isn't ok
spotify_logged_result <- function(resp, method, path) {
    result <- spotify_result(resp)

    if (result$state != "ok") {
        message("[spotify] ", method, " ", path, " -> ",
                if (is.na(result$http_status)) "no response" else result$http_status,
                " (", result$state, ")",
                if (inherits(resp, "error")) paste0(": ", conditionMessage(resp)) else "")
    }
    result
}

# The same call, without blocking the R session: returns a promise of the result list. For
# long jobs (a few hundred requests in a row): a blocked session can't answer the browser
# (clicks, redraws) until the request is done. Always resolves, never rejects.
#
# httr2's req_perform_promise() doesn't retry (checked with httr2 1.3.0: a 503 is given up
# at once), so the retries are done here, with the same rules as spotify_call(): up to
# max_tries, only for 429/5xx and network failures, Retry-After honoured but capped.
spotify_call_async <- function(path, token, method = "GET", query = list(), body = NULL,
                               base_url = SPOTIFY_API_URL, timeout = 10, max_tries = 3,
                               backoff = NULL) {
    req <- tryCatch({
        req <- request(paste0(base_url, path)) |>
            req_method(method) |>
            req_auth_bearer_token(token) |>
            req_user_agent(SPOTIFY_USER_AGENT) |>
            req_timeout(timeout)
        if (length(query) > 0) req <- req_url_query(req, !!!query)
        if (!is.null(body)) req <- req_body_json(req, body, auto_unbox = TRUE)
        req
    }, error = function(e) e)

    if (inherits(req, "error")) {
        return(promises::promise_resolve(spotify_logged_result(req, method, path)))
    }

    wait_before_retry <- function(resp, attempt) {
        after <- if (is.null(resp)) NA_real_ else spotify_retry_after(resp)
        if (!is.na(after)) return(after)
        if (is.null(backoff)) min(2^attempt, 10) else backoff(attempt)
    }

    attempt <- function(n) {
        promises::then(
            req_perform_promise(req),
            onFulfilled = function(resp) spotify_logged_result(resp, method, path),
            onRejected = function(e) {
                resp <- if (inherits(e, "httr2_http")) e$resp else NULL
                transient <- is.null(resp) || resp_status(resp) %in% c(429L, 500L, 502L, 503L, 504L)

                if (transient && n < max_tries) {
                    delay <- wait_before_retry(resp, n)
                    pause <- promises::promise(function(resolve, reject) {
                        later::later(function() resolve(NULL), delay)
                    })
                    return(promises::then(pause, onFulfilled = function(ignored) attempt(n + 1L)))
                }
                spotify_logged_result(if (is.null(resp)) e else resp, method, path)
            }
        )
    }

    attempt(1L)
}

spotify_get <- function(path, token, query = list(), ...) {
    spotify_call(path, token, method = "GET", query = query, ...)
}

spotify_get_async <- function(path, token, query = list(), ...) {
    spotify_call_async(path, token, method = "GET", query = query, ...)
}

spotify_post <- function(path, token, body = NULL, ...) {
    spotify_call(path, token, method = "POST", body = body, ...)
}

# ---------------------------------------------------------------------------
# Parsers: Spotify JSON (as nested lists) -> tibbles. They never fail on a field
# that is missing, because Spotify has been removing fields (popularity and
# followers are optional here). Each returns NULL when there is nothing to show.
# ---------------------------------------------------------------------------

# Addresses that come from Spotify end up in `href` and `src` of the page and in what the
# server fetches for the share cards. Only https addresses on Spotify's own hosts are let
# through; anything else becomes NA (a card without a link, a picture that is a placeholder).
# The same hosts the page's Content-Security-Policy allows (csp.R).

# The host of an https address, lower case, or NA. Userinfo ("https://open.spotify.com@evil.example/")
# and anything but letters, digits, dots and hyphens in the host make it NA.
https_host <- function(x) {
    x <- as.character(x)
    if (length(x) == 0) return(character(0))
    ok <- !is.na(x) & grepl("^https://[A-Za-z0-9.-]+(:[0-9]+)?([/?#]|$)", x)
    ifelse(ok, tolower(sub("^https://([A-Za-z0-9.-]+).*$", "\\1", x)), NA_character_)
}

# A link to something on Spotify (open.spotify.com), or NA
spotify_link <- function(x) {
    x <- as.character(x)
    ifelse(!is.na(https_host(x)) & https_host(x) == "open.spotify.com", x, NA_character_)
}

# A picture on Spotify's image hosts (*.scdn.co, *.spotifycdn.com), or NA
spotify_image <- function(x) {
    x <- as.character(x)
    host <- https_host(x)
    ifelse(!is.na(host) & (endsWith(host, ".scdn.co") | endsWith(host, ".spotifycdn.com")), x, NA_character_)
}

# First image url of an object that has an `images` list, or NA
first_image_url <- function(images) {
    url <- if (length(images) > 0 && !is.null(images[[1]]$url)) images[[1]]$url else NA_character_
    spotify_image(url)
}

# Artist names of a track, comma separated
artist_names <- function(artists) {
    paste(vapply(artists, function(a) a$name %||% "", character(1)), collapse = ", ")
}

# One column of a result: `get(item)` for each item, or `default` where it is missing.
# The parsers build a whole page with ONE tibble() call from such columns: a tibble()
# per row looked cheap in a script (30 ms for 50 rows) but took 230 ms per page inside
# Shiny's deep call stacks (most of it in tibble()'s name handling), which blocked the
# session for seconds when 85 pages of playlists were parsed one after another.
column <- function(items, get, default, type) {
    vapply(items, function(item) {
        value <- get(item)
        if (is.null(value) || length(value) != 1) default else value
    }, type, USE.NAMES = FALSE)
}

parse_top_artists <- function(data) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    tibble::tibble(
        rank        = seq_along(items),
        id          = column(items, \(a) a$id, NA_character_, character(1)),
        name        = column(items, \(a) a$name, "(Unknown)", character(1)),
        popularity  = column(items, \(a) as.integer(a$popularity), NA_integer_, integer(1)),
        followers   = column(items, \(a) as.numeric(a$followers$total), NA_real_, numeric(1)),
        genres      = vapply(items, \(a) paste(unlist(a$genres), collapse = ", "), character(1), USE.NAMES = FALSE),
        image_url   = vapply(items, \(a) first_image_url(a$images), character(1), USE.NAMES = FALSE),
        spotify_url = spotify_link(column(items, \(a) a$external_urls$spotify, NA_character_, character(1)))
    )
}

parse_top_tracks <- function(data) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    tibble::tibble(
        rank            = seq_along(items),
        id              = column(items, \(t) t$id, NA_character_, character(1)),
        name            = column(items, \(t) t$name, "(Unknown)", character(1)),
        artist          = vapply(items, \(t) artist_names(t$artists), character(1), USE.NAMES = FALSE),
        album           = column(items, \(t) t$album$name, "", character(1)),
        popularity      = column(items, \(t) as.integer(t$popularity), NA_integer_, integer(1)),
        duration_ms     = column(items, \(t) as.numeric(t$duration_ms), NA_real_, numeric(1)),
        album_image_url = vapply(items, \(t) first_image_url(t$album$images), character(1), USE.NAMES = FALSE),
        spotify_url     = spotify_link(column(items, \(t) t$external_urls$spotify, NA_character_, character(1)))
    )
}

# Recently played: the same track can appear many times, keep the first
# (most recent) one of each and return at most `count`
parse_recent_tracks <- function(data, count = 20) {
    items <- data$items
    if (length(items) == 0) return(NULL)

    tracks <- tibble::tibble(
        id          = column(items, \(i) i$track$id, NA_character_, character(1)),
        name        = column(items, \(i) i$track$name, "(Unknown)", character(1)),
        artist      = vapply(items, \(i) artist_names(i$track$artists), character(1), USE.NAMES = FALSE),
        album       = column(items, \(i) i$track$album$name, "", character(1)),
        spotify_url = spotify_link(column(items, \(i) i$track$external_urls$spotify, NA_character_, character(1)))
    )

    head(dplyr::distinct(tracks, id, .keep_all = TRUE), count)
}

# One page of /me/playlists. The track count moved from `tracks` to `items` in
# Spotify's API (both exist for now), so read whichever is there.
parse_playlists_page <- function(items) {
    # Spotify sends null in place of a playlist it can't show
    items <- Filter(Negate(is.null), items)
    if (length(items) == 0) return(NULL)

    tibble::tibble(
        id          = column(items, \(p) p$id, NA_character_, character(1)),
        name        = column(items, \(p) p$name, "(Untitled)", character(1)),
        description = column(items, \(p) p$description, "", character(1)),
        track_count = column(items, \(p) as.integer(p$items$total %||% p$tracks$total), 0L, integer(1)),
        owner       = column(items, \(p) p$owner$display_name, "Unknown", character(1)),
        is_public   = vapply(items, \(p) isTRUE(p$public %||% TRUE), logical(1), USE.NAMES = FALSE),
        image_url   = vapply(items, \(p) first_image_url(p$images), character(1), USE.NAMES = FALSE),
        spotify_url = spotify_link(column(items, \(p) p$external_urls$spotify, NA_character_, character(1)))
    )
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

# Playlists are created public. Spotify's API can't make a private one for an app like
# ours: a playlist created with public = false reads back as public, and changing it
# afterwards (PUT public = false) returns 200 but changes nothing (probed 2026-10-25, both
# endpoints). So we ask for what we will get, and the dialogs tell the user.
spotify_create_playlist <- function(token, user_id, name, description, public = TRUE, ...) {
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
