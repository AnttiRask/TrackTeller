# Content-Security-Policy: what the browser may load for the page, and where it reports
# what it would block. It has three modes, set with the CSP_MODE environment variable so
# that going back needs no rebuild (gcloud run services update --update-env-vars):
#   "report-only"  the browser reports violations and blocks nothing (the default while the
#                  policy is being checked against real use)
#   "enforce"      the browser blocks them
#   "off"          no policy
# Violations are reported to POST /csp-report and written to the log as one short line
# each: only what was blocked (origin or kind) and where, never an address's query: the
# page address holds the login's code and state when Spotify sends the browser back.

CSP_REPORT_PATH <- "/csp-report"

csp_mode <- function() {
    mode <- tolower(Sys.getenv("CSP_MODE", "report-only"))
    if (mode %in% c("report-only", "enforce", "off")) mode else "report-only"
}

# The policy for a page served on `host` (the websocket goes to the same host).
# 'unsafe-inline' is needed for scripts and styles: Shiny puts inline scripts in the page
# and style attributes everywhere, and has no nonce support. 'unsafe-eval' is needed too:
# shiny.min.js calls eval when it renders output that carries scripts (seen 22 times in one
# session in report-only mode). What the policy still does: no script from another host, no
# plugins, no framing, no changed <base>, no form posts elsewhere, and pictures, fonts and
# connections only to the hosts the app uses.
csp_policy <- function(host) {
    host <- if (is.character(host) && length(host) == 1 && grepl("^[A-Za-z0-9.:-]+$", host)) host else NULL
    sockets <- if (is.null(host)) character(0) else c(paste0("ws://", host), paste0("wss://", host))

    directives <- list(
        `default-src`     = "'self'",
        `script-src`      = c("'self'", "'unsafe-inline'", "'unsafe-eval'"),
        # fonts.cdnfonts.com: the Gotham stylesheet, and the font files it names
        `style-src`       = c("'self'", "'unsafe-inline'", "https://fonts.cdnfonts.com"),
        `font-src`        = c("'self'", "https://fonts.cdnfonts.com", "data:"),
        # Spotify's pictures (artists, albums, playlists); data: and blob: for the charts
        `img-src`         = c("'self'", "data:", "blob:", "https://*.scdn.co", "https://*.spotifycdn.com"),
        `connect-src`     = c("'self'", sockets),
        `object-src`      = "'none'",
        `base-uri`        = "'self'",
        `form-action`     = "'self'",
        `frame-ancestors` = "'none'",
        `report-uri`      = CSP_REPORT_PATH,
        `report-to`       = "csp"
    )
    paste(vapply(names(directives), function(name) paste(name, paste(directives[[name]], collapse = " ")), character(1)),
          collapse = "; ")
}

# The headers for a request: the policy in the header that fits the mode, and the
# endpoint that `report-to` names
csp_headers <- function(req, mode = csp_mode()) {
    if (mode == "off") return(list())

    name <- if (mode == "enforce") "Content-Security-Policy" else "Content-Security-Policy-Report-Only"
    out <- list(csp_policy(req$HTTP_HOST))
    names(out) <- name
    out[["Reporting-Endpoints"]] <- paste0('csp="', CSP_REPORT_PATH, '"')
    out
}

# ---- the reports ----

# Keep a value short and plain: reports come from anybody's browser
csp_clean <- function(x, max = 120) {
    x <- as.character(x %||% "")[1]
    if (is.na(x)) x <- ""
    substr(gsub("[^A-Za-z0-9 .:/_*'-]", "?", x), 1, max)
}

# https://host/path?query#frag -> https://host (the origin, which is what tells us what to allow);
# "inline" and "eval" stay as they are, data:... and blob:... become "data:" and "blob:"
csp_origin <- function(uri) {
    uri <- as.character(uri %||% "")[1]
    if (is.na(uri) || !nzchar(uri)) return("")
    # data:image/png;base64,... and blob:... are not echoed, only their kind
    if (!grepl("://", uri, fixed = TRUE)) return(csp_clean(sub(":.*$", ":", uri), 20))
    csp_clean(sub("^([A-Za-z][A-Za-z0-9+.-]*://[^/?#]*).*$", "\\1", uri))
}

