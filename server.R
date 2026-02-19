# Load necessary packages
library(conflicted)
library(dplyr)
library(ggplot2)
library(httr)
library(plotly)
library(purrr)
library(stringr)
library(tidyr)
library(waiter)

# Helper function to convert to Title Case
to_title_case <- function(x) {
    sapply(x, function(s) {
        words <- strsplit(s, " ")[[1]]
        paste(toupper(substring(words, 1, 1)), substring(words, 2), sep = "", collapse = " ")
    }, USE.NAMES = FALSE)
}

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

    # Reactive trigger for manual data refresh
    refresh_trigger <- reactiveVal(0)

    # Store display name for stats card download
    user_display_name_val <- reactiveVal("")

    # Reactive value for authentication state
    is_authenticated <- reactive({
        !is.null(token_info()) && !is.null(token_info()$access_token)
    })

    # Output for conditional panel
    output$is_authenticated <- reactive({
        is_authenticated()
    })
    outputOptions(output, "is_authenticated", suspendWhenHidden = FALSE)

    # Handle OAuth callback on session start
    observe({
        # Get the OAuth code from hidden input (set by UI)
        query <- parseQueryString(session$clientData$url_search)

        if (!is.null(query$code) && is.null(isolate(token_info()))) {
            tryCatch({
                # Exchange code for token
                new_token <- spotify_exchange_code(
                    code = query$code,
                    client_id = SPOTIFY_CLIENT_ID,
                    client_secret = SPOTIFY_CLIENT_SECRET,
                    redirect_uri = REDIRECT_URI
                )
                token_info(new_token)

                # Clear the URL query parameters after successful auth
                updateQueryString("?", mode = "replace")

                output$auth_status <- renderUI({
                    div(class = "text-success",
                        icon("check-circle"),
                        " Successfully logged in!")
                })
            }, error = function(e) {
                output$auth_status <- renderUI({
                    div(class = "text-danger",
                        icon("exclamation-triangle"),
                        " Authentication failed: ", e$message)
                })
            })
        }

        # Handle OAuth error
        if (!is.null(query$error)) {
            output$auth_status <- renderUI({
                div(class = "text-danger",
                    icon("exclamation-triangle"),
                    " Spotify authorization denied: ", query$error)
            })
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
        output$auth_status <- renderUI({
            div(class = "text-info",
                icon("info-circle"),
                " You have been logged out.")
        })
    })

    # Helper function to get a valid access token
    get_access_token <- reactive({
        current_token <- token_info()

        if (is.null(current_token)) {
            return(NULL)
        }

        # Check if token needs refresh
        if (token_is_expired(current_token)) {
            tryCatch({
                refreshed_token <- spotify_refresh_token(
                    refresh_token = current_token$refresh_token,
                    client_id = SPOTIFY_CLIENT_ID,
                    client_secret = SPOTIFY_CLIENT_SECRET
                )
                token_info(refreshed_token)
                return(refreshed_token$access_token)
            }, error = function(e) {
                # If refresh fails, clear token and require re-auth
                token_info(NULL)
                output$auth_status <- renderUI({
                    div(class = "text-warning",
                        icon("exclamation-triangle"),
                        " Session expired. Please login again.")
                })
                return(NULL)
            })
        }

        current_token$access_token
    })

    # Get user profile to display
    observe({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me",
                add_headers(Authorization = paste("Bearer", token))
            )

            if (status_code(response) == 200) {
                user_data <- content(response, "parsed")
                user_display_name_val(user_data$display_name %||% "")
                output$user_display_name <- renderText({
                    paste("Welcome,", user_data$display_name, "!")
                })
                # Store user ID for playlist creation
                session$userData$user_id <- user_data$id
            }
        }, error = function(e) {
            # Silently fail - user display name is optional
        })
    })

    # ============================================
    # SYNCED TIME RANGES
    # ============================================

    # Sync time_range (Top Artists) -> other tabs
    # Only update if values differ to prevent infinite loops
    observeEvent(input$time_range, {
        if (!is.null(input$time_range_tracks) && input$time_range_tracks != input$time_range) {
            updateSelectInput(session, "time_range_tracks", selected = input$time_range)
        }
        if (!is.null(input$time_range_genres) && input$time_range_genres != input$time_range) {
            updateSelectInput(session, "time_range_genres", selected = input$time_range)
        }
    }, ignoreInit = TRUE)

    # Sync time_range_tracks (Top Tracks) -> other tabs
    observeEvent(input$time_range_tracks, {
        if (!is.null(input$time_range) && input$time_range != input$time_range_tracks) {
            updateSelectInput(session, "time_range", selected = input$time_range_tracks)
        }
        if (!is.null(input$time_range_genres) && input$time_range_genres != input$time_range_tracks) {
            updateSelectInput(session, "time_range_genres", selected = input$time_range_tracks)
        }
    }, ignoreInit = TRUE)

    # Sync time_range_genres (Top Genres) -> other tabs
    observeEvent(input$time_range_genres, {
        if (!is.null(input$time_range) && input$time_range != input$time_range_genres) {
            updateSelectInput(session, "time_range", selected = input$time_range_genres)
        }
        if (!is.null(input$time_range_tracks) && input$time_range_tracks != input$time_range_genres) {
            updateSelectInput(session, "time_range_tracks", selected = input$time_range_genres)
        }
    }, ignoreInit = TRUE)

    # Get the current time range (used by Top Artists)
    get_time_range <- reactive({
        time_range <- input$time_range
        if (is.null(time_range)) "medium_term" else time_range
    })

    # Get time range for Top Tracks
    get_time_range_tracks <- reactive({
        time_range <- input$time_range_tracks
        if (is.null(time_range)) "medium_term" else time_range
    })

    # Get time range for Top Genres
    get_time_range_genres <- reactive({
        time_range <- input$time_range_genres
        if (is.null(time_range)) "medium_term" else time_range
    })

    # ============================================
    # TOP ARTISTS TAB
    # ============================================

    # Store max available artists for current time range
    max_artists_available <- reactiveVal(50)

    # Fetch ALL top artists (up to 50) based on time range
    all_top_artists_data <- reactive({
        refresh_trigger()
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- get_time_range()

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/artists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 50, time_range = time_range)
            )

            if (status_code(response) != 200) {
                stop(paste("Failed to fetch top artists. Status:", status_code(response)))
            }

            data <- content(response, "parsed")

            if (length(data$items) == 0) {
                return(NULL)
            }

            # Extract artist data
            artists <- map_dfr(seq_along(data$items), function(i) {
                artist <- data$items[[i]]
                tibble(
                    rank = i,
                    id = artist$id,
                    name = artist$name,
                    popularity = artist$popularity,
                    followers = artist$followers$total,
                    genres = paste(artist$genres, collapse = ", "),
                    image_url = if (length(artist$images) > 0) artist$images[[1]]$url else NA_character_,
                    spotify_url = artist$external_urls$spotify
                )
            })

            return(artists)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Update slider max when data changes
    observe({
        data <- all_top_artists_data()
        if (!is.null(data) && nrow(data) > 0) {
            available <- nrow(data)
            max_artists_available(available)

            # Default to 20, or max available if less than 20
            default_value <- min(20, available)

            updateSliderInput(session, "top_artists_count",
                max = available,
                value = default_value
            )
        }
    })

    # Filter artists based on slider (uses pre-fetched data)
    top_artists_data <- reactive({
        data <- all_top_artists_data()
        req(data)

        limit <- input$top_artists_count
        if (is.null(limit)) limit <- 20

        # Return only the requested number of artists
        head(data, limit)
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
                    tags$div(
                        style = "color: #1DB954;",
                        paste0("Popularity: ", artist$popularity)
                    ),
                    tags$div(
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

    # Store max available tracks for current time range
    max_tracks_available <- reactiveVal(50)

    # Fetch ALL top tracks (up to 50) based on time range
    all_top_tracks_data <- reactive({
        refresh_trigger()
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- get_time_range_tracks()

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/tracks",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 50, time_range = time_range)
            )

            if (status_code(response) != 200) {
                stop(paste("Failed to fetch top tracks. Status:", status_code(response)))
            }

            data <- content(response, "parsed")

            if (length(data$items) == 0) {
                return(NULL)
            }

            # Extract track data
            tracks <- map_dfr(seq_along(data$items), function(i) {
                track <- data$items[[i]]
                tibble(
                    rank = i,
                    id = track$id,
                    name = track$name,
                    artist = paste(sapply(track$artists, function(a) a$name), collapse = ", "),
                    album = track$album$name,
                    popularity = track$popularity,
                    duration_ms = track$duration_ms,
                    spotify_url = track$external_urls$spotify
                )
            })

            return(tracks)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Update slider max when data changes
    observe({
        data <- all_top_tracks_data()
        if (!is.null(data) && nrow(data) > 0) {
            available <- nrow(data)
            max_tracks_available(available)

            # Default to 20, or max available if less than 20
            default_value <- min(20, available)

            updateSliderInput(session, "top_tracks_count",
                max = available,
                value = default_value
            )
        }
    })

    # Filter tracks based on slider (uses pre-fetched data)
    top_tracks_data <- reactive({
        data <- all_top_tracks_data()
        req(data)

        limit <- input$top_tracks_count
        if (is.null(limit)) limit <- 20

        # Return only the requested number of tracks
        head(data, limit)
    })

    # Top tracks list with cards
    output$top_tracks_list <- renderUI({
        req(top_tracks_data())
        data <- top_tracks_data()

        validate(need(nrow(data) > 0, "No top tracks found. Listen to more music on Spotify!"))

        # Create a list of track cards
        track_cards <- lapply(seq_len(nrow(data)), function(i) {
            track <- data[i, ]
            # Format duration as M:SS
            duration_sec <- track$duration_ms / 1000
            duration_min <- floor(duration_sec / 60)
            duration_remaining <- round(duration_sec %% 60)
            duration_formatted <- sprintf("%d:%02d", duration_min, duration_remaining)

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
                    tags$div(
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

    recently_played_data <- reactive({
        refresh_trigger()
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        count <- input$recent_tracks_display_count
        if (is.null(count)) count <- 20

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/player/recently-played",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 50)
            )

            if (status_code(response) != 200) return(NULL)

            data <- content(response, "parsed")

            if (length(data$items) == 0) return(NULL)

            tracks <- map_dfr(data$items, function(item) {
                t <- item$track
                tibble(
                    id          = t$id,
                    name        = t$name,
                    artist      = paste(sapply(t$artists, function(a) a$name), collapse = ", "),
                    album       = t$album$name,
                    spotify_url = t$external_urls$spotify
                )
            }) |>
                distinct(id, .keep_all = TRUE) |>
                head(count)

            return(tracks)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            NULL
        })
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
        refresh_trigger()
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- get_time_range_genres()

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/artists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 50, time_range = time_range)
            )

            if (status_code(response) != 200) {
                stop(paste("Failed to fetch artists for genres. Status:", status_code(response)))
            }

            data <- content(response, "parsed")

            if (length(data$items) == 0) {
                return(NULL)
            }

            # Build genre-artist pairs to preserve genre-artist mapping
            genre_artist_pairs <- map_dfr(data$items, function(artist) {
                genres <- unlist(artist$genres)
                if (length(genres) == 0) return(NULL)
                tibble(genre = genres, artist_name = artist$name)
            })

            if (nrow(genre_artist_pairs) == 0) {
                return(NULL)
            }

            genre_counts <- genre_artist_pairs |>
                group_by(genre) |>
                summarise(
                    count = n(),
                    all_artists = list(artist_name),
                    .groups = "drop"
                ) |>
                arrange(desc(count)) |>
                mutate(
                    percentage = round(count / sum(count) * 100, 1),
                    genre_display = to_title_case(genre),
                    # Show up to 5 artist names, then "..."
                    artist_names = map_chr(all_artists, function(names) {
                        if (length(names) <= 5) paste(names, collapse = ", ")
                        else paste0(paste(names[1:5], collapse = ", "), "...")
                    })
                )

            return(genre_counts)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Genre distribution plot - green bars, title case
    output$genre_plot <- renderPlotly({
        req(genre_data())
        data <- genre_data()

        validate(need(nrow(data) > 0, "No genre data available."))

        top_count <- input$top_genres_count
        if (is.null(top_count)) top_count <- 10

        # Take top N genres
        data <- head(data, top_count)

        # Create horizontal bar chart with green color
        plot <- data %>%
            mutate(genre_display = factor(genre_display, levels = rev(genre_display))) %>%
            ggplot(aes(x = genre_display, y = count,
                      text = paste0(genre_display, "\n",
                                   "Artists: ", count, "\n",
                                   "Percentage: ", percentage, "%\n",
                                   artist_names))) +
            geom_col(fill = spotify_colors$dark_green, alpha = 0.8, width = 0.7) +
            coord_flip() +
            labs(
                title = paste("Your Top", top_count, "Genres"),
                x = NULL,
                y = "Number of Artists"
            ) +
            scale_y_continuous(expand = expansion(mult = c(0, 0.1))) +
            theme_spotify() +
            theme(
                panel.grid.major.x = element_line(
                    color = spotify_colors$white,
                    linewidth = 0.4,
                    linetype = 2
                ),
                panel.grid.major.y = element_blank()
            )

        ggplotly(plot, tooltip = "text") %>%
            plotly::layout(
                hoverlabel = list(bgcolor = spotify_colors$black)
            )
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
        token <- get_access_token()
        req(token)

        offset <- playlists_offset()
        batch_size <- 50

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/playlists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = batch_size, offset = offset)
            )

            if (status_code(response) != 200) {
                stop(paste("Failed to fetch playlists. Status:", status_code(response)))
            }

            data <- content(response, "parsed")
            items <- data$items

            if (length(items) > 0) {
                # Extract this batch (NULL-safe)
                batch <- map_dfr(seq_along(items), function(i) {
                    playlist <- items[[i]]
                    tibble(
                        id = playlist$id %||% NA_character_,
                        name = playlist$name %||% "(Untitled)",
                        description = playlist$description %||% "",
                        track_count = playlist$tracks$total %||% 0L,
                        owner = playlist$owner$display_name %||% "Unknown",
                        is_public = playlist$public %||% TRUE,
                        image_url = if (length(playlist$images) > 0) playlist$images[[1]]$url else NA_character_,
                        spotify_url = playlist$external_urls$spotify %||% NA_character_
                    )
                })

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
        }, error = function(e) {
            showNotification(paste("Error loading playlists:", e$message), type = "error", duration = 10)
            playlists_loading(FALSE)
        })
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
    # SHAREABLE STATS CARD
    # ============================================

    output$download_stats_card <- downloadHandler(
        filename = function() paste0("my-music-stats-", Sys.Date(), ".png"),
        content = function(file) {
            artists <- isolate(top_artists_data())
            tracks  <- isolate(top_tracks_data())
            genres  <- isolate(genre_data())
            username <- isolate(user_display_name_val())

            time_label <- switch(isolate(input$time_range),
                "short_term"  = "Last 4 Weeks",
                "medium_term" = "Last 6 Months",
                "long_term"   = "All Time",
                "All Time"
            )

            top5_artists <- if (!is.null(artists) && nrow(artists) > 0) head(artists$name, 5) else character(0)
            top5_tracks  <- if (!is.null(tracks) && nrow(tracks) > 0) {
                head(paste0(tracks$name, " \u2013 ", tracks$artist), 5)
            } else character(0)
            top_genre <- if (!is.null(genres) && nrow(genres) > 0) genres$genre_display[1] else "N/A"

            title_label <- if (nzchar(username)) {
                paste0(username, "'s Music Stats \u2014 ", time_label)
            } else {
                paste0("My Music Stats \u2014 ", time_label)
            }

            artist_ys <- seq(0.70, 0.34, length.out = 5)
            track_ys  <- seq(0.70, 0.34, length.out = 5)

            artist_annotations <- lapply(seq_along(top5_artists), function(i) {
                annotate("text", x = 0.25, y = artist_ys[i],
                         label = paste0(i, ". ", top5_artists[i]),
                         color = "#b3b3b3", size = 3.5, hjust = 0.5, family = "sans")
            })

            track_annotations <- lapply(seq_along(top5_tracks), function(i) {
                annotate("text", x = 0.75, y = track_ys[i],
                         label = top5_tracks[i],
                         color = "#b3b3b3", size = 3.5, hjust = 0.5, family = "sans")
            })

            card <- ggplot() +
                theme_void() +
                theme(plot.background = element_rect(fill = "#191414", color = NA)) +
                coord_cartesian(xlim = c(0, 1), ylim = c(0, 1), expand = FALSE) +
                annotate("text", x = 0.5, y = 0.93,
                         label = title_label,
                         color = "#1DB954", size = 6.5, fontface = "bold", hjust = 0.5,
                         family = "sans") +
                annotate("text", x = 0.25, y = 0.81,
                         label = "TOP ARTISTS",
                         color = "#FFFFFF", size = 4.5, fontface = "bold", hjust = 0.5,
                         family = "sans") +
                artist_annotations +
                annotate("segment", x = 0.5, xend = 0.5, y = 0.18, yend = 0.83,
                         color = "#333333", linewidth = 0.8) +
                annotate("text", x = 0.75, y = 0.81,
                         label = "TOP TRACKS",
                         color = "#FFFFFF", size = 4.5, fontface = "bold", hjust = 0.5,
                         family = "sans") +
                track_annotations +
                annotate("text", x = 0.5, y = 0.14,
                         label = paste0("Top Genre: ", top_genre),
                         color = "#1DB954", size = 4, hjust = 0.5, family = "sans") +
                annotate("text", x = 0.5, y = 0.05,
                         label = "trackteller.youcanbeapirate.com",
                         color = "#666666", size = 3, hjust = 0.5, family = "sans")

            ggsave(file, plot = card, width = 12, height = 6.3, dpi = 100, bg = "#191414")
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
        token <- get_access_token()
        req(token)

        source <- create_playlist_source()
        req(source)

        user_id <- session$userData$user_id
        req(user_id)

        # Get tracks based on source
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
                resp <- GET(
                    paste0("https://api.spotify.com/v1/artists/", artists$id[i], "/top-tracks"),
                    add_headers(Authorization = paste("Bearer", token)),
                    query = list(market = "US")
                )
                if (status_code(resp) == 200) {
                    td <- content(resp, "parsed")
                    if (length(td$tracks) > 0) {
                        t <- td$tracks[[1]]
                        all_tracks[[length(all_tracks) + 1]] <- tibble(
                            id     = t$id,
                            name   = t$name,
                            artist = paste(sapply(t$artists, function(a) a$name), collapse = ", ")
                        )
                    }
                }
            }
            if (length(all_tracks) > 0) bind_rows(all_tracks) |> distinct(id, .keep_all = TRUE)
            else NULL
        }

        if (is.null(tracks) || nrow(tracks) == 0) {
            showNotification("No tracks available to create a playlist.", type = "error")
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

        # Create the playlist
        create_resp <- POST(
            paste0("https://api.spotify.com/v1/users/", user_id, "/playlists"),
            add_headers(Authorization = paste("Bearer", token)),
            content_type_json(),
            body = jsonlite::toJSON(
                list(
                    name        = as.character(playlist_name),
                    description = "Created with TrackTeller \u2014 trackteller.youcanbeapirate.com",
                    public      = TRUE
                ),
                auto_unbox = TRUE
            ),
            encode = "raw"
        )

        if (status_code(create_resp) != 201) {
            showNotification("Failed to create playlist. Please try again.", type = "error")
            return()
        }

        playlist_data <- content(create_resp, "parsed")
        playlist_id   <- playlist_data$id

        # Add tracks
        add_resp <- POST(
            paste0("https://api.spotify.com/v1/playlists/", playlist_id, "/tracks"),
            add_headers(
                Authorization  = paste("Bearer", token),
                "Content-Type" = "application/json"
            ),
            body   = list(uris = paste0("spotify:track:", tracks$id)),
            encode = "json"
        )

        if (status_code(add_resp) %in% c(200, 201)) {
            playlist_url <- paste0("https://open.spotify.com/playlist/", playlist_id)
            showModal(modalDialog(
                title = "Playlist Created!",
                p(icon("check-circle", style = "color:#1DB954;"), " Your playlist is ready."),
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
