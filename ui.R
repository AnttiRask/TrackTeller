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
            id = "main_navbar",
            title = list(
                icon("spotify", lib = "font-awesome"),
                "TrackTeller"
            ),

            # Top Artists tab - landing page with inline auth
            tabPanel(
                "Top Artists",
                value = "top_artists",
                sidebarPanel(
                    # Show auth controls when not authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == false",
                        h3("Welcome to TrackTeller"),
                        br(),
                        p("Discover insights about your Spotify listening habits."),
                        br(),
                        p("Login to see your top artists, tracks, genres, and create playlists."),
                        br(),
                        actionButton("login_btn", "Login with Spotify",
                                   class = "btn-success btn-lg",
                                   icon = icon("spotify")),
                        br(),
                        br(),
                        uiOutput("auth_status")
                    ),

                    # Show controls when authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == true",
                        h3("Your Top Artists"),
                        br(),
                        p("Ranked by how much you listen to them."),
                        br(),
                        selectInput(
                            "time_range",
                            "Time range:",
                            choices = c(
                                "Last 4 weeks" = "short_term",
                                "Last 6 months" = "medium_term",
                                "All time" = "long_term"
                            ),
                            selected = "short_term"
                        ),
                        br(),
                        sliderInput(
                            "top_artists_count",
                            "Number of artists to show:",
                            min = 10,
                            max = 50,
                            value = 20,
                            step = 5
                        ),
                        br(),
                        p(class = "text-muted small",
                          "Note: Spotify only provides these three time ranges."),
                        br(),
                        hr(),
                        div(
                            style = "display: flex; align-items: center; gap: 10px;",
                            textOutput("user_display_name"),
                            actionButton("logout_btn", "Logout",
                                       class = "btn-outline-secondary btn-sm")
                        )
                    )
                ),
                mainPanel(
                    # Show welcome message when not authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == false",
                        div(
                            style = "text-align: center; padding: 60px 20px;",
                            h2("Discover Your Music DNA", style = "color: #1DB954;"),
                            br(),
                            p(style = "font-size: 1.1em; max-width: 500px; margin: 0 auto;",
                              "See your top artists, favorite tracks, genre breakdown, ",
                              "and create custom playlists based on your listening history."),
                            br(),
                            br(),
                            div(
                                style = "display: flex; justify-content: center; gap: 40px; flex-wrap: wrap;",
                                div(icon("users", class = "fa-3x", style = "color: #1DB954;"),
                                    p("Top Artists")),
                                div(icon("music", class = "fa-3x", style = "color: #1DB954;"),
                                    p("Top Tracks")),
                                div(icon("chart-bar", class = "fa-3x", style = "color: #1DB954;"),
                                    p("Genre Stats")),
                                div(icon("list", class = "fa-3x", style = "color: #1DB954;"),
                                    p("Playlists"))
                            )
                        )
                    ),
                    # Show artist list when authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == true",
                        uiOutput("top_artists_list"),
                        div(style = "height: 40px;")
                    )
                )
            ),

            # Top Tracks tab
            tabPanel(
                "Top Tracks",
                value = "top_tracks",
                sidebarPanel(
                    h3("Your Top Tracks"),
                    br(),
                    p("Your most played tracks, ranked by listening frequency."),
                    br(),
                    selectInput(
                        "time_range_tracks",
                        "Time range:",
                        choices = c(
                            "Last 4 weeks" = "short_term",
                            "Last 6 months" = "medium_term",
                            "All time" = "long_term"
                        ),
                        selected = "short_term"
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
                    uiOutput("top_tracks_list"),
                    div(style = "height: 40px;")
                )
            ),

            # Top Genres tab
            tabPanel(
                "Top Genres",
                value = "top_genres",
                sidebarPanel(
                    h3("Your Top Genres"),
                    br(),
                    p("Genre distribution across your top artists."),
                    br(),
                    selectInput(
                        "time_range_genres",
                        "Time range:",
                        choices = c(
                            "Last 4 weeks" = "short_term",
                            "Last 6 months" = "medium_term",
                            "All time" = "long_term"
                        ),
                        selected = "short_term"
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
                    plotlyOutput("genre_plot", height = 700),
                    div(style = "height: 40px;")
                )
            ),

            # My Playlists tab
            tabPanel(
                "My Playlists",
                value = "my_playlists",
                sidebarPanel(
                    h3("Your Playlists"),
                    br(),
                    p("Browse your Spotify playlists."),
                    br(),
                    sliderInput(
                        "playlists_count",
                        "Number of playlists to show:",
                        min = 10,
                        max = 50,
                        value = 20,
                        step = 5
                    )
                ),
                mainPanel(
                    uiOutput("user_playlists_list"),
                    div(style = "height: 40px;")
                )
            ),

            # Playlist Generator tab
            tabPanel(
                "Create Playlist",
                value = "playlist_generator",
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
                                       "Top Tracks from My Top Artists" = "artist_tracks",
                                       "Recently Played" = "recently_played"
                                   ),
                                   selected = "top_tracks"
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source != 'recently_played'",
                                   selectInput(
                                       "playlist_time_range",
                                       "Time range:",
                                       choices = c(
                                           "Last 4 weeks" = "short_term",
                                           "Last 6 months" = "medium_term",
                                           "All time" = "long_term"
                                       ),
                                       selected = "short_term"
                                   )
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source == 'top_tracks'",
                                   sliderInput(
                                       "playlist_track_count",
                                       "Number of tracks:",
                                       min = 10,
                                       max = 50,
                                       value = 20,
                                       step = 5
                                   )
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source == 'artist_tracks'",
                                   sliderInput(
                                       "num_top_artists",
                                       "Number of top artists to use:",
                                       min = 10,
                                       max = 50,
                                       value = 20,
                                       step = 5
                                   )
                               ),

                               conditionalPanel(
                                   condition = "input.playlist_source == 'recently_played'",
                                   sliderInput(
                                       "recent_tracks_count",
                                       "Number of tracks to use:",
                                       min = 10,
                                       max = 50,
                                       value = 20,
                                       step = 5
                                   )
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
