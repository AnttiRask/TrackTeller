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
source("scripts/spotify_api.R", local = TRUE)
source("scripts/display.R", local = TRUE)
source("scripts/charts.R", local = TRUE)
source("scripts/dialogs.R", local = TRUE)
source("scripts/playlists.R", local = TRUE)
source("scripts/playlists_module.R", local = TRUE)

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
                    if(current_app != "fillaristatus")
                        a(href = "https://fillaristatus.youcanbeapirate.com", "FillariStatus"),
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

        header = tagList(
            tags$head(
                tags$link(rel = "icon", type = "image/png", href = "www/favicon.png"),
                tags$script(src = "www/redirect.js"),
                tags$script(src = "www/preferences.js"),
                tags$script(src = "www/tabs.js"),
                includeCSS("css/styles.css"),
                # Automatically display a loading screen until UI is ready
                autoWaiter()
            ),

            # Shared choices: the same on every tab, and remembered between visits.
            # Shown only when logged in, and not on My Playlists (nothing to choose there).
            conditionalPanel(
                condition = "output.is_authenticated == true && input.main_navbar != 'my_playlists'",
                div(
                    class = "shared-controls",
                    conditionalPanel(
                        condition = "input.main_navbar != 'recently_played'",
                        selectInput(
                            "time_range",
                            "Time range:",
                            choices = TIME_RANGES,
                            selected = "short_term",
                            selectize = FALSE,
                            width = "220px"
                        )
                    ),
                    # Recently Played has no time range; the field stays so that the bar
                    # doesn't change shape from tab to tab
                    conditionalPanel(
                        condition = "input.main_navbar == 'recently_played'",
                        div(
                            class = "form-group shiny-input-container",
                            style = "width: 220px;",
                            tags$label(class = "control-label", `for` = "time_range_recent", "Time range:"),
                            tags$select(id = "time_range_recent", class = "form-select", disabled = NA,
                                        tags$option("Recently Played"))
                        )
                    ),
                    sliderInput(
                        "shown_count",
                        "Number to show:",
                        min = COUNT_MIN,
                        max = COUNT_MAX,
                        value = COUNT_DEFAULT,
                        step = COUNT_STEP,
                        ticks = FALSE,
                        width = "260px"
                    ),
                    p(class = "text-muted small shared-controls-note",
                      "Spotify only provides three time ranges. Your choices are remembered in this browser.")
                )
            )
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
                        width = 350,
                        # Show auth controls when not authenticated
                        conditionalPanel(
                            condition = "output.is_authenticated == false",
                            h3("Welcome to TrackTeller"),
                            br(),
                            p("Discover insights about your Spotify listening habits."),
                            br(),
                            p("Log in to see your top artists, tracks, genres, and create playlists."),
                            br(),
                            actionButton("login_btn", "Log in with Spotify",
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
                            div(
                                class = "d-grid gap-2 sidebar-actions",
                                downloadButton("download_artists_card", "Share Top Artists",
                                             icon = icon("share-nodes"),
                                             class = "btn-success",
                                             style = "color: #000;"),
                                actionButton("create_playlist_artists", "Create Playlist from Top Artists",
                                           class = "btn-success", icon = icon("music"))
                            )
                        ),

                        create_app_footer("trackteller")
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
                        uiOutput("top_artists_note"),
                        uiOutput("top_artists_list"),
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
                        width = 350,
                        h3("Your Top Tracks"),
                        br(),
                        p("Your most played tracks, ranked by listening frequency."),
                        div(
                            class = "d-grid gap-2 sidebar-actions",
                            downloadButton("download_tracks_card", "Share Top Tracks",
                                         icon = icon("share-nodes"),
                                         class = "btn-success",
                                         style = "color: #000;"),
                            actionButton("create_playlist_tracks", "Create Playlist from Top Tracks",
                                       class = "btn-success", icon = icon("music"))
                        ),
                        create_app_footer("trackteller")
                    ),
                    uiOutput("top_tracks_note"),
                    uiOutput("top_tracks_list"),
                    div(style = "height: 40px;")
                )
            ),

            # Recently Played tab
            nav_panel(
                title = "Recently Played",
                value = "recently_played",
                layout_sidebar(
                    sidebar = sidebar(
                        width = 350,
                        h3("Recently Played"),
                        br(),
                        p("Your most recently played tracks."),
                        div(
                            class = "d-grid gap-2 sidebar-actions",
                            actionButton("create_playlist_recent", "Create Playlist from Recently Played",
                                       class = "btn-success", icon = icon("music"))
                        ),
                        create_app_footer("trackteller")
                    ),
                    uiOutput("recently_played_note"),
                    uiOutput("recently_played_list"),
                    div(style = "height: 40px;")
                )
            ),

            # Top Genres tab
            nav_panel(
                title = "Top Genres",
                value = "top_genres",
                layout_sidebar(
                    sidebar = sidebar(
                        width = 350,
                        h3("Your Top Genres"),
                        br(),
                        p("Genre distribution across your top artists."),
                        create_app_footer("trackteller")
                    ),
                    uiOutput("genre_note"),
                    uiOutput("genre_plot_ui"),
                    div(style = "height: 40px;")
                )
            ),

            # My Playlists tab (see scripts/playlists_module.R)
            nav_panel(
                title = "My Playlists",
                value = "my_playlists",
                playlists_ui("playlists")
            ),

            nav_spacer(),
            nav_item(uiOutput("account_ui"))
    )
}
