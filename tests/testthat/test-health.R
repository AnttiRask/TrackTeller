id     <- "0123456789abcdef0123456789abcdef"
secret <- "fedcba9876543210fedcba9876543210"

test_that("a configured instance is healthy", {
    expect_length(health_problems(id, secret, "https://trackteller.example", production = TRUE), 0)
    # development may use plain http (Spotify's loopback address)
    expect_length(health_problems(id, secret, "http://127.0.0.1:8080", production = FALSE), 0)
})

test_that("missing or malformed credentials are named, and their values never appear", {
    expect_equal(health_problems("", secret, "https://x", TRUE), "SPOTIFY_CLIENT_ID")
    expect_equal(health_problems(id, "", "https://x", TRUE), "SPOTIFY_CLIENT_SECRET")
    expect_equal(health_problems("", "", "https://x", TRUE), c("SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"))
    # a quote or a carriage return (an outage once) and uppercase hex are not what Spotify issues
    expect_equal(health_problems(paste0('"', id, '"'), secret, "https://x", TRUE), "SPOTIFY_CLIENT_ID")
    expect_equal(health_problems(id, paste0(secret, "\r"), "https://x", TRUE), "SPOTIFY_CLIENT_SECRET")
    expect_equal(health_problems(toupper(id), secret, "https://x", TRUE), "SPOTIFY_CLIENT_ID")
    expect_equal(health_problems(NA_character_, secret, "https://x", TRUE), "SPOTIFY_CLIENT_ID")
    expect_equal(health_problems(NULL, secret, "https://x", TRUE), "SPOTIFY_CLIENT_ID")

    body <- health_response(health_problems(paste0('"', id, '"'), "", "https://x", TRUE))$content
    expect_no_match(body, "0123456789abcdef")
})

test_that("in production the redirect address must be https", {
    expect_equal(health_problems(id, secret, "http://trackteller.example", TRUE), "APP_URL")
    expect_equal(health_problems(id, secret, "", TRUE), "APP_URL")
    expect_equal(health_problems(id, secret, NULL, TRUE), "APP_URL")
    expect_length(health_problems(id, secret, "http://trackteller.example", FALSE), 0)
})

test_that("the answer is 200 ok or 503 with what is wrong, and is never cached", {
    ok <- health_response(character(0))
    expect_equal(ok$status, 200L)
    expect_equal(ok$content, "ok")
    expect_equal(ok$headers[["Cache-Control"]], "no-store")

    bad <- health_response(c("SPOTIFY_CLIENT_ID", "APP_URL"))
    expect_equal(bad$status, 503L)
    expect_equal(bad$content, "unhealthy: SPOTIFY_CLIENT_ID, APP_URL")
    expect_equal(bad$headers[["Cache-Control"]], "no-store")
})

page <- function(req) if (identical(req$PATH_INFO, "/")) shiny::httpResponse(200L, "text/html", "page") else NULL
wrapped <- function(check, ...) {
    app <- shiny::shinyApp(shiny::fluidPage("x"), function(input, output, session) {})
    app$httpHandler <- page
    with_health_check(app, check = check)
}

test_that("/health is answered by the wrapper; everything else still goes to the app", {
    app <- wrapped(function() character(0))
    expect_equal(app$httpHandler(list(PATH_INFO = "/health", REQUEST_METHOD = "GET"))$content, "ok")
    expect_equal(app$httpHandler(list(PATH_INFO = "/health", REQUEST_METHOD = "HEAD"))$status, 200L)
    expect_equal(app$httpHandler(list(PATH_INFO = "/", REQUEST_METHOD = "GET"))$content, "page")
    expect_null(app$httpHandler(list(PATH_INFO = "/elsewhere", REQUEST_METHOD = "GET")))
    # only the exact path, and only for reading
    expect_null(app$httpHandler(list(PATH_INFO = "/health/x", REQUEST_METHOD = "GET")))
    expect_null(app$httpHandler(list(PATH_INFO = "/health", REQUEST_METHOD = "POST")))
})

test_that("the answer follows the check each time it is asked", {
    problems <- character(0)
    app <- wrapped(function() problems)
    req <- list(PATH_INFO = "/health", REQUEST_METHOD = "GET")
    expect_equal(app$httpHandler(req)$status, 200L)
    problems <- "APP_URL"
    expect_equal(app$httpHandler(req)$status, 503L)
})

test_that("health and security headers work together: the answer carries both", {
    app <- with_security_headers(wrapped(function() character(0)))
    out <- app$httpHandler(list(PATH_INFO = "/health", REQUEST_METHOD = "GET"))
    expect_equal(out$content, "ok")
    expect_equal(out$headers[["X-Frame-Options"]], "DENY")
    expect_equal(out$headers[["Cache-Control"]], "no-store")
})
