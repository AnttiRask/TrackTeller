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
    # TOP ARTISTS TAB
    # ============================================

    # Fetch top artists based on time range
    top_artists_data <- reactive({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- input$time_range_artists
        if (is.null(time_range)) time_range <- "medium_term"

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/artists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 20, time_range = time_range)
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
                    image_url = if (length(artist$images) > 0) artist$images[[1]]$url else NA_character_
                )
            })

            return(artists)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Top artists plot
    output$top_artists_plot <- renderPlotly({
        req(top_artists_data())
        data <- top_artists_data()

        validate(need(nrow(data) > 0, "No top artists found. Listen to more music on Spotify!"))

        # Create horizontal bar chart
        plot <- data %>%
            mutate(name = factor(name, levels = rev(name))) %>%
            ggplot(aes(x = name, y = popularity,
                      text = paste0(name, "\n",
                                   "Popularity: ", popularity, "\n",
                                   "Followers: ", format(followers, big.mark = ","), "\n",
                                   "Genres: ", genres))) +
            geom_col(fill = spotify_colors$dark_green, alpha = 0.8) +
            coord_flip() +
            labs(
                title = "Your Top 20 Artists",
                x = NULL,
                y = "Popularity Score (0-100)"
            ) +
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
    # GENRE DISTRIBUTION TAB
    # ============================================

    # Fetch top artists for genre analysis
    genre_data <- reactive({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- input$time_range_genres
        if (is.null(time_range)) time_range <- "medium_term"

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
                mutate(percentage = round(count / sum(count) * 100, 1))

            return(genre_counts)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Genre distribution plot
    output$genre_plot <- renderPlotly({
        req(genre_data())
        data <- genre_data()

        validate(need(nrow(data) > 0, "No genre data available."))

        top_count <- input$top_genres_count
        if (is.null(top_count)) top_count <- 10

        # Take top N genres
        data <- head(data, top_count)

        # Create horizontal bar chart
        plot <- data %>%
            mutate(genre = factor(genre, levels = rev(genre))) %>%
            ggplot(aes(x = genre, y = count,
                      text = paste0(genre, "\n",
                                   "Artists: ", count, "\n",
                                   "Percentage: ", percentage, "%"))) +
            geom_col(fill = monokai_palette[1:nrow(data)], alpha = 0.8) +
            coord_flip() +
            labs(
                title = paste("Your Top", top_count, "Genres"),
                x = NULL,
                y = "Number of Artists"
            ) +
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
    # TOP TRACKS TAB
    # ============================================

    # Fetch top tracks based on time range
    top_tracks_data <- reactive({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        time_range <- input$time_range_tracks
        if (is.null(time_range)) time_range <- "medium_term"

        limit <- input$top_tracks_count
        if (is.null(limit)) limit <- 20

        tryCatch({
            response <- GET(
                "https://api.spotify.com/v1/me/top/tracks",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = limit, time_range = time_range)
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
                    duration_ms = track$duration_ms
                )
            })

            return(tracks)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Top tracks plot
    output$top_tracks_plot <- renderPlotly({
        req(top_tracks_data())
        data <- top_tracks_data()

        validate(need(nrow(data) > 0, "No top tracks found. Listen to more music on Spotify!"))

        # Create horizontal bar chart showing track ranking with popularity
        plot <- data %>%
            mutate(
                label = paste0(rank, ". ", name),
                label = factor(label, levels = rev(label)),
                duration_min = round(duration_ms / 60000, 1)
            ) %>%
            ggplot(aes(x = label, y = popularity,
                      text = paste0("#", rank, " ", name, "\n",
                                   "Artist: ", artist, "\n",
                                   "Album: ", album, "\n",
                                   "Popularity: ", popularity, "\n",
                                   "Duration: ", duration_min, " min"))) +
            geom_col(fill = spotify_colors$dark_green, alpha = 0.8) +
            coord_flip() +
            labs(
                title = "Your Top Tracks",
                x = NULL,
                y = "Popularity Score (0-100)"
            ) +
            theme_spotify() +
            theme(
                panel.grid.major.x = element_line(
                    color = spotify_colors$white,
                    linewidth = 0.4,
                    linetype = 2
                ),
                panel.grid.major.y = element_blank(),
                axis.text.y = element_text(size = rel(0.7))
            )

        ggplotly(plot, tooltip = "text") %>%
            plotly::layout(
                hoverlabel = list(bgcolor = spotify_colors$black)
            )
    })

    # ============================================
    # PLAYLIST GENERATOR TAB
    # ============================================

    # Store selected tracks for playlist
    playlist_tracks <- reactiveVal(NULL)

    # Update playlist preview when inputs change
    observe({
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        source <- input$playlist_source
        if (is.null(source)) source <- "top_tracks"

        track_count <- input$playlist_track_count
        if (is.null(track_count)) track_count <- 20

        tryCatch({
            if (source == "top_tracks") {
                # Get user's top tracks
                time_range <- input$playlist_time_range
                if (is.null(time_range)) time_range <- "medium_term"

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
                num_artists <- input$num_top_artists
                if (is.null(num_artists)) num_artists <- 5

                # First get top artists
                artists_response <- GET(
                    "https://api.spotify.com/v1/me/top/artists",
                    add_headers(Authorization = paste("Bearer", token)),
                    query = list(limit = num_artists, time_range = "medium_term")
                )

                if (status_code(artists_response) != 200) {
                    playlist_tracks(NULL)
                    return()
                }

                artists_data <- content(artists_response, "parsed")

                # Get top tracks for each artist
                all_tracks <- list()
                tracks_per_artist <- ceiling(track_count / num_artists)

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
                        distinct(id, .keep_all = TRUE) %>%
                        head(track_count)
                    playlist_tracks(tracks)
                } else {
                    playlist_tracks(NULL)
                }
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

        # Create playlist name
        playlist_name <- if (nzchar(input$playlist_name)) {
            str_glue("{input$playlist_name} ({Sys.Date()})")
        } else {
            str_glue("My Top Tracks ({Sys.Date()})")
        }

        # Create the playlist
        create_response <- POST(
            paste0("https://api.spotify.com/v1/users/", user_id, "/playlists"),
            add_headers(
                Authorization = paste("Bearer", token),
                "Content-Type" = "application/json"
            ),
            body = list(
                name = playlist_name,
                description = "Generated with R!",
                public = TRUE
            ),
            encode = "json"
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
