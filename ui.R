# Load required packages
library(bslib)
library(conflicted)
library(plotly)
library(purrr)
library(stringr)
library(waiter)

# Load scripts from the 'scripts' folder
source("scripts/global.R", local = TRUE)
source("scripts/config.R", local = TRUE)
source("scripts/spotify_oauth.R", local = TRUE)

# Shared footer component for cross-linking between apps
create_app_footer <- function(current_app = "") {
    tags$footer(
        class = "app-footer mt-5 py-4 border-top",
        div(
            class = "container text-center",
            div(
                class = "footer-apps mb-3",
                div(
                    class = "d-flex justify-content-center gap-3 flex-wrap",
                    if(current_app != "bibliostatus")
                        a(href = "https://bibliostatus.youcanbeapirate.com", "BiblioStatus"),
                    if(current_app != "gallery")
                        a(href = "https://galleryoftheday.youcanbeapirate.com", "Gallery of the Day"),
                    if(current_app != "trackteller")
                        a(href = "https://trackteller.youcanbeapirate.com", "TrackTeller"),
                    if(current_app != "tuneteller")
                        a(href = "https://tuneteller.youcanbeapirate.com", "TuneTeller")
                )
            ),
            div(
                class = "footer-credit",
                p(
                    "Created by ",
                    a(href = "https://www.linkedin.com/in/AnttiRask/", "Antti Rask"),
                    " | ",
                    a(href = "https://youcanbeapirate.com", "youcanbeapirate.com")
                )
            )
        )
    )
}

