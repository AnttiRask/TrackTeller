# Load necessary packages
library(conflicted)
library(dplyr)
library(ggplot2)
library(magick)
library(plotly)
library(purrr)
library(stringr)
library(tidyr)
library(waiter)

# Define the server function
server <- function(input, output, session) {

    # Define the preferred functions to avoid namespace clashes
    conflict_prefer("filter", "dplyr")
    conflict_prefer("validate", "shiny")

    # Load helper scripts
    source("scripts/config.R", local = TRUE)
    source("scripts/spotify_oauth.R", local = TRUE)
    source("scripts/global.R", local = TRUE)

    # Reactive value to store token info
    token_info <- reactiveVal(NULL)

    # Store display name for stats card download
    user_display_name_val <- reactiveVal("")

    # Reactive value for authentication state
    is_authenticated <- reactive({
        !is.null(token_info()) && !is.null(token_info()$access_token)
    })

    # The message under the login button (login failed, session expired, logged out).
    # Defined once; the observers only change the value. (An output defined inside an
    # observer is thrown away when that observer re-runs, which is what happens right
    # after the address is cleared.)
    auth_message <- reactiveVal(NULL)

    set_auth_message <- function(class, icon_name, text) {
        auth_message(list(class = class, icon = icon_name, text = text))
    }

    output$auth_status <- renderUI({
        msg <- auth_message()
        req(msg)
        div(class = msg$class, icon(msg$icon), paste0(" ", msg$text))
    })
    # These two sit in panels that start hidden (the login or the logged-in view), and
    # Shiny doesn't compute outputs it thinks are hidden: always compute them
    outputOptions(output, "auth_status", suspendWhenHidden = FALSE)

    # Output for conditional panel
    output$is_authenticated <- reactive({
        is_authenticated()
    })
    outputOptions(output, "is_authenticated", suspendWhenHidden = FALSE)

    # Handle OAuth callback on session start
    observe({
        # Get the OAuth code from the address (set by Spotify's redirect)
        query <- parseQueryString(session$clientData$url_search)

        if (!is.null(query$code) && is.null(isolate(token_info()))) {
            result <- spotify_exchange_code(
                code = query$code,
                client_id = SPOTIFY_CLIENT_ID,
                client_secret = SPOTIFY_CLIENT_SECRET,
                redirect_uri = REDIRECT_URI
            )

            # The code can only be used once: clear it from the address either way
            updateQueryString("?", mode = "replace")

            if (result$state == "ok") {
                token_info(result$token)

                set_auth_message("text-success", "check-circle", "Successfully logged in!")
            } else {
                set_auth_message("text-danger", "exclamation-triangle",
                                 paste("Authentication failed:", result$message))
            }
        }

        # Handle OAuth error
        if (!is.null(query$error)) {
            set_auth_message("text-danger", "exclamation-triangle",
                             paste("Spotify authorization denied:", query$error))
        }
    })

    # Handle login button click
    observeEvent(input$login_btn, {
        auth_info <- spotify_authorize_url(
            client_id = SPOTIFY_CLIENT_ID,
            redirect_uri = REDIRECT_URI,
            scope = SPOTIFY_SCOPES
        )

        # Store state for verification (optional, for added security)
        session$userData$oauth_state <- auth_info$state

        # Redirect to Spotify
        session$sendCustomMessage("redirect", auth_info$url)
    })

    # Handle logout button click
    observeEvent(input$logout_btn, {
        token_info(NULL)
        user_display_name_val("")
        set_auth_message("text-info", "info-circle", "You have been logged out.")
    })

    # The login ended (expired or revoked): forget the token, say so on the login view
    end_session <- function() {
        token_info(NULL)
        set_auth_message("text-warning", "exclamation-triangle", "Session expired. Please login again.")
    }

    # A valid access token for the current login, renewed when it is about to
    # expire. NULL when nobody is logged in, or when the login could not be renewed.
    # A plain function, not a reactive: reading the token must not make the data
    # reactives re-run every time it is renewed.
    current_token <- function(force_refresh = FALSE) {
        tok <- isolate(token_info())
        if (is.null(tok)) return(NULL)

        if (force_refresh || token_is_expired(tok)) {
            result <- spotify_refresh_token(
                refresh_token = tok$refresh_token,
                client_id = SPOTIFY_CLIENT_ID,
                client_secret = SPOTIFY_CLIENT_SECRET
            )
            if (result$state == "reauth") {
                end_session()
                return(NULL)
            }
            if (result$state != "ok") {
                showNotification(result$message, type = "error", duration = 10)
                return(NULL)
            }
            token_info(result$token)
            tok <- result$token
        }

        tok$access_token
    }

    # Run one Spotify call with the current token. `call` is function(token) that
    # returns a result from spotify_get() / spotify_post(). If Spotify says the
    # token is no longer valid, renew it once and try again.
    api_request <- function(call) {
        token <- current_token()
        if (is.null(token)) {
            state <- if (is.null(isolate(token_info()))) "reauth" else "error"
            return(list(state = state, data = NULL, http_status = NA_integer_,
                        message = spotify_messages[[state]]))
        }

        res <- call(token)

        if (res$state == "reauth") {
            token <- current_token(force_refresh = TRUE)
            if (!is.null(token)) res <- call(token)
            if (res$state == "reauth") end_session()
        }
        res
    }

    api_get <- function(path, query = list()) {
        api_request(function(token) spotify_get(path, token, query))
    }

    # Inside a reactive or output: stop with Spotify's message in place of the data
    # when the call failed (nothing is shown when the login ended; the page then
    # switches to the login view)
    stop_if_failed <- function(res) {
        if (res$state == "reauth") req(FALSE)
        validate(need(res$state == "ok", res$message))
    }

    # Top right of the navbar: who is signed in, and the Logout button
    output$account_ui <- renderUI({
        req(is_authenticated())
        name <- user_display_name_val()
        div(
            class = "account-box",
            span(class = "account-name",
                 icon("circle-user"),
                 if (nzchar(name)) paste("Signed in as", name) else "Signed in"),
            actionButton("logout_btn", "Logout", class = "btn-outline-secondary btn-sm")
        )
    })

    # Get user profile to display
    observe({
        req(is_authenticated())
        res <- api_get("/me")

        if (res$state == "ok") {
            user_display_name_val(res$data$display_name %||% "")
            # Store user ID for playlist creation
            session$userData$user_id <- res$data$id
        }
    })

    # ============================================
    # SHARED CHOICES (the bar above the tabs)
    # ============================================

    time_range  <- reactive(input$time_range %||% "short_term")
    shown_count <- reactive(input$shown_count %||% COUNT_DEFAULT)

    # A value, or NULL when computing it fails or is not ready (the note under a list
    # must not repeat the list's own error message)
    quiet <- function(value) tryCatch(value, error = function(e) NULL)

    # What the browser remembered from the last visit (www/preferences.js sends it once
    # per session). The data waits until the remembered time range is in place, so that
    # a visit with a saved range doesn't fetch the default range first.
    prefs_ready <- reactiveVal(FALSE)
    saved_time_range <- reactiveVal(NULL)

    observeEvent(input$saved_prefs, {
        prefs <- sanitise_prefs(input$saved_prefs)

        if (is.null(prefs$time_range)) {
            prefs_ready(TRUE)
        } else {
            updateSelectInput(session, "time_range", selected = prefs$time_range)
            saved_time_range(prefs$time_range)
        }
        if (!is.null(prefs$shown_count)) {
            updateSliderInput(session, "shown_count", value = prefs$shown_count)
        }

        # From now on the browser may save what the user changes
        session$sendCustomMessage("prefs_applied", TRUE)
    }, once = TRUE)

    observe({
        wanted <- saved_time_range()
        req(wanted)
        if (isolate(prefs_ready())) return()
        if (identical(input$time_range, wanted)) prefs_ready(TRUE)
    })

    # If the browser never reports (scripts blocked), don't wait for it for long
    prefs_waits <- reactiveVal(0L)
    observe({
        if (isolate(prefs_ready())) return()
        invalidateLater(1500, session)
        waited <- isolate(prefs_waits())
        prefs_waits(waited + 1L)
        if (waited >= 1L) prefs_ready(TRUE)
    })

    # ============================================
    # TOP ARTISTS TAB
    # ============================================

    # Fetch ALL top artists (up to 50) based on time range
    all_top_artists_data <- reactive({
        req(is_authenticated(), prefs_ready())

        res <- api_get("/me/top/artists",
                       list(limit = 50, time_range = time_range()))
        stop_if_failed(res)

        parse_top_artists(res$data)
    })

    # The first `shown_count` of them (or all there are)
    top_artists_data <- reactive({
        data <- all_top_artists_data()
        req(data)

        head(data, displayed_count(shown_count(), nrow(data)))
    })

    output$top_artists_note <- renderUI({
        data <- quiet(all_top_artists_data())
        note <- count_note(shown_count(), if (is.null(data)) NULL else nrow(data), "artist", "artists")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    # Top artists list with cards
    output$top_artists_list <- renderUI({
        req(top_artists_data())
        data <- top_artists_data()

        validate(need(nrow(data) > 0, "No top artists found. Listen to more music on Spotify!"))

        # Create a list of artist cards
        artist_cards <- lapply(seq_len(nrow(data)), function(i) {
            artist <- data[i, ]
            tags$div(
                class = "artist-card",
                style = paste0(
                    "display: flex; align-items: center; padding: 12px; ",
                    "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
                    "transition: background 0.2s; cursor: default;"
                ),
                # Rank number
                tags$div(
                    style = "color: #1DB954; font-size: 1.4em; font-weight: bold; width: 40px; text-align: center;",
                    paste0("#", artist$rank)
                ),
                # Artist info
                tags$div(
                    style = "flex: 1; margin-left: 15px;",
                    tags$div(
                        style = "color: #fff; font-size: 1.1em; font-weight: 500;",
                        artist$name
                    ),
                    tags$div(
                        style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;",
                        if (nchar(artist$genres) > 0) to_title_case(artist$genres) else "No genres listed"
                    )
                ),
                # Stats
                tags$div(
                    style = "text-align: right; color: #b3b3b3; font-size: 0.85em;",
                    if (!is.na(artist$popularity)) tags$div(
                        style = "color: #1DB954;",
                        paste0("Popularity: ", artist$popularity)
                    ),
                    if (!is.na(artist$followers)) tags$div(
                        paste0(format(artist$followers, big.mark = ","), " followers")
                    )
                ),
                # Spotify link button
                tags$a(
                    href = artist$spotify_url,
                    target = "_blank",
                    style = paste0(
                        "margin-left: 15px; padding: 8px 12px; ",
                        "background: #1DB954; color: #fff; border-radius: 20px; ",
                        "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                        "display: flex; align-items: center; gap: 5px;"
                    ),
                    icon("spotify"),
                    "Open"
                )
            )
        })

        tags$div(
            style = "padding-right: 10px;",
            artist_cards
        )
    })

    # ============================================
    # TOP TRACKS TAB
    # ============================================

    # Fetch ALL top tracks (up to 50) based on time range
    all_top_tracks_data <- reactive({
        req(is_authenticated(), prefs_ready())

        res <- api_get("/me/top/tracks",
                       list(limit = 50, time_range = time_range()))
        stop_if_failed(res)

        parse_top_tracks(res$data)
    })

    # The first `shown_count` of them (or all there are)
    top_tracks_data <- reactive({
        data <- all_top_tracks_data()
        req(data)

        head(data, displayed_count(shown_count(), nrow(data)))
    })

    output$top_tracks_note <- renderUI({
        data <- quiet(all_top_tracks_data())
        note <- count_note(shown_count(), if (is.null(data)) NULL else nrow(data), "track", "tracks")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    # Top tracks list with cards
    output$top_tracks_list <- renderUI({
        req(top_tracks_data())
        data <- top_tracks_data()

        validate(need(nrow(data) > 0, "No top tracks found. Listen to more music on Spotify!"))

        # Create a list of track cards
        track_cards <- lapply(seq_len(nrow(data)), function(i) {
            track <- data[i, ]
            duration_formatted <- format_duration(track$duration_ms)

            tags$div(
                class = "track-card",
                style = paste0(
                    "display: flex; align-items: center; padding: 12px; ",
                    "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
                    "transition: background 0.2s; cursor: default;"
                ),
                # Rank number
                tags$div(
                    style = "color: #1DB954; font-size: 1.4em; font-weight: bold; width: 40px; text-align: center;",
                    paste0("#", track$rank)
                ),
                # Track info
                tags$div(
                    style = "flex: 1; margin-left: 15px;",
                    tags$div(
                        style = "color: #fff; font-size: 1.1em; font-weight: 500;",
                        track$name
                    ),
                    tags$div(
                        style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;",
                        track$artist
                    ),
                    tags$div(
                        style = "color: #666; font-size: 0.85em; margin-top: 2px;",
                        track$album
                    )
                ),
                # Stats
                tags$div(
                    style = "text-align: right; color: #b3b3b3; font-size: 0.85em;",
                    if (!is.na(track$popularity)) tags$div(
                        style = "color: #1DB954;",
                        paste0("Popularity: ", track$popularity)
                    ),
                    tags$div(
                        duration_formatted
                    )
                ),
                # Spotify link button
                tags$a(
                    href = track$spotify_url,
                    target = "_blank",
                    style = paste0(
                        "margin-left: 15px; padding: 8px 12px; ",
                        "background: #1DB954; color: #fff; border-radius: 20px; ",
                        "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                        "display: flex; align-items: center; gap: 5px;"
                    ),
                    icon("spotify"),
                    "Open"
                )
            )
        })

        tags$div(
            style = "padding-right: 10px;",
            track_cards
        )
    })

    # ============================================
    # RECENTLY PLAYED TAB
    # ============================================

    # Fetched once (the last 50); the slider only slices what is already loaded
    recently_played_all <- reactive({
        req(is_authenticated(), prefs_ready())

        res <- api_get("/me/player/recently-played", list(limit = 50))
        stop_if_failed(res)

        parse_recent_tracks(res$data, count = 50)
    })

    recently_played_data <- reactive({
        tracks <- recently_played_all()
        if (is.null(tracks)) return(NULL)

        head(tracks, displayed_count(shown_count(), nrow(tracks)))
    })

    output$recently_played_note <- renderUI({
        tracks <- quiet(recently_played_all())
        note <- count_note(shown_count(), if (is.null(tracks)) NULL else nrow(tracks), "track", "tracks")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    output$recently_played_list <- renderUI({
        data <- recently_played_data()
        validate(need(!is.null(data) && nrow(data) > 0,
                      "No recently played tracks found. Play some music on Spotify first!"))

        track_cards <- lapply(seq_len(nrow(data)), function(i) {
            track <- data[i, ]
            tags$div(
                class = "track-card",
                style = paste0(
                    "display: flex; align-items: center; padding: 12px; ",
                    "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
                    "transition: background 0.2s; cursor: default;"
                ),
                tags$div(
                    style = "color: #1DB954; font-size: 1.4em; font-weight: bold; width: 40px; text-align: center;",
                    paste0("#", i)
                ),
                tags$div(
                    style = "flex: 1; margin-left: 15px;",
                    tags$div(style = "color: #fff; font-size: 1.1em; font-weight: 500;", track$name),
                    tags$div(style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;", track$artist),
                    tags$div(style = "color: #666; font-size: 0.85em; margin-top: 2px;", track$album)
                ),
                tags$a(
                    href = track$spotify_url,
                    target = "_blank",
                    style = paste0(
                        "margin-left: 15px; padding: 8px 12px; ",
                        "background: #1DB954; color: #fff; border-radius: 20px; ",
                        "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                        "display: flex; align-items: center; gap: 5px;"
                    ),
                    icon("spotify"),
                    "Open"
                )
            )
        })

        tags$div(
            style = "padding-right: 10px;",
            track_cards
        )
    })

    # ============================================
    # GENRE DISTRIBUTION TAB
    # ============================================

    # Fetch top artists for genre analysis
    genre_data <- reactive({
        req(is_authenticated(), prefs_ready())

        res <- api_get("/me/top/artists",
                       list(limit = 50, time_range = time_range()))
        stop_if_failed(res)

        summarise_genres(res$data)
    })

    output$genre_note <- renderUI({
        data <- quiet(genre_data())
        note <- count_note(shown_count(), if (is.null(data)) NULL else nrow(data),
                           "genre", "genres", cap = GENRE_CHART_MAX)
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    # The chart sits in a plain container whose height follows the number of bars. Placed
    # directly in the page's fill layout the plot would be squeezed into whatever height
    # is left (and 20 bars need room for their labels).
    output$genre_plot_ui <- renderUI({
        data <- quiet(genre_data())
        n <- if (is.null(data)) 0L else displayed_count(shown_count(), nrow(data), cap = GENRE_CHART_MAX)
        plotlyOutput("genre_plot", height = paste0(genre_chart_height(n), "px"))
    })

    # Genre distribution plot - green bars, title case
    output$genre_plot <- renderPlotly({
        req(genre_data())
        data <- genre_data()

        validate(need(nrow(data) > 0, "No genre data available."))

        # Take the top N genres (never more than the chart can show)
        top_count <- displayed_count(shown_count(), nrow(data), cap = GENRE_CHART_MAX)
        genre_chart(head(data, top_count))
    })

    # ============================================
    # MY PLAYLISTS TAB
    # ============================================

    # Incremental playlist loading state
    all_playlists_data <- reactiveVal(NULL)
    playlists_loading <- reactiveVal(FALSE)
    playlists_offset <- reactiveVal(0)
    playlists_done <- reactiveVal(FALSE)

    # Start loading when My Playlists tab is opened
    observeEvent(input$main_navbar, {
        if (input$main_navbar == "my_playlists" &&
            is.null(all_playlists_data()) &&
            !playlists_loading()) {
            playlists_loading(TRUE)
            playlists_offset(0)
            playlists_done(FALSE)
        }
    })

    # Load one batch at a time, yielding between batches for UI updates
    observe({
        req(playlists_loading())
        req(!playlists_done())
        req(is_authenticated())

        offset <- playlists_offset()
        batch_size <- 50

        res <- api_get("/me/playlists", list(limit = batch_size, offset = offset))

        if (res$state != "ok") {
            if (res$state != "reauth") {
                showNotification(res$message, type = "error", duration = 10)
            }
            playlists_loading(FALSE)
            return()
        }

        items <- res$data$items

        if (length(items) > 0) {
            batch <- parse_playlists_page(items)

            # Append to existing data and sort
            current <- all_playlists_data()
            updated <- if (is.null(current)) batch else bind_rows(current, batch)
            updated <- updated %>% arrange(tolower(name))
            all_playlists_data(updated)
        }

        if (length(items) < batch_size) {
            # All done
            playlists_done(TRUE)
            playlists_loading(FALSE)
        } else {
            # More to fetch - schedule next batch
            playlists_offset(offset + batch_size)
            invalidateLater(100)
        }
    })

    # Update letter filter choices based on available playlists
    observe({
        data <- all_playlists_data()
        req(data)

        # Get first character of each playlist name
        first_chars <- toupper(substr(data$name, 1, 1))

        # Build available choices: "#" for non-alpha, then A-Z
        available <- character(0)

        has_non_alpha <- any(!grepl("^[A-Za-z]", first_chars))
        if (has_non_alpha) available <- c(available, "#" = "#")

        for (letter in LETTERS) {
            if (any(first_chars == letter)) {
                available <- c(available, setNames(letter, letter))
            }
        }

        # Keep current selection if still valid, otherwise first available
        current <- input$playlist_letter
        selected <- if (!is.null(current) && current %in% available) current else available[[1]]

        updateSelectInput(session, "playlist_letter",
            choices = available,
            selected = selected
        )
    })

    # Filter playlists by selected letter
    filtered_playlists_data <- reactive({
        data <- all_playlists_data()
        req(data)

        letter <- input$playlist_letter
        if (is.null(letter) || length(letter) == 0 || letter == "") return(head(data, 0))

        if (letter == "#") {
            data %>% filter(!grepl("^[A-Za-z]", name))
        } else {
            data %>% filter(toupper(substr(name, 1, 1)) == letter)
        }
    })

    # Render user's playlists
    output$user_playlists_list <- renderUI({
        loading <- playlists_loading()
        all_data <- all_playlists_data()

        # Show spinner if loading hasn't produced any data yet
        if (loading && is.null(all_data)) {
            return(tags$div(
                style = "text-align: center; padding: 40px; color: #b3b3b3;",
                tags$div(
                    style = "display: inline-block; width: 30px; height: 30px; border: 3px solid #333; border-top-color: #1DB954; border-radius: 50%; animation: spin 1s linear infinite;",
                ),
                tags$style("@keyframes spin { to { transform: rotate(360deg); } }"),
                tags$p(style = "margin-top: 15px;", "Loading playlists...")
            ))
        }

        req(all_data)
        data <- filtered_playlists_data()

        validate(need(nrow(data) > 0, "No playlists found for this letter."))

        total_count <- nrow(all_data)
        filtered_count <- nrow(data)
        still_loading <- loading

        # Create a list of playlist cards
        playlist_cards <- lapply(seq_len(nrow(data)), function(i) {
            playlist <- data[i, ]
            tags$div(
                class = "playlist-card",
                style = paste0(
                    "display: flex; align-items: center; padding: 12px; ",
                    "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
                    "transition: background 0.2s; cursor: default;"
                ),
                # Playlist image (if available)
                if (!is.na(playlist$image_url)) {
                    tags$img(
                        src = playlist$image_url,
                        style = "width: 50px; height: 50px; border-radius: 4px; object-fit: cover;"
                    )
                } else {
                    tags$div(
                        style = "width: 50px; height: 50px; border-radius: 4px; background: #333; display: flex; align-items: center; justify-content: center;",
                        icon("music", style = "color: #666;")
                    )
                },
                # Playlist info
                tags$div(
                    style = "flex: 1; margin-left: 15px;",
                    tags$div(
                        style = "color: #fff; font-size: 1.1em; font-weight: 500;",
                        playlist$name
                    ),
                    tags$div(
                        style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;",
                        paste0("By ", playlist$owner)
                    )
                ),
                # Stats
                tags$div(
                    style = "text-align: right; color: #b3b3b3; font-size: 0.85em;",
                    tags$div(
                        style = "color: #1DB954;",
                        paste0(playlist$track_count, " tracks")
                    ),
                    tags$div(
                        if (playlist$is_public) "Public" else "Private"
                    )
                ),
                # Spotify link button
                tags$a(
                    href = playlist$spotify_url,
                    target = "_blank",
                    style = paste0(
                        "margin-left: 15px; padding: 8px 12px; ",
                        "background: #1DB954; color: #fff; border-radius: 20px; ",
                        "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                        "display: flex; align-items: center; gap: 5px;"
                    ),
                    icon("spotify"),
                    "Open"
                )
            )
        })

        loading_banner <- if (still_loading) {
            tags$div(
                style = paste0(
                    "display: flex; align-items: center; gap: 10px; padding: 10px 15px; ",
                    "margin-bottom: 12px; background: #1a3a2a; border: 1px solid #1DB954; ",
                    "border-radius: 8px; color: #1DB954;"
                ),
                tags$div(
                    style = "width: 16px; height: 16px; border: 2px solid #1a3a2a; border-top-color: #1DB954; border-radius: 50%; animation: spin 1s linear infinite; flex-shrink: 0;",
                ),
                tags$style("@keyframes spin { to { transform: rotate(360deg); } }"),
                tags$span(paste0("Loading playlists... ", total_count, " found so far. You can already browse below."))
            )
        }

        status_text <- paste0("Showing ", filtered_count, " of ", total_count, " playlists")

        tags$div(
            loading_banner,
            tags$p(
                style = "color: #b3b3b3; margin-bottom: 10px;",
                status_text
            ),
            tags$div(
                style = "padding-right: 10px;",
                playlist_cards
            )
        )
    })

    # ============================================
    # SHAREABLE STATS CARDS
    # ============================================

    # Download an image from a URL and resize it; returns a blank placeholder on failure
    fetch_card_image <- function(url, size = 70) {
        tryCatch({
            if (!is.na(url) && nzchar(url)) {
                art <- image_read(url)
                image_scale(art, paste0(size, "x", size, "!"))
            } else {
                image_blank(size, size, color = "#282828")
            }
        }, error = function(e) {
            image_blank(size, size, color = "#282828")
        })
    }

    # Truncate a string to max_chars with ".." suffix if needed
    trunc_str <- function(s, max_chars = 32) {
        if (nchar(s) > max_chars) paste0(substr(s, 1, max_chars - 2), "..") else s
    }

    # Build a 1200x630 stats card using magick
    # type = "artists" or "tracks"
    build_stats_card <- function(data, username, time_label, type) {
        W <- 1200L; H <- 630L

        img <- image_blank(W, H, color = "#191414")

        # ---- Header ----
        title_text <- if (nzchar(username)) {
            paste0(username, "\u2019s Top ", if (type == "artists") "Artists" else "Tracks")
        } else {
            paste0("My Top ", if (type == "artists") "Artists" else "Tracks")
        }

        img <- image_annotate(img, title_text,
            size = 38, color = "#1DB954", font = "Liberation Sans",
            weight = 700, gravity = "NorthWest", location = "+40+18"
        )
        img <- image_annotate(img, time_label,
            size = 22, color = "#b3b3b3", font = "Liberation Sans",
            gravity = "NorthWest", location = "+40+65"
        )

        # Header separator
        hline <- image_blank(1120L, 2L, color = "#2d2d2d")
        img <- image_composite(img, hline, offset = "+40+97")

        # Vertical column separator
        vline <- image_blank(2L, 470L, color = "#2d2d2d")
        img <- image_composite(img, vline, offset = "+600+103")

        # ---- Layout constants ----
        img_size    <- 70L
        row_h       <- 90L
        start_y     <- 108L
        left_img_x  <- 40L
        left_txt_x  <- 122L   # left_img_x + img_size + 12
        right_img_x <- 622L
        right_txt_x <- 704L   # right_img_x + img_size + 12

        top10 <- head(data, 10)

        for (i in seq_len(nrow(top10))) {
            col    <- if (i <= 5L) 1L else 2L
            row    <- if (i <= 5L) i  else i - 5L
            x_img  <- if (col == 1L) left_img_x  else right_img_x
            x_txt  <- if (col == 1L) left_txt_x  else right_txt_x
            y_base <- start_y + (row - 1L) * row_h

            # Subtle row background (alternating)
            if (row %% 2L == 0L) {
                row_bg <- image_blank(550L, row_h - 4L, color = "#1d1d1d")
                img <- image_composite(img, row_bg, offset = paste0("+", x_img - 4L, "+", y_base + 4L))
            }

            # Image (artist photo or album art)
            img_url <- if (type == "artists") top10$image_url[i] else top10$album_image_url[i]
            art_img <- fetch_card_image(img_url, img_size)
            img <- image_composite(img, art_img, offset = paste0("+", x_img, "+", y_base + 10L))

            if (type == "artists") {
                # Single text line: rank + name
                img <- image_annotate(img, paste0("#", i),
                    size = 18L, color = "#1DB954", font = "Liberation Sans",
                    weight = 700L, gravity = "NorthWest",
                    location = paste0("+", x_txt, "+", y_base + 30L)
                )
                name <- trunc_str(top10$name[i], 30L)
                img <- image_annotate(img, name,
                    size = 22L, color = "#FFFFFF", font = "Liberation Sans",
                    gravity = "NorthWest",
                    location = paste0("+", x_txt + 48L, "+", y_base + 28L)
                )
            } else {
                # Two text lines: rank + track name, then artist
                img <- image_annotate(img, paste0("#", i),
                    size = 18L, color = "#1DB954", font = "Liberation Sans",
                    weight = 700L, gravity = "NorthWest",
                    location = paste0("+", x_txt, "+", y_base + 22L)
                )
                tname <- trunc_str(top10$name[i], 26L)
                img <- image_annotate(img, tname,
                    size = 20L, color = "#FFFFFF", font = "Liberation Sans",
                    gravity = "NorthWest",
                    location = paste0("+", x_txt + 48L, "+", y_base + 18L)
                )
                aname <- trunc_str(top10$artist[i], 26L)
                img <- image_annotate(img, aname,
                    size = 17L, color = "#b3b3b3", font = "Liberation Sans",
                    gravity = "NorthWest",
                    location = paste0("+", x_txt + 48L, "+", y_base + 46L)
                )
            }
        }

        # ---- Footer ----
        img <- image_annotate(img, "trackteller.youcanbeapirate.com",
            size = 18L, color = "#555555", font = "Liberation Sans",
            gravity = "South", location = "+0+18"
        )

        img
    }

    output$download_artists_card <- downloadHandler(
        filename = function() paste0("top-artists-", Sys.Date(), ".png"),
        content = function(file) {
            artists <- isolate(all_top_artists_data())
            username <- isolate(user_display_name_val())
            time_label <- switch(isolate(input$time_range),
                "short_term"  = "Last 4 Weeks",
                "medium_term" = "Last 6 Months",
                "long_term"   = "All Time",
                "All Time"
            )

            if (is.null(artists) || nrow(artists) == 0) {
                img <- image_blank(1200L, 630L, color = "#191414")
                img <- image_annotate(img, "No data available",
                    size = 30L, color = "#ffffff", gravity = "Center")
                image_write(img, path = file, format = "png")
                return()
            }

            img <- build_stats_card(artists, username, time_label, "artists")
            image_write(img, path = file, format = "png")
        }
    )

    output$download_tracks_card <- downloadHandler(
        filename = function() paste0("top-tracks-", Sys.Date(), ".png"),
        content = function(file) {
            tracks <- isolate(all_top_tracks_data())
            username <- isolate(user_display_name_val())
            time_label <- switch(isolate(input$time_range),
                "short_term"  = "Last 4 Weeks",
                "medium_term" = "Last 6 Months",
                "long_term"   = "All Time",
                "All Time"
            )

            if (is.null(tracks) || nrow(tracks) == 0) {
                img <- image_blank(1200L, 630L, color = "#191414")
                img <- image_annotate(img, "No data available",
                    size = 30L, color = "#ffffff", gravity = "Center")
                image_write(img, path = file, format = "png")
                return()
            }

            img <- build_stats_card(tracks, username, time_label, "tracks")
            image_write(img, path = file, format = "png")
        }
    )

    # ============================================
    # PLAYLIST CREATION (modal-based, from any tab)
    # ============================================

    create_playlist_source <- reactiveVal(NULL)

    playlist_name_modal <- function() {
        modalDialog(
            title = "Create Playlist",
            p(class = "text-muted", "Leave the name empty to use a default name."),
            textInput("new_playlist_name", "Playlist name:", placeholder = "e.g. Summer Vibes"),
            checkboxInput("new_playlist_public",
                          "Make it public (anyone can find it on your Spotify profile)",
                          value = FALSE),
            footer = tagList(
                modalButton("Cancel"),
                actionButton("confirm_create_playlist", "Create", class = "btn-success")
            ),
            easyClose = TRUE
        )
    }

    observeEvent(input$create_playlist_artists, {
        create_playlist_source("artist_tracks")
        showModal(playlist_name_modal())
    })

    observeEvent(input$create_playlist_tracks, {
        create_playlist_source("top_tracks")
        showModal(playlist_name_modal())
    })

    observeEvent(input$create_playlist_recent, {
        create_playlist_source("recently_played")
        showModal(playlist_name_modal())
    })

    observeEvent(input$confirm_create_playlist, {
        removeModal()
        req(is_authenticated())

        source <- create_playlist_source()
        req(source)

        user_id <- session$userData$user_id
        req(user_id)

        # Get tracks based on source; a failed Spotify call is kept to explain why
        # there is nothing to add
        failure <- NULL

        tracks <- if (source == "top_tracks") {
            top_tracks_data()
        } else if (source == "recently_played") {
            recently_played_data()
        } else {
            # artist_tracks: fetch top track for each currently shown artist
            artists <- top_artists_data()
            req(artists)
            all_tracks <- list()
            for (i in seq_len(nrow(artists))) {
                res <- api_get(paste0("/artists/", artists$id[i], "/top-tracks"),
                               list(market = "US"))
                if (res$state == "ok") {
                    track <- parse_first_track(res$data)
                    if (!is.null(track)) all_tracks[[length(all_tracks) + 1]] <- track
                } else {
                    failure <- res
                    # No point asking again when Spotify refuses the endpoint or the login ended
                    if (res$state %in% c("forbidden", "reauth")) break
                }
            }
            if (length(all_tracks) > 0) bind_rows(all_tracks) |> distinct(id, .keep_all = TRUE)
            else NULL
        }

        track_ids <- if (is.null(tracks)) character(0) else tracks$id[!is.na(tracks$id)]

        if (length(track_ids) == 0) {
            showNotification(
                if (!is.null(failure)) failure$message else "No tracks available to create a playlist.",
                type = "error"
            )
            return()
        }

        default_name <- switch(source,
            "top_tracks"      = "My Top Tracks",
            "artist_tracks"   = "My Top Artists",
            "recently_played" = "My Recently Played"
        )
        name_in <- trimws(input$new_playlist_name)
        playlist_name <- str_glue(
            "{if (nzchar(name_in)) name_in else default_name} ({Sys.Date()})"
        )

        # Create the playlist: private unless the box was ticked
        make_public <- isTRUE(input$new_playlist_public)
        create_res <- api_request(function(token) {
            spotify_create_playlist(
                token, user_id,
                name = as.character(playlist_name),
                description = "Created with TrackTeller \u2014 trackteller.youcanbeapirate.com",
                public = make_public
            )
        })

        playlist_id <- create_res$data$id
        if (create_res$state != "ok" || is.null(playlist_id)) {
            showNotification(
                if (create_res$state == "ok") "Failed to create playlist. Please try again." else create_res$message,
                type = "error"
            )
            return()
        }

        # Add tracks
        add_res <- api_request(function(token) spotify_add_tracks(token, playlist_id, track_ids))

        if (add_res$state == "ok") {
            playlist_url <- paste0("https://open.spotify.com/playlist/", playlist_id)
            showModal(modalDialog(
                title = "Playlist Created!",
                p(icon("check-circle", style = "color:#1DB954;"),
                  if (make_public) " Your playlist is ready. It is public."
                  else " Your playlist is ready. It is private: only you can see it."),
                tags$a("Open in Spotify", href = playlist_url, target = "_blank",
                       class = "btn btn-success"),
                footer  = modalButton("Close"),
                easyClose = TRUE
            ))
        } else {
            showNotification("Playlist created but failed to add tracks.", type = "warning")
        }
    })
}
