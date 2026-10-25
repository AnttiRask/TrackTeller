token_body <- function(...) modifyList(
    list(access_token = "new-access", token_type = "Bearer", expires_in = 3600, scope = "user-top-read"),
    list(...)
)

test_that("exchanging a code gives a token that expires in the future", {
    local_mocked_responses(list(response_json(200, body = token_body(refresh_token = "r1"))))
    res <- spotify_exchange_code("code", "id", "secret", "http://127.0.0.1:8080", backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(res$token$access_token, "new-access")
    expect_equal(res$token$refresh_token, "r1")
    expect_equal(as.numeric(difftime(res$token$expires_at, Sys.time(), units = "secs")), 3600, tolerance = 5)
})

test_that("a refresh keeps the old refresh token when Spotify sends none", {
    local_mocked_responses(list(response_json(200, body = token_body())))
    res <- spotify_refresh_token("old-refresh", "id", "secret", backoff = no_wait)
    expect_equal(res$state, "ok")
    expect_equal(res$token$refresh_token, "old-refresh")

    local_mocked_responses(list(response_json(200, body = token_body(refresh_token = "rotated"))))
    res <- spotify_refresh_token("old-refresh", "id", "secret", backoff = no_wait)
    expect_equal(res$token$refresh_token, "rotated")
})

test_that("the credentials go in the request body, not the address", {
    mock <- mock_sequence(list(response_json(200, body = token_body())))
    local_mocked_responses(mock$mock)
    spotify_exchange_code("the-code", "the-id", "the-secret", "http://127.0.0.1:8080", backoff = no_wait)
    req <- mock$calls[[1]]
    expect_false(grepl("the-secret|the-code", req$url))
    expect_equal(as.character(req$body$data$grant_type), "authorization_code")
    expect_equal(as.character(req$body$data$code), "the-code")
})

test_that("a rejected code or refresh token means log in again, without Spotify's text", {
    for (status in c(400L, 401L)) {
        local_mocked_responses(list(response_json(status, body = list(error = "invalid_grant", error_description = "Authorization code expired"))))
        res <- spotify_exchange_code("code", "id", "secret", "http://127.0.0.1:8080", backoff = no_wait)
        expect_equal(res$state, "reauth")
        expect_null(res$token)
        expect_false(grepl("invalid_grant|expired", res$message))
    }
})

test_that("server errors and network failures give state error and never throw", {
    local_mocked_responses(list(response(status_code = 500)))
    expect_equal(spotify_refresh_token("r", "id", "secret", backoff = no_wait)$state, "error")

    local_mocked_responses(function(req) stop("connection refused"))
    res <- expect_no_error(spotify_refresh_token("r", "id", "secret", backoff = no_wait))
    expect_equal(res$state, "error")
})

test_that("a 200 without an access token is an error", {
    local_mocked_responses(list(response_json(200, body = list(token_type = "Bearer"))))
    expect_equal(spotify_refresh_token("r", "id", "secret", backoff = no_wait)$state, "error")
})

test_that("token_is_expired uses a five minute buffer", {
    expect_true(token_is_expired(NULL))
    expect_true(token_is_expired(list(access_token = "x")))
    expect_true(token_is_expired(list(expires_at = Sys.time() + 299)))
    expect_false(token_is_expired(list(expires_at = Sys.time() + 301)))
    expect_true(token_is_expired(list(expires_at = Sys.time() - 10)))
})

test_that("the authorize URL carries the client, redirect, scopes and state", {
    url <- spotify_authorize_url("my-id", "http://127.0.0.1:8080", c("user-top-read", "playlist-read-private"), state = "abc")
    expect_match(url, "^https://accounts.spotify.com/authorize\\?")
    expect_match(url, "client_id=my-id")
    expect_match(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8080", fixed = TRUE)
    expect_match(url, "scope=user-top-read%20playlist-read-private", fixed = TRUE)
    expect_match(url, "state=abc")
})

# ---- the state value of a login ----

test_that("a fresh state checks out when the same browser brings it back", {
    login <- oauth_state_new("secret")
    expect_match(login$nonce, "^[0-9a-f]{32}$")
    expect_match(login$state, paste0("^", login$nonce, "\\.[0-9]+\\.[0-9a-f]{64}$"))
    expect_true(oauth_state_check(login$state, login$nonce, "secret")$ok)
})

test_that("every login gets a different state", {
    expect_false(oauth_state_new("secret")$state == oauth_state_new("secret")$state)
})

test_that("a state is refused when it is missing, mangled or not signed with our secret", {
    login <- oauth_state_new("secret")
    reason <- \(state, nonce = login$nonce, secret = "secret") oauth_state_check(state, nonce, secret)$reason

    expect_equal(reason(NULL), "missing")
    expect_equal(reason(""), "missing")
    expect_equal(reason(NA_character_), "missing")
    expect_equal(reason(c(login$state, login$state)), "missing")
    expect_equal(reason("not-a-state"), "malformed")
    expect_equal(reason(paste0(login$state, ".extra")), "malformed")
    expect_equal(reason(paste0("ZZ", substring(login$state, 3))), "malformed")
    expect_equal(reason(login$state, secret = "another secret"), "signature")

    # A changed timestamp (to make an old state look new) breaks the signature
    parts <- strsplit(login$state, ".", fixed = TRUE)[[1]]
    expect_equal(reason(paste(parts[1], as.integer(parts[2]) + 5, parts[3], sep = ".")), "signature")
    expect_equal(reason(paste(parts[1], parts[2], strrep("0", 64), sep = ".")), "signature")
})

test_that("a state is good for ten minutes", {
    now <- as.POSIXct("2026-10-26 12:00:00", tz = "UTC")
    login <- oauth_state_new("secret", now = now)

    expect_true(oauth_state_check(login$state, login$nonce, "secret", now = now + 599)$ok)
    expect_equal(oauth_state_check(login$state, login$nonce, "secret", now = now + 601)$reason, "expired")
    # one from the future (clock far off) is not accepted either
    expect_equal(oauth_state_check(login$state, login$nonce, "secret", now = now - 120)$reason, "expired")
})

test_that("a state is refused in a browser that didn't start the login", {
    login <- oauth_state_new("secret")
    other <- oauth_state_new("secret")
    expect_equal(oauth_state_check(login$state, other$nonce, "secret")$reason, "browser")
    expect_equal(oauth_state_check(login$state, "", "secret")$reason, "browser")
    expect_equal(oauth_state_check(login$state, NULL, "secret")$reason, "browser")
})
