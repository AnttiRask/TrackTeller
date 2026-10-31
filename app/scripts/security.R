# Response headers that tell the browser how far to trust and expose the page. Shiny has no
# setting for them, so the app's HTTP handler (the one that answers for the page itself) is
# wrapped. Static files (js, css, images) already get X-Content-Type-Options from Shiny.

# Headers for a request. HSTS only when the request really came in over https (Cloud Run
# says so in X-Forwarded-Proto): a browser ignores it over http, but then it is just noise
# in local development.
security_headers <- function(req) {
    headers <- list(
        # Nobody has a reason to show this app inside another page
        `X-Frame-Options` = "DENY",
        `X-Content-Type-Options` = "nosniff",
        # Other sites get the address's origin at most, never its query: the login's
        # code and state are in the query when Spotify sends the browser back
        `Referrer-Policy` = "strict-origin-when-cross-origin",
        # The app uses none of these browser features
        `Permissions-Policy` = paste(
            "camera=()", "microphone=()", "geolocation=()", "payment=()", "usb=()",
            "accelerometer=()", "gyroscope=()", "magnetometer=()", "interest-cohort=()",
            sep = ", "
        )
    )

    proto <- tolower(as.character(req$HTTP_X_FORWARDED_PROTO %||% ""))
    if (length(proto) == 1 && startsWith(proto, "https")) {
        headers[["Strict-Transport-Security"]] <- "max-age=31536000"
    }
    headers
}

# Add the headers to a response that doesn't have them already (a handler's own header wins).
# NULL (this handler has nothing to say, the next one tries) stays NULL.
add_security_headers <- function(resp, req) {
    if (is.null(resp)) return(resp)
    if (promises::is.promise(resp)) {
        return(promises::then(resp, function(value) add_security_headers(value, req)))
    }

    ours <- security_headers(req)
    existing <- as.list(resp$headers)
    missing <- !(tolower(names(ours)) %in% tolower(names(existing)))
    resp$headers <- c(existing, ours[missing])
    resp
}

# The shinyApp() object with its page handler wrapped
with_security_headers <- function(app) {
    handler <- app$httpHandler
    app$httpHandler <- function(req) add_security_headers(handler(req), req)
    app
}
