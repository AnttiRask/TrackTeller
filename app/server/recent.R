# The Recently Played tab. Returns the part of the list that is shown.

recent_server <- function(input, output, session, auth, shared) {
    # Fetched once (the last 50); the slider only slices what is already loaded
    recently_played_all <- reactive({
        req(auth$is_authenticated(), shared$prefs_ready())

        res <- auth$api_get("/me/player/recently-played", list(limit = 50))
        auth$stop_if_failed(res)

        parse_recent_tracks(res$data, count = 50)
    })

    recently_played_data <- reactive({
        tracks <- recently_played_all()
        if (is.null(tracks)) return(NULL)

        head(tracks, displayed_count(shared$shown_count(), nrow(tracks)))
    })

    output$recently_played_note <- renderUI({
        tracks <- quiet(recently_played_all())
        note <- count_note(shared$shown_count(), if (is.null(tracks)) NULL else nrow(tracks), "track", "tracks")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    output$recently_played_list <- renderUI({
        data <- recently_played_data()
        validate(need(!is.null(data) && nrow(data) > 0, TXT$no_recent_tracks))

        recent_track_cards(data)
    })

    list(shown = recently_played_data)
}
