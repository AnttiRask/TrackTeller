req_over <- function(proto = NULL) if (is.null(proto)) list() else list(HTTP_X_FORWARDED_PROTO = proto)

test_that("every page gets the headers that restrict framing, referrers and browser features", {
    h <- security_headers(req_over())
    expect_equal(h[["X-Frame-Options"]], "DENY")
    expect_equal(h[["X-Content-Type-Options"]], "nosniff")
    expect_equal(h[["Referrer-Policy"]], "strict-origin-when-cross-origin")
    expect_match(h[["Permissions-Policy"]], "camera=\\(\\)")
    expect_match(h[["Permissions-Policy"]], "microphone=\\(\\)")
    expect_match(h[["Permissions-Policy"]], "geolocation=\\(\\)")
})

test_that("HSTS is sent only to requests that came in over https", {
    expect_null(security_headers(req_over())[["Strict-Transport-Security"]])
    expect_null(security_headers(req_over("http"))[["Strict-Transport-Security"]])
    for (proto in c("https", "HTTPS", "https,http")) {
        expect_equal(security_headers(req_over(proto))[["Strict-Transport-Security"]], "max-age=31536000")
    }
    # a year, for this host only: no includeSubDomains, no preload
    expect_no_match(security_headers(req_over("https"))[["Strict-Transport-Security"]], "includeSubDomains|preload")
})

test_that("the headers are added to a response and nothing else about it changes", {
    resp <- shiny::httpResponse(200L, "text/html", "<p>hi</p>", headers = list(`Cache-Control` = "no-store"))
    out <- add_security_headers(resp, req_over())
    expect_equal(out$status, 200L)
    expect_equal(out$content, "<p>hi</p>")
    expect_equal(out$headers[["Cache-Control"]], "no-store")
    expect_equal(out$headers[["X-Frame-Options"]], "DENY")
    expect_s3_class(out, class(resp)[1])
})

test_that("a header the handler set itself is kept, whatever its capitalisation", {
    resp <- shiny::httpResponse(200L, "text/html", "x", headers = list(`x-frame-options` = "SAMEORIGIN"))
    out <- add_security_headers(resp, req_over())
    expect_equal(sum(tolower(names(out$headers)) == "x-frame-options"), 1)
    expect_equal(out$headers[["x-frame-options"]], "SAMEORIGIN")
})

test_that("a handler with nothing to say still has nothing to say", {
    expect_null(add_security_headers(NULL, req_over()))
})

test_that("a response that arrives later gets the headers too", {
    later_resp <- promises::promise_resolve(shiny::httpResponse(200L, "text/plain", "ok"))
    out <- NULL
    promises::then(add_security_headers(later_resp, req_over()), function(value) out <<- value)
    for (i in 1:50) { later::run_now(0.01); if (!is.null(out)) break }
    expect_equal(out$headers[["X-Frame-Options"]], "DENY")
})

test_that("the app's page handler is wrapped, and the rest of the app is left alone", {
    app <- shiny::shinyApp(shiny::fluidPage("hello"), function(input, output, session) {})
    wrapped <- with_security_headers(app)
    expect_identical(wrapped$serverFuncSource, app$serverFuncSource)
    expect_identical(wrapped$onStart, app$onStart)

    # a handler of our own in its place, to see what the wrapper does with its answers
    app$httpHandler <- function(req) if (identical(req$PATH_INFO, "/")) shiny::httpResponse(200L, "text/html", "page") else NULL
    wrapped <- with_security_headers(app)
    expect_equal(wrapped$httpHandler(list(PATH_INFO = "/"))$headers[["X-Frame-Options"]], "DENY")
    expect_null(wrapped$httpHandler(list(PATH_INFO = "/elsewhere")))
})
