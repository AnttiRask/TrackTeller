# The Top Tracks tab. Returns the full list and the part of it that is shown.

tracks_server <- function(input, output, session, auth, shared) {
    # Fetch ALL top tracks (up to 50) based on time range
    all_top_tracks_data <- reactive({
        req(auth$is_authenticated(), shared$prefs_ready())

        res <- auth$api_get("/me/top/tracks",
                            list(limit = 50, time_range = shared$time_range()))
        auth$stop_if_failed(res)

        parse_top_tracks(res$data)
    })

    # The first `shown_count` of them (or all there are)
    top_tracks_data <- reactive({
        data <- all_top_tracks_data()
        req(data)

        head(data, displayed_count(shared$shown_count(), nrow(data)))
    })

    output$top_tracks_note <- renderUI({
        data <- quiet(all_top_tracks_data())
        note <- count_note(shared$shown_count(), if (is.null(data)) NULL else nrow(data), "track", "tracks")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    output$top_tracks_list <- renderUI({
        req(top_tracks_data())
        data <- top_tracks_data()

        validate(need(nrow(data) > 0, TXT$no_top_tracks))

        track_cards(data)
    })

    list(all = all_top_tracks_data, shown = top_tracks_data)
}
