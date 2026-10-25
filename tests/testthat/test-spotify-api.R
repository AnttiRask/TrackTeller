json_ok <- function(body = list(ok = TRUE), status = 200L) response_json(status, body = body)

test_that("a 2xx answer gives state ok and the parsed data", {
    local_mocked_responses(list(json_ok(list(display_name = "Pat"))))
    res <- spotify_get("/me", "token")
    expect_equal(res$state, "ok")
    expect_equal(res$data$display_name, "Pat")
    expect_equal(res$http_status, 200L)
    expect_null(res$message)
})

test_that("an empty 2xx body is ok with NULL data", {
    local_mocked_responses(list(response(status_code = 204)))
    res <- spotify_get("/me", "token")
    expect_equal(res$state, "ok")
    expect_null(res$data)
})

test_that("error statuses map to states with plain messages", {
    cases <- list(`401` = "reauth", `403` = "forbidden", `404` = "error", `400` = "error")
    for (code in names(cases)) {
        local_mocked_responses(list(json_ok(list(error = "internal detail"), as.integer(code))))
        res <- spotify_get("/me", "token", backoff = no_wait)
        expect_equal(res$state, cases[[code]], info = code)
        expect_equal(res$http_status, as.integer(code))
        expect_null(res$data)
        expect_equal(res$message, spotify_messages[[cases[[code]]]])
    }
})

test_that("messages never contain the response body or the token", {
    local_mocked_responses(list(json_ok(list(error = "secret internal text"), 400L)))
    res <- spotify_get("/me", "my-secret-token")
    expect_false(grepl("secret internal text|my-secret-token", res$message))
})

test_that("a network failure gives state error and never throws", {
    local_mocked_responses(function(req) stop("connection refused"))
    res <- expect_no_error(spotify_get("/me", "token", backoff = no_wait))
    expect_equal(res$state, "error")
    expect_true(is.na(res$http_status))
    expect_equal(res$message, spotify_messages$error)
})

test_that("the request carries the token, the query and the path", {
    mock <- mock_sequence(list(json_ok()))
    local_mocked_responses(mock$mock)
    spotify_get("/me/top/artists", "tok-123", query = list(limit = 50, time_range = "short_term"))
    req <- mock$calls[[1]]
    expect_equal(req$method %||% "GET", "GET")
    expect_match(req$url, "^https://api.spotify.com/v1/me/top/artists\\?")
    expect_match(req$url, "limit=50")
    expect_match(req$url, "time_range=short_term")
    expect_equal(req_get_headers(req, redacted = "reveal")$Authorization, "Bearer tok-123")
})

test_that("Retry-After is honoured but capped", {
    expect_equal(spotify_retry_after(response(headers = list(`Retry-After` = "3"))), 3)
    expect_equal(spotify_retry_after(response(headers = list(`Retry-After` = "120"))), 10)
    expect_true(is.na(spotify_retry_after(response())))
    expect_true(is.na(spotify_retry_after(response(headers = list(`Retry-After` = "soon")))))
})

test_that("creating a playlist uses the current endpoint and falls back on 403/404", {
    mock <- mock_sequence(list(json_ok(list(id = "pl1"), 201L)))
    local_mocked_responses(mock$mock)
    res <- spotify_create_playlist("tok", "user9", "Mine", "desc", public = FALSE, backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(requested_paths(mock), "/users/user9/playlists")

    for (code in c(403L, 404L)) {
        mock <- mock_sequence(list(json_ok(list(), code), json_ok(list(id = "pl2"), 201L)))
        local_mocked_responses(mock$mock)
        res <- spotify_create_playlist("tok", "user9", "Mine", "desc", backoff = no_wait)
        expect_equal(res$state, "ok", info = code)
        expect_equal(requested_paths(mock), c("/users/user9/playlists", "/me/playlists"), info = code)
    }

    mock <- mock_sequence(list(json_ok(list(), 400L)))
    local_mocked_responses(mock$mock)
    res <- spotify_create_playlist("tok", "user9", "Mine", "desc", backoff = no_wait)
    expect_equal(res$state, "error")
    expect_length(mock$calls, 1)
})

test_that("playlists are created public, and what is asked for is what is sent", {
    # Spotify makes them public whatever we ask (see spotify_create_playlist), so public
    # is the default; the setting is still passed on exactly as given.
    mock <- mock_sequence(list(json_ok(list(id = "pl1"), 201L)))
    local_mocked_responses(mock$mock)
    spotify_create_playlist("tok", "user9", "Mine", "desc")
    expect_true(mock$calls[[1]]$body$data$public)

    mock <- mock_sequence(list(json_ok(list(id = "pl1"), 201L)))
    local_mocked_responses(mock$mock)
    spotify_create_playlist("tok", "user9", "Mine", "desc", public = FALSE)
    expect_false(mock$calls[[1]]$body$data$public)
})

test_that("adding tracks sends spotify URIs and falls back to /items", {
    mock <- mock_sequence(list(json_ok(list(snapshot_id = "s"), 201L)))
    local_mocked_responses(mock$mock)
    res <- spotify_add_tracks("tok", "pl1", c("t1", "t2"), backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(requested_paths(mock), "/playlists/pl1/tracks")
    expect_equal(unlist(mock$calls[[1]]$body$data$uris), c("spotify:track:t1", "spotify:track:t2"))

    mock <- mock_sequence(list(json_ok(list(), 403L), json_ok(list(snapshot_id = "s"), 201L)))
    local_mocked_responses(mock$mock)
    res <- spotify_add_tracks("tok", "pl1", "t1", backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(requested_paths(mock), c("/playlists/pl1/tracks", "/playlists/pl1/items"))
    # a single track is still sent as a list
    expect_equal(unlist(mock$calls[[2]]$body$data$uris), "spotify:track:t1")
})
