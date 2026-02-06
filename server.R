# Load necessary packages
library(conflicted)
library(dplyr)
library(ggplot2)
library(httr)
library(plotly)
library(purrr)
library(shinydashboard)
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

        if (!is.null(query$code) && is.null(token_info())) {
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
            style = "max-height: 700px; overflow-y: auto; padding-right: 10px;",
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
            style = "max-height: 700px; overflow-y: auto; padding-right: 10px;",
            track_cards
        )
    })

    # ============================================
    # GENRE DISTRIBUTION TAB
    # ============================================

    # Fetch top artists for genre analysis
    genre_data <- reactive({
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

            # Extract and count genres
            all_genres <- unlist(lapply(data$items, function(artist) artist$genres))

            if (length(all_genres) == 0) {
                return(NULL)
            }

            genre_counts <- as.data.frame(table(all_genres), stringsAsFactors = FALSE)
            names(genre_counts) <- c("genre", "count")
            genre_counts <- genre_counts %>%
                arrange(desc(count)) %>%
                mutate(
                    percentage = round(count / sum(count) * 100, 1),
                    # Convert to Title Case
                    genre_display = to_title_case(genre)
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
                                   "Percentage: ", percentage, "%"))) +
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

    # Fetch ALL user's playlists (paginated)
    all_playlists_data <- reactive({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        tryCatch({
            all_items <- list()
            offset <- 0
            batch_size <- 50

            repeat {
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

                if (length(items) == 0) break

                all_items <- c(all_items, items)
                offset <- offset + batch_size

                if (length(items) < batch_size) break
            }

            if (length(all_items) == 0) return(NULL)

            # Extract playlist data
            playlists <- map_dfr(seq_along(all_items), function(i) {
                playlist <- all_items[[i]]
                tibble(
                    id = playlist$id,
                    name = playlist$name,
                    description = if (!is.null(playlist$description)) playlist$description else "",
                    track_count = playlist$tracks$total,
                    owner = playlist$owner$display_name,
                    is_public = if (!is.null(playlist$public)) playlist$public else TRUE,
                    image_url = if (length(playlist$images) > 0) playlist$images[[1]]$url else NA_character_,
                    spotify_url = playlist$external_urls$spotify
                )
            })

            # Sort alphabetically (case-insensitive)
            playlists <- playlists %>% arrange(tolower(name))

            return(playlists)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
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

        # Default to first available choice
        updateSelectInput(session, "playlist_letter",
            choices = available,
            selected = available[[1]]
        )
    })

    # Filter playlists by selected letter
    filtered_playlists_data <- reactive({
        data <- all_playlists_data()
        req(data)

        letter <- input$playlist_letter
        if (is.null(letter) || length(letter) == 0) return(head(data, 0))

        if (letter == "#") {
            data %>% filter(!grepl("^[A-Za-z]", name))
        } else {
            data %>% filter(toupper(substr(name, 1, 1)) == letter)
        }
    })

    # Render user's playlists
    output$user_playlists_list <- renderUI({
        all_data <- all_playlists_data()
        req(all_data)
        data <- filtered_playlists_data()

        validate(need(nrow(data) > 0, "No playlists found for this letter."))

        total_count <- nrow(all_data)
        filtered_count <- nrow(data)

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

        tags$div(
            tags$p(
                style = "color: #b3b3b3; margin-bottom: 10px;",
                paste0("Showing ", filtered_count, " of ", total_count, " playlists")
            ),
            tags$div(
                style = "max-height: 700px; overflow-y: auto; padding-right: 10px;",
                playlist_cards
            )
        )
    })

    # ============================================
    # PLAYLIST GENERATOR TAB
    # ============================================

    # Clear playlist form when leaving the tab
    observeEvent(input$main_navbar, {
        if (input$main_navbar != "playlist_generator") {
            # Clear the playlist name input
            updateTextInput(session, "playlist_name", value = "")
            # Clear the success/error message
            output$playlist_link <- renderUI({ NULL })
        }
    }, ignoreInit = TRUE)

    # Store selected tracks for playlist
    playlist_tracks <- reactiveVal(NULL)

    # Store max available artists for playlist time range
    max_playlist_artists_available <- reactiveVal(50)

    # Fetch available artist count for playlist time range (to update slider)
    playlist_artists_count <- reactive({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- input$playlist_time_range
        if (is.null(time_range)) time_range <- "short_term"

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/artists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 50, time_range = time_range)
            )

            if (status_code(response) == 200) {
                data <- content(response, "parsed")
                return(length(data$items))
            }
            return(50)
        }, error = function(e) {
            return(50)
        })
    })

    # Update num_top_artists slider when available count changes
    observe({
        available <- playlist_artists_count()
        if (!is.null(available) && available > 0) {
            max_playlist_artists_available(available)

            # Default to 20, or max available if less than 20
            default_value <- min(20, available)

            updateSliderInput(session, "num_top_artists",
                max = available,
                value = default_value
            )
        }
    })

    # Update playlist preview when inputs change
    observe({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        source <- input$playlist_source
        if (is.null(source)) source <- "top_tracks"

        # Access all inputs outside tryCatch to ensure reactive dependencies are tracked
        track_count <- input$playlist_track_count
        if (is.null(track_count)) track_count <- 20

        num_artists <- input$num_top_artists
        if (is.null(num_artists)) num_artists <- 20

        recent_count <- input$recent_tracks_count
        if (is.null(recent_count)) recent_count <- 20

        time_range <- input$playlist_time_range
        if (is.null(time_range)) time_range <- "short_term"

        # Always use 1 track per artist (no slider in UI)
        tracks_per_artist <- 1

        tryCatch({
            if (source == "top_tracks") {
                # Get user's top tracks
                response <- GET(
                    "https://api.spotify.com/v1/me/top/tracks",
                    add_headers(Authorization = paste("Bearer", token)),
                    query = list(limit = track_count, time_range = time_range)
                )

                if (status_code(response) != 200) {
                    playlist_tracks(NULL)
                    return()
                }

                data <- content(response, "parsed")
                tracks <- map_dfr(data$items, function(track) {
                    tibble(
                        id = track$id,
                        name = track$name,
                        artist = paste(sapply(track$artists, function(a) a$name), collapse = ", ")
                    )
                })

                playlist_tracks(tracks)

            } else if (source == "artist_tracks") {
                # Get top tracks from user's top artists
                # First get top artists
                artists_response <- GET(
                    "https://api.spotify.com/v1/me/top/artists",
                    add_headers(Authorization = paste("Bearer", token)),
                    query = list(limit = num_artists, time_range = time_range)
                )

                if (status_code(artists_response) != 200) {
                    playlist_tracks(NULL)
                    return()
                }

                artists_data <- content(artists_response, "parsed")

                # Get top tracks for each artist
                all_tracks <- list()

                for (artist in artists_data$items) {
                    tracks_response <- GET(
                        paste0("https://api.spotify.com/v1/artists/", artist$id, "/top-tracks"),
                        add_headers(Authorization = paste("Bearer", token)),
                        query = list(market = "US")
                    )

                    if (status_code(tracks_response) == 200) {
                        tracks_data <- content(tracks_response, "parsed")
                        for (track in head(tracks_data$tracks, tracks_per_artist)) {
                            all_tracks[[length(all_tracks) + 1]] <- tibble(
                                id = track$id,
                                name = track$name,
                                artist = paste(sapply(track$artists, function(a) a$name), collapse = ", ")
                            )
                        }
                    }
                }

                if (length(all_tracks) > 0) {
                    tracks <- bind_rows(all_tracks) %>%
                        distinct(id, .keep_all = TRUE)
                    playlist_tracks(tracks)
                } else {
                    playlist_tracks(NULL)
                }

            } else if (source == "recently_played") {
                # Get user's recently played tracks
                response <- GET(
                    "https://api.spotify.com/v1/me/player/recently-played",
                    add_headers(Authorization = paste("Bearer", token)),
                    query = list(limit = recent_count)
                )

                if (status_code(response) != 200) {
                    playlist_tracks(NULL)
                    return()
                }

                data <- content(response, "parsed")
                tracks <- map_dfr(data$items, function(item) {
                    track <- item$track
                    tibble(
                        id = track$id,
                        name = track$name,
                        artist = paste(sapply(track$artists, function(a) a$name), collapse = ", ")
                    )
                })

                # Remove duplicates (same song played multiple times)
                tracks <- tracks %>%
                    distinct(id, .keep_all = TRUE)

                playlist_tracks(tracks)
            }
        }, error = function(e) {
            message("Error fetching playlist tracks: ", e$message)
            playlist_tracks(NULL)
        })
    })

    # Render playlist preview
    output$playlist_preview <- renderUI({
        tracks <- playlist_tracks()

        if (is.null(tracks) || nrow(tracks) == 0) {
            return(p(class = "text-muted", "Loading track preview..."))
        }

        # Create a list of tracks
        track_list <- lapply(seq_len(nrow(tracks)), function(i) {
            tags$div(
                class = "track-item",
                style = "padding: 5px 0; border-bottom: 1px solid #333;",
                tags$span(style = "color: #1DB954;", paste0(i, ". ")),
                tags$span(style = "color: #fff;", tracks$name[i]),
                tags$span(style = "color: #b3b3b3;", paste0(" - ", tracks$artist[i]))
            )
        })

        tags$div(
            style = "max-height: 400px; overflow-y: auto;",
            track_list
        )
    })

    # Generate playlist when button is clicked
    observeEvent(input$generate, {
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        tracks <- playlist_tracks()

        if (is.null(tracks) || nrow(tracks) == 0) {
            output$playlist_link <- renderUI({
                p(class = "text-danger", "No tracks available to create playlist.")
            })
            return()
        }

        # Get user ID from session
        user_id <- session$userData$user_id
        req(user_id)

        # Create playlist name based on source
        source <- input$playlist_source
        default_name <- switch(source,
            "top_tracks" = "My Top Tracks",
            "artist_tracks" = "Artist Favorites",
            "recently_played" = "Recently Played",
            "My Playlist"
        )

        playlist_name <- if (nzchar(input$playlist_name)) {
            str_glue("{input$playlist_name} ({Sys.Date()})")
        } else {
            str_glue("{default_name} ({Sys.Date()})")
        }

        # Create the playlist body
        playlist_body <- jsonlite::toJSON(
            list(
                name = as.character(playlist_name),
                description = "Created with TrackTeller - github.com/AnttiRask/TrackTeller",
                public = TRUE
            ),
            auto_unbox = TRUE
        )

        # Create the playlist
        # Using encode = "raw" to ensure the JSON string is sent as-is
        create_response <- POST(
            paste0("https://api.spotify.com/v1/users/", user_id, "/playlists"),
            add_headers(Authorization = paste("Bearer", token)),
            content_type_json(),
            body = playlist_body,
            encode = "raw"
        )

        if (status_code(create_response) != 201) {
            error_content <- content(create_response, "text")
            message("Failed to create playlist. Status: ", status_code(create_response))
            message("Response: ", error_content)
            output$playlist_link <- renderUI({
                p(class = "text-danger", "Failed to create playlist. Please try again.")
            })
            return()
        }

        playlist_data <- content(create_response, "parsed")
        playlist_id <- playlist_data$id

        # Add tracks to the playlist
        track_uris <- paste0("spotify:track:", tracks$id)

        add_response <- POST(
            paste0("https://api.spotify.com/v1/playlists/", playlist_id, "/tracks"),
            add_headers(
                Authorization = paste("Bearer", token),
                "Content-Type" = "application/json"
            ),
            body = list(uris = track_uris),
            encode = "json"
        )

        if (status_code(add_response) != 201 && status_code(add_response) != 200) {
            output$playlist_link <- renderUI({
                p(class = "text-warning",
                  "Playlist created but failed to add some tracks. ",
                  a("Open playlist", href = paste0("https://open.spotify.com/playlist/", playlist_id),
                    target = "_blank"))
            })
            return()
        }

        # Success!
        output$playlist_link <- renderUI({
            playlist_link <- paste0("https://open.spotify.com/playlist/", playlist_id)
            div(
                class = "text-success",
                p(icon("check-circle"), " Playlist created successfully!"),
                p("Open your new playlist: ",
                  a(playlist_name, href = playlist_link, target = "_blank", class = "btn btn-success"))
            )
        })
    })
}
