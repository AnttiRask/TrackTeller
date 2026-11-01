# Load the app's own code (no server, no UI) so the functions can be tested
# directly. Runs from tests/testthat, whatever directory the tests start in.
app_dir <- normalizePath(file.path("..", "..", "app"))

library(dplyr)
library(httr2)
library(purrr)
library(tibble)

source(file.path(app_dir, "scripts", "spotify_api.R"))
source(file.path(app_dir, "scripts", "spotify_oauth.R"))

# The whole app (packages, scripts and the parts of the server), as it is loaded when it
# starts, for the tests of the server and of the pieces of the page. It reads its files
# relative to the app folder.
withr::with_dir(app_dir, source("setup.R"))
source(file.path(app_dir, "server.R"))
assign("SPOTIFY_CLIENT_ID", "test-client", envir = globalenv())
assign("SPOTIFY_CLIENT_SECRET", "test-secret", envir = globalenv())

# No waiting between retries in the tests
no_wait <- function(i) 0

# A mock that answers with `responses` in order and counts the requests made
mock_sequence <- function(responses) {
    env <- new.env()
    env$calls <- list()
    env$mock <- function(req) {
        env$calls[[length(env$calls) + 1]] <- req
        responses[[min(length(env$calls), length(responses))]]
    }
    env
}

# The paths (without host and query) of the requests a mock received
requested_paths <- function(env) {
    vapply(env$calls, function(r) sub("\\?.*$", "", sub("^https://[^/]+/v1", "", r$url)), character(1))
}

# A real HTTP server on a free local port, run in a background R process, that
# answers each request with the next status in `codes` (the last one repeats).
# httr2's mocks skip its retry loop, so retries have to be tested against a real
# server. Paths: /count answers with how many requests the server has handled
# (without counting itself); anything else counts and answers with the next code.
# `headers` (a named list) is added to every counted answer.
# Returns list(url, proc, count()); stop it with proc$kill().
start_flaky_server <- function(codes, headers = list(), delay = 0) {
    skip_if_not_installed("callr")
    skip_if_not_installed("httpuv")

    port <- httpuv::randomPort()
    proc <- callr::r_bg(function(port, codes, headers, delay) {
        n <- 0L
        app <- list(call = function(req) {
            if (req$PATH_INFO == "/count") {
                return(list(status = 200L, headers = list("Content-Type" = "application/json"),
                            body = sprintf('{"count": %d}', n)))
            }
            n <<- n + 1L
            if (delay > 0) Sys.sleep(delay)
            list(status = codes[min(n, length(codes))],
                 headers = c(list("Content-Type" = "application/json"), headers),
                 body = sprintf('{"attempt": %d}', n))
        })
        httpuv::runServer("127.0.0.1", port, app)
    }, args = list(port = port, codes = as.integer(codes), headers = headers, delay = delay), supervise = TRUE)

    url <- paste0("http://127.0.0.1:", port)
    for (i in 1:50) {
        up <- tryCatch({ req_perform(request(paste0(url, "/count"))); TRUE }, error = function(e) FALSE)
        if (up) break
        Sys.sleep(0.1)
    }
    if (!up) { proc$kill(); skip("the local test server did not start") }

    list(
        url = url, proc = proc,
        count = function() resp_body_json(req_perform(request(paste0(url, "/count"))))$count
    )
}

