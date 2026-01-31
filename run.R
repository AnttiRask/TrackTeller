library(shiny)

# Source the UI and server files
source("ui.R")
source("server.R")

# Create and run the application with function-based UI
app <- shinyApp(
    ui = uiFunc,
    server = server,
    options = list(
        host = "0.0.0.0",
        port = as.integer(Sys.getenv("PORT", "8080"))
    )
)

# Add JavaScript handler for OAuth redirect
shiny::addResourcePath("www", "www")

runApp(app)
