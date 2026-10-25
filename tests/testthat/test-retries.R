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
