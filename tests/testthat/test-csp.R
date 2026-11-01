test_that("the policy allows the page's own files, the font host and Spotify's pictures, and little else", {
    policy <- csp_policy("trackteller.example")
    directive <- function(name) sub(paste0("^", name, " "), "", grep(paste0("^", name, " "), strsplit(policy, "; ")[[1]], value = TRUE))

    expect_equal(directive("default-src"), "'self'")
    expect_equal(directive("object-src"), "'none'")
    expect_equal(directive("base-uri"), "'self'")
    expect_equal(directive("form-action"), "'self'")
    expect_equal(directive("frame-ancestors"), "'none'")
    expect_match(directive("font-src"), "https://fonts.cdnfonts.com")
    expect_match(directive("style-src"), "https://fonts.cdnfonts.com")
    expect_match(directive("img-src"), "https://\\*.scdn.co")
    expect_match(directive("img-src"), "https://\\*.spotifycdn.com")
    # no script host other than the page's own; inline and eval because Shiny needs both
    expect_equal(directive("script-src"), "'self' 'unsafe-inline' 'unsafe-eval'")
})

test_that("the websocket may go to the page's own host, over ws and wss", {
    policy <- csp_policy("trackteller.example")
    expect_match(policy, "connect-src 'self' ws://trackteller.example wss://trackteller.example")
    expect_match(csp_policy("127.0.0.1:8080"), "wss://127.0.0.1:8080")
})

test_that("a host header that isn't a plain host adds nothing to the policy", {
    for (host in list(NULL, NA_character_, "", "a b", "evil.example; script-src *", "x'y", c("a", "b"))) {
        policy <- csp_policy(host)
        expect_match(policy, "connect-src 'self';")
        expect_no_match(policy, "script-src \\*")
    }
})

test_that("reports go to our endpoint, in both formats browsers use", {
    policy <- csp_policy("x.example")
    expect_match(policy, "report-uri /csp-report")
    expect_match(policy, "report-to csp")
    expect_equal(csp_headers(list(HTTP_HOST = "x.example"), "report-only")[["Reporting-Endpoints"]], 'csp="/csp-report"')
})

test_that("the mode picks the header: report-only reports, enforce blocks, off sends nothing", {
    req <- list(HTTP_HOST = "x.example")
    expect_named(csp_headers(req, "report-only"), c("Content-Security-Policy-Report-Only", "Reporting-Endpoints"))
    expect_named(csp_headers(req, "enforce"), c("Content-Security-Policy", "Reporting-Endpoints"))
    expect_length(csp_headers(req, "off"), 0)
})

test_that("CSP_MODE selects the mode; unset or unknown means enforce", {
    withr::with_envvar(c(CSP_MODE = "report-only"), expect_equal(csp_mode(), "report-only"))
    withr::with_envvar(c(CSP_MODE = "REPORT-ONLY"), expect_equal(csp_mode(), "report-only"))
    withr::with_envvar(c(CSP_MODE = "off"), expect_equal(csp_mode(), "off"))
    withr::with_envvar(c(CSP_MODE = "enforce"), expect_equal(csp_mode(), "enforce"))
    # a typo must not weaken the policy
    withr::with_envvar(c(CSP_MODE = "enforced"), expect_equal(csp_mode(), "enforce"))
    withr::with_envvar(c(CSP_MODE = "nonsense"), expect_equal(csp_mode(), "enforce"))
    withr::with_envvar(c(CSP_MODE = ""), expect_equal(csp_mode(), "enforce"))
    withr::with_envvar(c(CSP_MODE = NA), expect_equal(csp_mode(), "enforce"))
})

test_that("the page's headers include the policy, enforced unless the mode says otherwise", {
    req <- list(HTTP_HOST = "x.example")
    withr::with_envvar(c(CSP_MODE = NA), {
        resp <- add_security_headers(shiny::httpResponse(200L, "text/html", "x"), req)
        expect_match(resp$headers[["Content-Security-Policy"]], "^default-src 'self'")
        expect_null(resp$headers[["Content-Security-Policy-Report-Only"]])
    })
    withr::with_envvar(c(CSP_MODE = "report-only"), {
        resp <- add_security_headers(shiny::httpResponse(200L, "text/html", "x"), req)
        expect_match(resp$headers[["Content-Security-Policy-Report-Only"]], "^default-src 'self'")
        expect_null(resp$headers[["Content-Security-Policy"]])
    })
    withr::with_envvar(c(CSP_MODE = "off"), {
        resp <- add_security_headers(shiny::httpResponse(200L, "text/html", "x"), req)
        expect_null(resp$headers[["Content-Security-Policy"]])
        expect_null(resp$headers[["Content-Security-Policy-Report-Only"]])
        expect_equal(resp$headers[["X-Frame-Options"]], "DENY")
    })
})

# ---- reports ----

old_format <- function(...) jsonlite::toJSON(list(`csp-report` = list(...)), auto_unbox = TRUE)