# https://host/path?query -> /path (no query, no host)
csp_path <- function(uri) {
    uri <- as.character(uri %||% "")[1]
    if (is.na(uri) || !nzchar(uri)) return("")
    csp_clean(sub("[?#].*$", "", sub("^[A-Za-z][A-Za-z0-9+.-]*://[^/]*", "", uri)))
}

# One log line per violation in a report body (either format: report-uri sends
# {"csp-report": {...}}, report-to sends [{"type": "csp-violation", "body": {...}}])
csp_report_lines <- function(body) {
    parsed <- tryCatch(jsonlite::fromJSON(body, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(parsed)) return(character(0))

    reports <- if (!is.null(parsed[["csp-report"]])) {
        list(parsed[["csp-report"]])
    } else if (is.list(parsed) && is.null(names(parsed))) {
        lapply(Filter(function(r) is.list(r) && identical(r$type, "csp-violation"), parsed), function(r) r$body)
    } else {
        list()
    }

    vapply(Filter(is.list, reports), function(r) {
        directive <- r[["effective-directive"]] %||% r[["effectiveDirective"]] %||%
            r[["violated-directive"]] %||% r[["violatedDirective"]]
        blocked <- r[["blocked-uri"]] %||% r[["blockedURL"]] %||% r[["blockedURI"]]
        source <- r[["source-file"]] %||% r[["sourceFile"]]
        line <- suppressWarnings(as.integer((r[["line-number"]] %||% r[["lineNumber"]] %||% NA)[1]))
        disposition <- r[["disposition"]] %||% ""
        paste0("[csp] ", csp_clean(directive, 40), " blocked=", csp_origin(blocked),
               " page=", csp_path(r[["document-uri"]] %||% r[["documentURL"]]),
               " source=", csp_origin(source), csp_path(source), if (!is.na(line)) paste0(":", line) else "",
               if (nzchar(disposition)) paste0(" (", csp_clean(disposition, 12), ")") else "")
    }, character(1))
}

CSP_REPORT_MAX_BYTES <- 16384L
# At most this many lines per instance and hour: the endpoint is open to anybody
CSP_REPORT_MAX_LINES_PER_HOUR <- 300L
.csp_budget <- new.env()
.csp_budget$hour <- NULL
.csp_budget$used <- 0L

# Spend `n` lines of the hourly budget; returns how many may be written
csp_budget_take <- function(n, now = Sys.time()) {
    hour <- format(now, "%Y%m%d%H")
    if (!identical(.csp_budget$hour, hour)) {
        .csp_budget$hour <- hour
        .csp_budget$used <- 0L
    }
    allowed <- max(0L, min(n, CSP_REPORT_MAX_LINES_PER_HOUR - .csp_budget$used))
    .csp_budget$used <- .csp_budget$used + allowed
    allowed
}

# POST /csp-report: log what was reported, answer 204 (nothing to send back)
csp_report_response <- function(req, log = message) {
    declared <- suppressWarnings(as.integer(req$CONTENT_LENGTH %||% NA))
    if (is.na(declared) || declared > CSP_REPORT_MAX_BYTES) {
        return(shiny::httpResponse(413L, "text/plain", "too large"))
    }
    body <- tryCatch(rawToChar(req$rook.input$read(declared)), error = function(e) "")
    lines <- csp_report_lines(body)
    for (line in utils::head(lines, csp_budget_take(length(lines)))) log(line)
    shiny::httpResponse(204L, "text/plain", "")
}

# The shinyApp() object, answering the report endpoint itself
with_csp_reports <- function(app, log = message) {
    handler <- app$httpHandler
    app$httpHandler <- function(req) {
        if (identical(req$PATH_INFO, CSP_REPORT_PATH) && identical(req$REQUEST_METHOD, "POST")) {
            return(csp_report_response(req, log))
        }
        handler(req)
    }
    app
}