# A Spotify that answers by method and path, for the tests of the server. `...` are
# "GET /me" = <response, or function(req) returning one>; the last answer of a route
# repeats, and a list of responses is used one after the other. A request nobody listed
# is recorded in $unexpected (and answered with an error), so a test can insist that
# nothing else was asked. $requests keeps every request that was made.
spotify_router <- function(...) {
    # In the tests every output is computed, so every tab asks Spotify; they get an empty
    # answer unless the test says otherwise
    nothing <- httr2::response_json(200L, body = list(items = list()))
    routes <- modifyList(list(
        "GET /me/top/artists" = nothing, "GET /me/top/tracks" = nothing,
        "GET /me/player/recently-played" = nothing
    ), list(...))
    env <- new.env()
    env$requests <- list()
    env$unexpected <- character(0)
    env$used <- list()
    env$keys <- function() vapply(env$requests, \(r) r$key, character(1))
    env$mock <- function(req) {
        path <- sub("\\?.*$", "", sub("^https://[^/]+(/v1)?", "", req$url))
        key <- paste(httr2::req_get_method(req), path)
        env$requests[[length(env$requests) + 1]] <- list(key = key, req = req)

        route <- routes[[key]]
        if (is.null(route)) {
            env$unexpected <- c(env$unexpected, key)
            return(httr2::response_json(500L, body = list(error = "unexpected request")))
        }
        if (is.function(route)) return(route(req))
        if (inherits(route, "httr2_response")) return(route)
        n <- (env$used[[key]] %||% 0L) + 1L
        env$used[[key]] <- n
        route[[min(n, length(route))]]
    }
    env
}

fresh_token <- function(access_token = "tok", expires_in = 3600) {
    list(access_token = access_token, token_type = "Bearer", refresh_token = "ref",
         expires_at = Sys.time() + expires_in)
}

# A local server for the share card's pictures. Paths: /ok.jpg and /ok.png (real images),
# /slow.jpg (a real image after `slow` seconds), /redirect.jpg (302 to /ok.jpg), /page.jpg
# (HTML, claiming to be a picture), /big.jpg (a real image padded past 100 kB), /missing.jpg
# (404). /hits says how often each path was asked for. Returns list(url, proc, hits()).
start_image_server <- function(slow = 3) {
    skip_if_not_installed("callr")
    skip_if_not_installed("httpuv")
    skip_if_not_installed("magick")

    img <- magick::image_blank(40, 40, color = "#1DB954")
    jpeg <- magick::image_write(img, format = "jpeg")
    png <- magick::image_write(img, format = "png")
    big <- c(jpeg, as.raw(rep(0, 150000)))

    port <- httpuv::randomPort()
    proc <- callr::r_bg(function(port, jpeg, png, big, slow) {
        hits <- list()
        app <- list(call = function(req) {
            path <- req$PATH_INFO
            if (path == "/hits") {
                return(list(status = 200L, headers = list("Content-Type" = "application/json"),
                            body = if (length(hits) == 0) "{}" else paste0("{", paste0('"', names(hits), '": ', unlist(hits), collapse = ", "), "}")))
            }
            hits[[path]] <<- (hits[[path]] %||% 0L) + 1L
            image <- function(bytes, type = "image/jpeg") list(status = 200L, headers = list("Content-Type" = type), body = bytes)
            switch(path,
                "/ok.jpg" = image(jpeg),
                "/ok.png" = image(png, "image/png"),
                # a late answer that doesn't hold the server up (a real CDN serves many at once)
                "/slow.jpg" = promises::promise(function(resolve, reject) {
                    later::later(function() resolve(image(jpeg)), slow)
                }),
                "/redirect.jpg" = list(status = 302L, headers = list(Location = "/ok.jpg"), body = ""),
                "/page.jpg" = list(status = 200L, headers = list("Content-Type" = "text/html"), body = "<html>not a picture</html>"),
                "/big.jpg" = image(big),
                list(status = 404L, headers = list("Content-Type" = "text/plain"), body = "no")
            )
        })
        `%||%` <- function(a, b) if (is.null(a)) b else a
        httpuv::runServer("127.0.0.1", port, app)
    }, args = list(port = port, jpeg = jpeg, png = png, big = big, slow = slow), supervise = TRUE)

    url <- paste0("http://127.0.0.1:", port)
    up <- FALSE
    for (i in 1:50) {
        up <- tryCatch({ req_perform(request(paste0(url, "/hits"))); TRUE }, error = function(e) FALSE)
        if (up) break
        Sys.sleep(0.1)
    }
    if (!up) { proc$kill(); skip("the local image server did not start") }

    list(url = url, proc = proc, hits = function() {
        h <- resp_body_json(req_perform(request(paste0(url, "/hits"))))
        unlist(h)
    })
}
