# The Top Artists tab. Returns the full list and the part of it that is shown.

artists_server <- function(input, output, session, auth, shared) {
    # Fetch ALL top artists (up to 50) based on time range
    all_top_artists_data <- reactive({
        req(auth$is_authenticated(), shared$prefs_ready())

        res <- auth$api_get("/me/top/artists",
                            list(limit = 50, time_range = shared$time_range()))
        auth$stop_if_failed(res)

        parse_top_artists(res$data)
    })

    # The first `shown_count` of them (or all there are)
    top_artists_data <- reactive({
        data <- all_top_artists_data()
        req(data)

        head(data, displayed_count(shared$shown_count(), nrow(data)))
    })

    output$top_artists_note <- renderUI({
        data <- quiet(all_top_artists_data())
        note <- count_note(shared$shown_count(), if (is.null(data)) NULL else nrow(data), "artist", "artists")
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    output$top_artists_list <- renderUI({
        req(top_artists_data())
        data <- top_artists_data()

        validate(need(nrow(data) > 0, TXT$no_top_artists))

        artist_cards(data)
    })

    list(all = all_top_artists_data, shown = top_artists_data)
}
