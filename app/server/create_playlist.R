# Creating a playlist from the artists, tracks or recently played shown (a modal, from any tab)

playlist_name_modal <- function() {
    modalDialog(
        title = "Create Playlist",
        p(class = "text-muted", "Leave the name empty to use a default name."),
        textInput("new_playlist_name", "Playlist name:", placeholder = "e.g. Summer Vibes"),
        p(
            icon("globe"),
            " The playlist will be public: Spotify doesn't let apps like this one create",
            " private playlists. You can make it private in Spotify afterwards: open it,",
            " click the three dots and choose \"Make private\"."
        ),
        footer = tagList(
            modalButton("Cancel"),
            actionButton("confirm_create_playlist", "Create", class = "btn-success")
        ),
        easyClose = TRUE
    )
}

playlist_created_modal <- function(playlist_id) {
    modalDialog(
        title = "Playlist Created!",
        p(icon("check-circle", style = "color:#1DB954;"), " Your playlist is ready."),
        p("It is public. To make it private, open it in Spotify, click the three dots",
          " and choose \"Make private\"."),
        tags$a("Open in Spotify", href = paste0("https://open.spotify.com/playlist/", playlist_id),
               target = "_blank", class = "btn btn-success"),
        footer  = modalButton("Close"),
        easyClose = TRUE
    )
}

create_playlist_server <- function(input, output, session, auth, artists, tracks, recent) {
    create_playlist_source <- reactiveVal(NULL)

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
        req(auth$is_authenticated())

        source <- create_playlist_source()
        req(source)

        user_id <- auth$user_id()
        req(user_id)

        # Get tracks based on source; a failed Spotify call is kept to explain why
        # there is nothing to add
        failure <- NULL

        tracks_to_add <- if (source == "top_tracks") {
            tracks$shown()
        } else if (source == "recently_played") {
            recent$shown()
        } else {
            # artist_tracks: fetch top track for each currently shown artist
            shown_artists <- artists$shown()
            req(shown_artists)
            all_tracks <- list()
            for (i in seq_len(nrow(shown_artists))) {
                res <- auth$api_get(paste0("/artists/", shown_artists$id[i], "/top-tracks"),
                                    list(market = TOP_TRACKS_MARKET))
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

        track_ids <- if (is.null(tracks_to_add)) character(0) else tracks_to_add$id[!is.na(tracks_to_add$id)]

        if (length(track_ids) == 0) {
            showNotification(
                if (!is.null(failure)) failure$message else TXT$playlist_no_tracks,
                type = "error"
            )
            return()
        }

        name_in <- trimws(input$new_playlist_name)
        playlist_name <- playlist_title(name_in, source)

        # Create the playlist (public: see spotify_create_playlist)
        create_res <- auth$api_request(function(token) {
            spotify_create_playlist(
                token, user_id,
                name = playlist_name,
                description = TXT$playlist_description,
                public = TRUE
            )
        })

        playlist_id <- create_res$data$id
        if (create_res$state != "ok" || is.null(playlist_id)) {
            showNotification(
                if (create_res$state == "ok") TXT$playlist_failed else create_res$message,
                type = "error"
            )
            return()
        }

        # Add tracks
        add_res <- auth$api_request(function(token) spotify_add_tracks(token, playlist_id, track_ids))

        if (add_res$state == "ok") {
            showModal(playlist_created_modal(playlist_id))
        } else {
            showNotification(TXT$playlist_add_failed, type = "warning")
        }
    })
}
