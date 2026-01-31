# Load required packages
library(conflicted)
library(plotly)
library(purrr)
library(shinydashboard)
library(shinythemes)
library(stringr)
library(waiter)

# Load scripts from the 'scripts' folder
source("scripts/global.R", local = TRUE)
source("scripts/config.R", local = TRUE)
source("scripts/spotify_oauth.R", local = TRUE)

# Function-based UI for OAuth handling
uiFunc <- function(req) {
    # Parse query string for OAuth callback
    query <- parseQueryString(req$QUERY_STRING)

    # Check if this is an OAuth callback
    has_code <- !is.null(query$code)
    has_error <- !is.null(query$error)

    fluidPage(
        # Automatically display a loading screen until UI is ready
        autoWaiter(),

        # Set the theme and custom CSS
        theme = shinytheme("cyborg"),
        includeCSS("css/styles.css"),

        # JavaScript for OAuth redirect handling
        tags$head(
            tags$script(src = "www/redirect.js")
        ),

        # Hidden inputs to pass OAuth data to server
        tags$input(type = "hidden", id = "oauth_code", value = if (has_code) query$code else ""),
        tags$input(type = "hidden", id = "oauth_state", value = if (has_code) query$state else ""),
        tags$input(type = "hidden", id = "oauth_error", value = if (has_error) query$error else ""),

        navbarPage(
            # Application title
            title = list(
                icon("spotify", lib = "font-awesome"),
                "Spotify Playlist Generator"
            ),

            # Authentication tab
            tabPanel(
                "Intro",
                sidebarPanel(
                    h3("Authentication:"),
                    br(),

                    # Show different content based on auth state
                    conditionalPanel(
                        condition = "output.is_authenticated == false",
                        p("Click the button below to login with your Spotify account:"),
                        br(),
                        actionButton("login_btn", "Login with Spotify",
                                   class = "btn-success btn-lg",
                                   icon = icon("spotify")),
                        br(),
                        br()
                    ),

                    conditionalPanel(
                        condition = "output.is_authenticated == true",
                        p(icon("check-circle", class = "text-success"),
                          " You are logged in!"),
                        br(),
                        textOutput("user_display_name"),
                        br(),
                        actionButton("logout_btn", "Logout",
                                   class = "btn-outline-secondary")
                    ),

                    # Status messages
                    br(),
                    uiOutput("auth_status")
                ),
                mainPanel(
                    # Display welcome and instructions
                    h2("Welcome to the Spotify Playlist Generator"),
                    br(),
                    h6("You can use this tool to see different analyses on your favorite music on Spotify. You can even create new playlists that use your favorites as a starting point!"),
                    br(),
                    h6("Getting started is easy:"),
                    h6("Step 1: Click the 'Login with Spotify' button on the left"),
                    h6("Step 2: Authorize the app to access your Spotify data"),
                    h6("Step 3: You'll be redirected back here, ready to explore!"),
                    br(),
                    h6("Once logged in, click any of the tabs above to get started.")
                )
            ),

            # Feature per Album tab
            tabPanel(
                "Feature per Album",
                sidebarPanel(
                    h3("Features:"),

                    # User selection of features to display
                    selectInput(
                        "feature",
                        "Select a feature to view:",
                        choices  = features,
                        selected = "acousticness"
                    ),

                    # Introduction about the selected feature
                    textOutput("feature_introduction")
                ),

                # Plotting area
                mainPanel(
                    plotlyOutput("summary_plot", height = 700)
                )
            ),

            # Average Features tab
            tabPanel(
                "Average Features",
                div(
                    class = "plot-center",

                    # Plotting area
                    mainPanel(plotOutput("artists_plot", height = 700))
                )
            ),

            # Mood Quadrants tab
            tabPanel(
                "Mood Quadrants",
                sidebarPanel(
                    h3("Features:"),

                    # User selection for X and Y axis features
                    selectInput(
                        "x_var",
                        "X Axis (Horizontal):",
                        choices  = features,
                        selected = "energy"
                    ),
                    selectInput(
                        "y_var",
                        "Y Axis (Vertical):",
                        choices  = features,
                        selected = "valence"
                    )
                ),

                # Plotting area
                mainPanel(plotlyOutput("tracks_plot", height = 700))
            ),

            # Playlist Generator tab
            tabPanel(
                "Playlist Generator",
                fluidPage(
                    fluidRow(
                        column(3,
                               h3("Input:"),
                               br()
                        ),
                        column(8,
                               offset = 1,
                               h3("Targets:"),
                               br()
                        ),
                        column(3,
                               # Number of top artists and playlist name
                               numericInput("num_top_artists", "Number of top artists (1-5):", min = 1, max = 5, value = 5),
                               textInput("playlist_name", "Playlist Name: "),
                               br(),

                               # Button to generate the playlist
                               actionButton("generate", "Generate Playlist")
                        ),
                        column(4,
                               offset = 1,

                               # User inputs for target feature values
                               sliderInput("acousticness", "Acousticness (0-1):", min = 0, max = 1, value = 0.5, step = 0.1),
                               sliderInput("danceability", "Danceability (0-1):", min = 0, max = 1, value = 0.5, step = 0.1),
                               sliderInput("energy", "Energy (0-1):", min = 0, max = 1, value = 0.5, step = 0.1)
                        ),
                        column(4,
                               # User inputs for target feature values
                               sliderInput("instrumentalness", "Instrumentalness (0-1):", min = 0, max = 1, value = 0.5, step = 0.1),
                               sliderInput("speechiness", "Speechiness (0-1):", min = 0, max = 1, value = 0.5, step = 0.1),
                               sliderInput("valence", "Valence (0-1):", min = 0, max = 1, value = 0.5, step = 0.1)
                        ),
                        column(12,
                               br(),

                               # Display the link to the generated playlist
                               uiOutput("playlist_link")
                        )
                    )
                )
            )
        )
    )
}