# Function-based UI for OAuth handling
uiFunc <- function(req) {
    # Parse query string for OAuth callback
    query <- parseQueryString(req$QUERY_STRING)

    # Check if this is an OAuth callback
    has_code <- !is.null(query$code)
    has_error <- !is.null(query$error)

    page_navbar(
        theme = bs_theme(
            version = 5,
            bg = "#191414",
            fg = "#FFFFFF",
            primary = "#1DB954",      # Spotify green
            secondary = "#C1272D",    # YouCanBePirate red
            success = "#1DB954",
            base_font = font_link(
                family = "Gotham",
                href = "https://fonts.cdnfonts.com/css/gotham-6"
            )
        ),

        header = tags$head(
            tags$link(rel = "shortcut icon", type = "image/png", href = "favicon.png"),
            tags$script(src = "www/redirect.js"),
            includeCSS("css/styles.css"),
            # Automatically display a loading screen until UI is ready
            autoWaiter()
        ),

        # Application title
        title = list(
            icon("spotify", lib = "font-awesome"),
            "TrackTeller"
        ),
        id = "main_navbar",

            # Top Artists tab - landing page with inline auth
            nav_panel(
                title = "Top Artists",
                value = "top_artists",

                # Hidden inputs to pass OAuth data to server
                tags$input(type = "hidden", id = "oauth_code", value = if (has_code) query$code else ""),
                tags$input(type = "hidden", id = "oauth_state", value = if (has_code) query$state else ""),
                tags$input(type = "hidden", id = "oauth_error", value = if (has_error) query$error else ""),

                layout_sidebar(
                    sidebar = sidebar(
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
                            p(
                                class = "text-muted small",
                                "Don't have access yet? ",
                                tags$a(
                                    href = "https://forms.gle/cXwoNNVhmfZfWchj6",
                                    target = "_blank",
                                    "Request access here."
                                )
                            ),
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
                            downloadButton("download_stats_card", "Share My Stats",
                                         icon = icon("share-nodes"),
                                         class = "btn-outline-secondary btn-sm w-100"),
                            br(),
                            hr(),
                            div(
                                style = "display: flex; align-items: center; gap: 10px;",
                                textOutput("user_display_name"),
                                actionButton("refresh_data", NULL,
                                           icon = icon("rotate-right"),
                                           class = "btn-outline-secondary btn-sm",
                                           title = "Refresh data"),
                                actionButton("logout_btn", "Logout",
                                           class = "btn-outline-secondary btn-sm")
                            )
                        )
                    ),
                    # Show welcome message when not authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == false",
                        div(
                            class = "d-flex flex-column align-items-center justify-content-center",
                            style = "min-height: 400px; padding: 40px 20px;",
                            h2("Discover Your Music DNA", class = "mb-4", style = "color: #1DB954;"),
                            p(class = "text-center mb-5",
                              style = "font-size: 1.1em; max-width: 600px;",
                              "See your top artists, favorite tracks, genre breakdown, ",
                              "and create custom playlists based on your listening history."),
                            div(
                                class = "d-flex justify-content-center gap-5 flex-wrap",
                                div(class = "text-center",
                                    icon("users", class = "fa-3x mb-3", style = "color: #1DB954;"),
                                    p(class = "mb-0", "Top Artists")),
                                div(class = "text-center",
                                    icon("music", class = "fa-3x mb-3", style = "color: #1DB954;"),
                                    p(class = "mb-0", "Top Tracks")),
                                div(class = "text-center",
                                    icon("chart-bar", class = "fa-3x mb-3", style = "color: #1DB954;"),
                                    p(class = "mb-0", "Genre Stats")),
                                div(class = "text-center",
                                    icon("list", class = "fa-3x mb-3", style = "color: #1DB954;"),
                                    p(class = "mb-0", "Playlists"))
                            )
                        )
                    ),
                    # Show artist list when authenticated
                    conditionalPanel(
                        condition = "output.is_authenticated == true",
                        uiOutput("top_artists_list"),
                        div(
                            style = "margin-top: 16px;",
                            actionButton("create_playlist_artists", "Create Playlist from Top Artists",
                                       class = "btn-success", icon = icon("music"))
                        ),
                        div(style = "height: 40px;")
                    )
                )
            ),

            # Top Tracks tab
            nav_panel(
                title = "Top Tracks",
                value = "top_tracks",
                layout_sidebar(
                    sidebar = sidebar(
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
                    uiOutput("top_tracks_list"),
                    div(
                        style = "margin-top: 16px;",
                        actionButton("create_playlist_tracks", "Create Playlist from Top Tracks",
                                   class = "btn-success", icon = icon("music"))
                    ),
                    div(style = "height: 40px;")
                )
            ),

            # Recently Played tab
            nav_panel(
                title = "Recently Played",
                value = "recently_played",
                layout_sidebar(
                    sidebar = sidebar(
                        h3("Recently Played"),
                        br(),
                        p("Your most recently played tracks."),
                        br(),
                        sliderInput(
                            "recent_tracks_display_count",
                            "Number of tracks to show:",
                            min = 10,
                            max = 50,
                            value = 20,
                            step = 5
                        )
                    ),
                    uiOutput("recently_played_list"),
                    div(
                        style = "margin-top: 16px;",
                        actionButton("create_playlist_recent", "Create Playlist from Recently Played",
                                   class = "btn-success", icon = icon("music"))
                    ),
                    div(style = "height: 40px;")
                )
            ),

            # Top Genres tab
            nav_panel(
                title = "Top Genres",
                value = "top_genres",
                layout_sidebar(
                    sidebar = sidebar(
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
                    plotlyOutput("genre_plot", height = 700),
                    div(style = "height: 40px;")
                )
            ),

            # My Playlists tab
            nav_panel(
                title = "My Playlists",
                value = "my_playlists",
                layout_sidebar(
                    sidebar = sidebar(
                        h3("Your Playlists"),
                        br(),
                        p("Browse all your Spotify playlists, filtered by first letter."),
                        br(),
                        selectInput(
                            "playlist_letter",
                            "Filter by first letter:",
                            choices = c("Loading..." = ""),
                            selected = ""
                        )
                    ),
                    uiOutput("user_playlists_list"),
                    div(style = "height: 40px;")
                )
            ),

        # Add footer with cross-linking
        footer = create_app_footer("trackteller")
    )
}
