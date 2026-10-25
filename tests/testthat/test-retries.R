# These talk to a real local HTTP server (see start_flaky_server in helper-setup.R)

test_that("transient errors are retried until it works", {
    srv <- start_flaky_server(c(503, 429, 200))
    withr::defer(srv$proc$kill())

    res <- spotify_get("/x", "token", base_url = srv$url, backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(res$data$attempt, 3)
    expect_equal(srv$count(), 3)
})

test_that("it gives up after max_tries and reports the last status", {
    srv <- start_flaky_server(503)
    withr::defer(srv$proc$kill())

    res <- spotify_get("/x", "token", base_url = srv$url, backoff = no_wait)
    expect_equal(res$state, "error")
    expect_equal(res$http_status, 503L)
    expect_equal(srv$count(), 3)
})

test_that("a rate limit that does not clear is reported as rate_limited", {
    srv <- start_flaky_server(429)
    withr::defer(srv$proc$kill())

    res <- spotify_get("/x", "token", base_url = srv$url, backoff = no_wait)
    expect_equal(res$state, "rate_limited")
    expect_equal(res$message, spotify_messages$rate_limited)
    expect_equal(srv$count(), 3)
})

test_that("client errors are not retried", {
    for (code in c(400L, 401L, 403L, 404L)) {
        srv <- start_flaky_server(code)
        res <- spotify_get("/x", "token", base_url = srv$url, backoff = no_wait)
        expect_equal(srv$count(), 1, info = code)
        srv$proc$kill()
    }
})

test_that("Retry-After is used as the wait (0 seconds here), not just the backoff", {
    srv <- start_flaky_server(c(429, 200), headers = list(`Retry-After` = "0"))
    withr::defer(srv$proc$kill())

    # a backoff that would fail the test if it were used
    res <- spotify_get("/x", "token", base_url = srv$url, backoff = function(i) 60)
    expect_equal(res$state, "ok")
    expect_equal(srv$count(), 2)
})

test_that("a creation that fails with 403 on both endpoints reports forbidden", {
    srv <- start_flaky_server(403)
    withr::defer(srv$proc$kill())

    res <- spotify_create_playlist("tok", "u1", "Mine", "desc", base_url = srv$url, backoff = no_wait)
    expect_equal(res$state, "forbidden")
    expect_equal(srv$count(), 2)  # the user-scoped endpoint, then /me/playlists
})

test_that("a server that is not there gives state error and never throws", {
    res <- expect_no_error(spotify_get("/x", "token", base_url = "http://127.0.0.1:1", backoff = no_wait))
    expect_equal(res$state, "error")
    expect_true(is.na(res$http_status))
})

# ---- the same rules without blocking the R session (spotify_call_async) ----

# Wait for a promise on the event loop, without ever blocking it for long
await <- function(promise, seconds = 15) {
    state <- new.env(); state$done <- FALSE; state$value <- NULL; state$error <- NULL
    promises::then(promise, function(v) { state$value <- v; state$done <- TRUE },
                   function(e) { state$error <- e; state$done <- TRUE })
    deadline <- Sys.time() + seconds
    while (!state$done && Sys.time() < deadline) later::run_now(0.02)
    if (!is.null(state$error)) stop("the promise was rejected: ", conditionMessage(state$error))
    state$value
}

test_that("async: transient errors are retried until it works", {
    srv <- start_flaky_server(c(503, 429, 200))
    withr::defer(srv$proc$kill())
    res <- await(spotify_get_async("/x", "token", base_url = srv$url, backoff = no_wait))
    expect_equal(res$state, "ok")
    expect_equal(res$data$attempt, 3)
    expect_equal(srv$count(), 3)
})

test_that("async: it gives up after max_tries and resolves (never rejects)", {
    srv <- start_flaky_server(503)
    withr::defer(srv$proc$kill())
    res <- await(spotify_get_async("/x", "token", base_url = srv$url, backoff = no_wait))
    expect_equal(res$state, "error")
    expect_equal(res$http_status, 503L)
    expect_equal(srv$count(), 3)
})

test_that("async: client errors are not retried, and map to the same states", {
    for (case in list(c(401, "reauth"), c(403, "forbidden"), c(404, "error"))) {
        srv <- start_flaky_server(as.integer(case[1]))
        res <- await(spotify_get_async("/x", "token", base_url = srv$url, backoff = no_wait))
        expect_equal(res$state, case[2], info = case[1])
        expect_equal(srv$count(), 1, info = case[1])
        srv$proc$kill()
    }
})

test_that("async: Retry-After is the wait, capped, and the backoff is not used then", {
    srv <- start_flaky_server(c(429, 200), headers = list(`Retry-After` = "0"))
    withr::defer(srv$proc$kill())
    res <- await(spotify_get_async("/x", "token", base_url = srv$url, backoff = function(i) 60), seconds = 8)
    expect_equal(res$state, "ok")
})

test_that("async: a server that is not there gives state error", {
    res <- await(spotify_get_async("/x", "token", base_url = "http://127.0.0.1:1", backoff = no_wait))
    expect_equal(res$state, "error")
    expect_true(is.na(res$http_status))
})

test_that("async: the session stays free while a request is in flight", {
    srv <- start_flaky_server(200, delay = 0.4)
    withr::defer(srv$proc$kill())
    ticks <- 0L; running <- TRUE
    tick <- function() { ticks <<- ticks + 1L; if (running) later::later(tick, 0.05) }
    tick()
    res <- await(spotify_get_async("/x", "token", base_url = srv$url))
    running <- FALSE
    expect_equal(res$state, "ok")
    expect_gt(ticks, 4L)      # blocked for 0.4 s, it would have been 1
})
