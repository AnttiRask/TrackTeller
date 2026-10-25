# Load the app's own code (no server, no UI) so the functions can be tested
# directly. Runs from tests/testthat, whatever directory the tests start in.
app_dir <- normalizePath(file.path("..", "..", "app"))

library(dplyr)
library(httr2)
library(purrr)
library(tibble)

source(file.path(app_dir, "scripts", "spotify_api.R"))
source(file.path(app_dir, "scripts", "spotify_oauth.R"))

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
start_flaky_server <- function(codes, headers = list()) {
    skip_if_not_installed("callr")
    skip_if_not_installed("httpuv")

    port <- httpuv::randomPort()
    proc <- callr::r_bg(function(port, codes, headers) {
        n <- 0L
        app <- list(call = function(req) {
            if (req$PATH_INFO == "/count") {
                return(list(status = 200L, headers = list("Content-Type" = "application/json"),
                            body = sprintf('{"count": %d}', n)))
            }
            n <<- n + 1L
            list(status = codes[min(n, length(codes))],
                 headers = c(list("Content-Type" = "application/json"), headers),
                 body = sprintf('{"attempt": %d}', n))
        })
        httpuv::runServer("127.0.0.1", port, app)
    }, args = list(port = port, codes = as.integer(codes), headers = headers), supervise = TRUE)

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