test_that("a report-uri report becomes one line with the directive, what was blocked, and where", {
    line <- csp_report_lines(old_format(
        `document-uri` = "https://trackteller.example/?code=SECRET1&state=SECRET2",
        `effective-directive` = "img-src",
        `blocked-uri` = "https://cdn.other.example/a/b.png?token=SECRET3",
        `source-file` = "https://trackteller.example/www/x.js?v=SECRET4",
        `line-number` = 12L, disposition = "report"))
    expect_equal(line, "[csp] img-src blocked=https://cdn.other.example page=/ source=https://trackteller.example/www/x.js:12 (report)")
    expect_no_match(line, "SECRET")
})

test_that("a report-to report is read too", {
    body <- jsonlite::toJSON(list(list(type = "csp-violation", body = list(
        documentURL = "https://trackteller.example/some/page?code=SECRET",
        effectiveDirective = "font-src", blockedURL = "https://fonts.other.example/f.woff2",
        sourceFile = "", lineNumber = 0L, disposition = "report"))), auto_unbox = TRUE)
    line <- csp_report_lines(body)
    expect_match(line, "^\\[csp\\] font-src blocked=https://fonts.other.example page=/some/page")
    expect_no_match(line, "SECRET")
})

test_that("inline and eval violations keep their kind, and a data: address isn't echoed", {
    expect_match(csp_report_lines(old_format(`effective-directive` = "script-src", `blocked-uri` = "inline")), "blocked=inline")
    expect_match(csp_report_lines(old_format(`effective-directive` = "script-src", `blocked-uri` = "eval")), "blocked=eval")
    line <- csp_report_lines(old_format(`effective-directive` = "img-src", `blocked-uri` = "data:image/png;base64,AAAA"))
    expect_no_match(line, "AAAA")
})

test_that("rubbish and hostile reports are harmless", {
    expect_length(csp_report_lines("not json"), 0)
    expect_length(csp_report_lines(""), 0)
    expect_length(csp_report_lines("{}"), 0)
    expect_length(csp_report_lines("[1, 2, 3]"), 0)
    line <- csp_report_lines(old_format(`effective-directive` = "img-src\n[csp] FAKE <script>",
                                        `blocked-uri` = paste0("https://", strrep("a", 5000), ".example/")))
    expect_length(line, 1)
    expect_no_match(line, "\n")
    expect_no_match(line, "<script>")
    expect_lt(nchar(line), 600)
})

test_that("only a limited number of lines are written per hour", {
    withr::defer(.csp_budget$hour <- NULL)
    .csp_budget$hour <- NULL
    now <- as.POSIXct("2026-10-31 12:00:00", tz = "UTC")
    expect_equal(csp_budget_take(100, now), 100L)
    expect_equal(csp_budget_take(300, now), 200L)       # 300 in all
    expect_equal(csp_budget_take(5, now), 0L)
    expect_equal(csp_budget_take(5, now + 3600), 5L)    # a new hour
})

fake_post <- function(body, length = nchar(body, "bytes")) {
    list(PATH_INFO = "/csp-report", REQUEST_METHOD = "POST", CONTENT_LENGTH = as.character(length),
         rook.input = list(read = function(n) charToRaw(body)))
}

test_that("the endpoint logs what was reported and answers 204", {
    withr::defer(.csp_budget$hour <- NULL); .csp_budget$hour <- NULL
    logged <- character(0)
    resp <- csp_report_response(fake_post(as.character(old_format(`effective-directive` = "img-src", `blocked-uri` = "https://x.example/a"))),
                                log = function(line) logged <<- c(logged, line))
    expect_equal(resp$status, 204L)
    expect_length(logged, 1)
    expect_match(logged, "img-src blocked=https://x.example")
})

test_that("an oversized or length-less report is refused without being read", {
    read <- FALSE
    big <- list(CONTENT_LENGTH = "999999", rook.input = list(read = function(n) { read <<- TRUE; raw(0) }))
    expect_equal(csp_report_response(big)$status, 413L)
    nolength <- list(rook.input = list(read = function(n) { read <<- TRUE; raw(0) }))
    expect_equal(csp_report_response(nolength)$status, 413L)
    expect_false(read)
})

test_that("only POST to the report path is taken by the wrapper", {
    app <- shiny::shinyApp(shiny::fluidPage("x"), function(input, output, session) {})
    app$httpHandler <- function(req) shiny::httpResponse(200L, "text/plain", "app")
    logged <- character(0)
    wrapped <- with_csp_reports(app, log = function(line) logged <<- c(logged, line))

    expect_equal(wrapped$httpHandler(fake_post("{}"))$status, 204L)
    get <- fake_post("{}"); get$REQUEST_METHOD <- "GET"
    expect_equal(wrapped$httpHandler(get)$content, "app")
    other <- fake_post("{}"); other$PATH_INFO <- "/elsewhere"
    expect_equal(wrapped$httpHandler(other)$content, "app")
})
