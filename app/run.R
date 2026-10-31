library(shiny)

# Run from the app directory so ui.R, server.R, scripts/, css/ and www/ resolve
setwd("app")

# Packages and the app's code (once), then the UI and the server
source("setup.R")
source("ui.R")
source("server.R")

# Create and run the application with function-based UI
# /health and the CSP report endpoint first, then the security headers around everything the handler answers
app <- shinyApp(
    ui = uiFunc,
    server = server,
    options = list(
        host = "0.0.0.0",
        port = as.integer(Sys.getenv("PORT", "8080"))
    )
) |>
    with_health_check() |>
    with_csp_reports() |>
    with_security_headers()

# Add JavaScript handler for OAuth redirect
shiny::addResourcePath("www", "www")

runApp(app)
