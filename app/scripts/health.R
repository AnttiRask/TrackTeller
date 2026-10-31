# GET /health: is this instance configured to work? 200 "ok", or 503 naming what is wrong
# (names only, never values). No call to Spotify: an outage there must not make a deploy
# or an uptime check fail, and it would cost a request per probe.

# What is wrong with the configuration, as a character vector (empty when all is well).
# A Spotify client id or secret is 32 lowercase hex characters (the same rule deploy.sh
# applies before it stores one). In production the redirect address must be https.
health_problems <- function(client_id, client_secret, app_url, production) {
    is_credential <- function(x) is.character(x) && length(x) == 1 && grepl("^[a-f0-9]{32}$", x)

    problems <- character(0)
    if (!is_credential(client_id)) problems <- c(problems, "SPOTIFY_CLIENT_ID")
    if (!is_credential(client_secret)) problems <- c(problems, "SPOTIFY_CLIENT_SECRET")
    if (isTRUE(production) && !(is.character(app_url) && length(app_url) == 1 && startsWith(app_url, "https://"))) {
        problems <- c(problems, "APP_URL")
    }
    problems
}

health_response <- function(problems) {
    headers <- list(`Cache-Control` = "no-store")
    if (length(problems) == 0) {
        shiny::httpResponse(200L, "text/plain; charset=utf-8", "ok", headers = headers)
    } else {
        shiny::httpResponse(503L, "text/plain; charset=utf-8",
                            paste0("unhealthy: ", paste(problems, collapse = ", ")), headers = headers)
    }
}

# The shinyApp() object, answering /health itself. `check` is a function returning the
# problems (the tests give their own).
with_health_check <- function(app, check = function() {
    health_problems(SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, APP_URL, is_production())
}) {
    handler <- app$httpHandler
    app$httpHandler <- function(req) {
        if (identical(req$PATH_INFO, "/health") && req$REQUEST_METHOD %in% c("GET", "HEAD")) {
            return(health_response(check()))
        }
        handler(req)
    }
    app
}
