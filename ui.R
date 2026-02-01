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

            # Top Artists tab - shows user's top artists with details
            tabPanel(
                "Top Artists",
                sidebarPanel(
                    h3("Your Top Artists"),
                    br(),
                    p("This shows your top 20 artists from Spotify, ranked by how much you listen to them."),
                    br(),
                    selectInput(
                        "time_range_artists",
                        "Time range:",
                        choices = c(
                            "Last 4 weeks" = "short_term",
                            "Last 6 months" = "medium_term",
                            "All time" = "long_term"
                        ),
                        selected = "medium_term"
                    ),
                    br(),
                    p("Click on an artist bar to see more details.")
                ),
                mainPanel(
                    plotlyOutput("top_artists_plot", height = 700)
                )
            ),

            # Genre Distribution tab
            tabPanel(
                "Genre Distribution",
                sidebarPanel(
                    h3("Your Music Genres"),
                    br(),
                    p("This shows the distribution of genres across your top artists."),
                    br(),
                    selectInput(
                        "time_range_genres",
                        "Time range:",
                        choices = c(
                            "Last 4 weeks" = "short_term",
                            "Last 6 months" = "medium_term",
                            "All time" = "long_term"
                        ),
                        selected = "medium_term"
                    ),
                    br(),
                    sliderInput(
                        "top_genres_count",
                        "Number of top genres to show:",
                        min = 5,
                        max = 20,
                        value = 10,
                        step = 1
                    )
                ),
                mainPanel(
                    plotlyOutput("genre_plot", height = 700)
                )
            ),

            # Top Tracks tab
            tabPanel(
                "Top Tracks",
                sidebarPanel(
                    h3("Your Top Tracks"),
                    br(),
                    p("These are your most played tracks on Spotify."),
                    br(),
                    selectInput(
                        "time_range_tracks",
                        "Time range:",
                        choices = c(
                            "Last 4 weeks" = "short_term",
                            "Last 6 months" = "medium_term",
                            "All time" = "long_term"
                        ),
                        selected = "medium_term"
                    ),
                    br(),
                    sliderInput(
                        "top_tracks_count",
                        "Number of tracks to show:",
                        min = 10,
                        max = 50,
                        value = 20,
                        step = 5
                    )
                ),
                mainPanel(
                    plotlyOutput("top_tracks_plot", height = 700)
                )
            ),

            # Playlist Generator tab - redesigned without recommendations API
            tabPanel(
                "Playlist Generator",
                fluidPage(
                    fluidRow(
                        column(4,
                               h3("Create Your Playlist"),
                               br(),
                               p("Create a playlist from your top tracks or discover new music from your favorite artists."),
                               br(),

                               selectInput(
                                   "playlist_source",
                                   "Source:",
                                   choices = c(
                                       "My Top Tracks" = "top_tracks",
                                       "Top Tracks from My Top Artists" = "artist_tracks"
                                   ),
                                   selected = "top_tracks"
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source == 'top_tracks'",
                                   selectInput(
                                       "playlist_time_range",
                                       "Time range:",
                                       choices = c(
                                           "Last 4 weeks" = "short_term",
                                           "Last 6 months" = "medium_term",
                                           "All time" = "long_term"
                                       ),
                                       selected = "medium_term"
                                   )
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source == 'artist_tracks'",
                                   numericInput(
                                       "num_top_artists",
                                       "Number of top artists to use (1-10):",
                                       min = 1,
                                       max = 10,
                                       value = 5
                                   )
                               ),

                               sliderInput(
                                   "playlist_track_count",
                                   "Number of tracks:",
                                   min = 10,
                                   max = 50,
                                   value = 20,
                                   step = 5
                               ),

                               textInput("playlist_name", "Playlist Name:"),
                               br(),

                               actionButton("generate", "Generate Playlist",
                                          class = "btn-success btn-lg",
                                          icon = icon("music"))
                        ),
                        column(8,
                               br(),
                               br(),
                               h4("Preview"),
                               p("Tracks that will be added to your playlist:"),
                               br(),
                               uiOutput("playlist_preview"),
                               br(),
                               uiOutput("playlist_link")
                        )
                    )
                )
            )
        )
    )
}
