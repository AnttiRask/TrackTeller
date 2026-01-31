# Load necessary packages
library(conflicted)
library(dplyr)
library(extrafont)
library(forcats)
library(ggplot2)
library(httr)
library(plotly)
library(purrr)
library(shinydashboard)
library(spotifyr)
library(stringr)
library(tidyr)
library(waiter)

# Define the server function
server <- function(input, output, session) {

    # Define the preferred 'filter' function to avoid namespace clashes
    conflict_prefer("filter", "dplyr")

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

    # Define reactive expression to fetch top artists and their track features
    my_artists_track_features <- reactive({
        # Require authentication
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        tryCatch({
            # Fetch the top artists for the authenticated user using httr directly
            response <- GET(
                "https://api.spotify.com/v1/me/top/artists",
                add_headers(Authorization = paste("Bearer", token)),
                query = list(limit = 20)
            )

            if (status_code(response) != 200) {
                stop(paste("Failed to fetch top artists. Status:", status_code(response)))
            }

            top_artists_data <- content(response, "parsed")

            if (length(top_artists_data$items) == 0) {
                stop("No top artists found. You may need to listen to more music on Spotify first.")
            }

            my_artists <- sample(
                sapply(top_artists_data$items, function(x) x$name),
                min(2, length(top_artists_data$items))
            )

            # Fetch the track features for the top artists
            # Using spotifyr's get_artist_audio_features (uses client credentials)
            my_artists_track_features <- map(
                my_artists,
                get_artist_audio_features,
                market = "US"
            ) %>%
                bind_rows() %>%
                select(
                    artist_id,
                    artist_name,
                    track_id,
                    track_name,
                    album_name,
                    album_release_year,
                    acousticness,
                    danceability,
                    energy,
                    instrumentalness,
                    liveness,
                    speechiness,
                    valence
                ) %>%
                as_tibble()

            return(my_artists_track_features)
        }, error = function(e) {
            showNotification(paste("Error:", e$message), type = "error", duration = 10)
            return(NULL)
        })
    })

    # Define reactive expression to summarize album track features
    my_album_summary_stats <- reactive({

        my_album_summary_stats <- my_artists_track_features() %>%
            summarise(
                across(where(is.numeric), mean),
                .by    = c(artist_name, album_release_year, album_name)
            ) %>%
            filter(
                str_detect(tolower(album_name), "commentary version") == FALSE,
                str_detect(tolower(album_name), "deluxe edition") == FALSE,
                str_detect(tolower(album_name), "track commentary") == FALSE
            ) %>%
            group_by(artist_name) %>%
            arrange(artist_name, album_release_year, album_name) %>%
            mutate(album_number = row_number(album_release_year)) %>%
            ungroup() %>%
            pivot_longer(
                cols      = !c(artist_name, album_release_year, album_name, album_number),
                names_to  = "feature",
                values_to = "score"
            ) %>%
            filter(
                feature %in% features
            )

        return(my_album_summary_stats)

    })

    # Define reactive expression to provide feature descriptions
    output$feature_introduction <- renderText({

        # Return feature description based on selected feature
        if (input$feature == "acousticness") {
            return('"A confidence measure from 0.0 to 1.0 of whether the track is acoustic. 1.0 represents high confidence the track is acoustic." -Spotify'
            )
        }

        if (input$feature == "danceability") {
            return('"Danceability describes how suitable a track is for dancing based on a combination of musical elements including tempo, rhythm stability, beat strength, and overall regularity. A value of 0.0 is least danceable and 1.0 is most danceable." -Spotify')
        }

        if (input$feature == "energy") {
            return('"Energy is a measure from 0.0 to 1.0 and represents a perceptual measure of intensity and activity. Typically, energetic tracks feel fast, loud, and noisy. For example, death metal has high energy, while a Bach prelude scores low on the scale. Perceptual features contributing to this attribute include dynamic range, perceived loudness, timbre, onset rate, and general entropy." -Spotify')
        }

        if (input$feature == "instrumentalness") {
            return('"Predicts whether a track contains no vocals. "Ooh" and "aah" sounds are treated as instrumental in this context. Rap or spoken word tracks are clearly "vocal". The closer the instrumentalness value is to 1.0, the greater likelihood the track contains no vocal content. Values above 0.5 are intended to represent instrumental tracks, but confidence is higher as the value approaches 1.0." -Spotify')
        }

        if (input$feature == "speechiness") {
            return('"Speechiness detects the presence of spoken words in a track. The more exclusively speech-like the recording (e.g. talk show, audio book, poetry), the closer to 1.0 the attribute value. Values above 0.66 describe tracks that are probably made entirely of spoken words. Values between 0.33 and 0.66 describe tracks that may contain both music and speech, either in sections or layered, including such cases as rap music. Values below 0.33 most likely represent music and other non-speech-like tracks." -Spotify')
        }

        if (input$feature == "valence") {
            return('"A measure from 0.0 to 1.0 describing the musical positiveness conveyed by a track. Tracks with high valence sound more positive (e.g. happy, cheerful, euphoric), while tracks with low valence sound more negative (e.g. sad, depressed, angry)." -Spotify')
        }

    })

    # Define reactive expression to create a summary plot
    output$summary_plot <- renderPlotly({
        req(my_album_summary_stats())

        # Create ggplot, then convert it to plotly for interactive plots
        plot1 <- my_album_summary_stats() %>%
            mutate(label_text = str_glue("{album_name} ({album_release_year})")) %>%
            filter(feature == input$feature) %>%
            ggplot(aes(album_number, score, color = artist_name)) +
            geom_line(linewidth = 1) +
            geom_point(aes(text = label_text), size = 2) +
            labs(
                color = "Artist",
                title = str_glue("Average {str_to_title(input$feature)} per Album"),
                x     = "Album #",
                y     = NULL
            ) +
            scale_color_manual(values = monokai_palette) +
            theme_spotify()

        plot1 <- ggplotly(plot1, tooltip = "text")

        plot1 <- plot1 %>%
            plotly::layout(
                legend = list(
                    font = list(
                        color = spotify_colors$dark_green,
                        font  = "Gotham",
                        size  = 20
                    ),
                    x = 1.05,
                    y = 0.5
                ),
                xaxis = list(
                    autorange = TRUE
                )
            )

        return(plot1)

    })

    # Define reactive expression to create an artist feature plot
    output$artists_plot <- renderPlot({
        req(my_artists_track_features())

        # Create ggplot to show average values of different features per artist
        my_artists_track_features() %>%
            select(
                -c(
                    track_name,
                    album_release_year,
                    album_name,
                    track_id,
                    artist_id
                )
            ) %>%
            pivot_longer(
                cols = !c(artist_name),
                names_to        = "feature",
                values_to       = "score",
                names_transform = list(feature = as.factor)
            ) %>%
            filter(feature %in% features) %>%
            ggplot(aes(feature %>% str_to_title() %>% fct_rev(), score, color = artist_name)) +
            geom_boxplot(
                fill      = spotify_colors$black,
                linewidth = 1
            ) +
            coord_flip() +
            labs(
                color = "Artist",
                title = "Average Values (0-1) of Different Features",
                x     = NULL,
                y     = NULL
            ) +
            scale_color_manual(values = monokai_palette) +
            theme_spotify() +
            theme(
                panel.grid.major.x = element_line(
                    color     = spotify_colors$white,
                    linewidth = 0.4,
                    linetype  = 2
                ),
                panel.grid.major.y = element_blank(),
                panel.grid.minor   = element_blank()
            )
    })

    # Update available y_var choices when x_var changes
    observe({
        if (!is.null(input$x_var)) {
            updateSelectInput(
                session, "y_var",
                choices  = setdiff(features, input$x_var),
                selected = "valence"
            )
        }
    })

    # Define reactive expression to create mood quadrants plot
    output$tracks_plot <- renderPlotly({
        req(input$x_var, input$y_var)
        req(my_artists_track_features())

        top_tracks <- bind_rows(
            map(unique(my_artists_track_features()$artist_id), get_artist_top_tracks)
        )

        # Create ggplot, then convert it to plotly for interactive plots
        plot2 <- top_tracks %>%
            select(id, popularity) %>%
            right_join(
                my_artists_track_features(),
                by = join_by(id == track_id)
            ) %>%
            mutate(
                rank_top_song = row_number(desc(popularity)),
                .by = artist_name
            ) %>%
            mutate(
                label_text = str_glue(
                    "{track_name}
                    from {album_name} ({album_release_year})
                    {str_to_title(input$x_var)}: {round(.data[[input$x_var]], 2)}
                    {str_to_title(input$y_var)}: {round(.data[[input$y_var]], 2)}"
                )
            ) %>%
            ggplot(aes(.data[[input$x_var]], .data[[input$y_var]], color = artist_name)) +
            geom_point(aes(text = label_text), alpha = 0.9) +
            geom_hline(yintercept = 0.5,  color = "grey", linetype = "dashed") +
            geom_vline(xintercept = 0.5,  color = "grey", linetype = "dashed") +
            labs(
                x     = str_to_title(input$x_var),
                y     = str_to_title(input$y_var),
                color = "Artist",
                title = "Mood Quadrants"
            ) +
            scale_color_manual(values = monokai_palette) +
            theme_spotify() +
            theme(panel.grid.major = element_blank())

        plot2 <- ggplotly(plot2, tooltip = "text")

        plot2 <- plot2 %>%
            plotly::layout(
                legend = list(
                    font        = list(
                        color = spotify_colors$dark_green,
                        font  = "Gotham",
                        size  = 20
                    ),
                    x = 1.05,
                    y = 0.5
                ),
                xaxis  = list(
                    range    = c(0, 1),
                    showline = FALSE
                ),
                yaxis  = list(
                    range    = c(0, 1),
                    showline = FALSE
                )
            )

        return(plot2)
    })

    # Listen for a click event on the 'generate' button to generate a playlist
    observeEvent(input$generate, {
        # Require authentication
        req(is_authenticated())
        token <- get_access_token()
        req(token)

        # Get user ID from session
        user_id <- session$userData$user_id
        req(user_id)

        # Get top artists for the authenticated user
        response <- GET(
            "https://api.spotify.com/v1/me/top/artists",
            add_headers(Authorization = paste("Bearer", token)),
            query = list(
                limit = input$num_top_artists,
                time_range = "medium_term"
            )
        )

        if (status_code(response) != 200) {
            output$playlist_link <- renderUI({
                p(class = "text-danger", "Failed to get your top artists. Please try again.")
            })
            return()
        }

        top_artists_data <- content(response, "parsed")
        artist_ids <- sapply(top_artists_data$items, function(x) x$id)

        # Get song recommendations based on user input and top artists
        new_playlist <- get_recommendations(
            seed_artists            = head(artist_ids, input$num_top_artists),
            target_acousticness     = input$acousticness,
            target_danceability     = input$danceability,
            target_energy           = input$energy,
            target_instrumentalness = input$instrumentalness,
            target_speechiness      = input$speechiness,
            target_valence          = input$valence
        )

        # Create a new playlist for the authenticated user
        playlist_name <- if (nzchar(input$playlist_name)) {
            str_glue("{input$playlist_name} ({Sys.Date()})")
        } else {
            str_glue("Generated Playlist ({Sys.Date()})")
        }

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
            output$playlist_link <- renderUI({
                p(class = "text-danger", "Failed to create playlist. Please try again.")
            })
            return()
        }

        playlist_data <- content(create_response, "parsed")
        playlist_id <- playlist_data$id

        # Add recommended songs to the created playlist
        track_uris <- paste0("spotify:track:", new_playlist$id)

        add_response <- POST(
            paste0("https://api.spotify.com/v1/playlists/", playlist_id, "/tracks"),
            add_headers(
                Authorization = paste("Bearer", token),
                "Content-Type" = "application/json"
            ),
            body = list(uris = track_uris),
            encode = "json"
        )

        # Render a UI element to display the playlist link
        output$playlist_link <- renderUI({
            playlist_link <- str_glue("https://open.spotify.com/playlist/{playlist_id}")
            p("The playlist was created. Here is the ", a("link.", href = playlist_link, target = "_blank"))
        })
    })
}
