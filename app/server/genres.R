# The Top Genres tab

genres_server <- function(input, output, session, auth, shared) {
    # Fetch top artists for genre analysis
    genre_data <- reactive({
        req(auth$is_authenticated(), shared$prefs_ready())

        res <- auth$api_get("/me/top/artists",
                            list(limit = 50, time_range = shared$time_range()))
        auth$stop_if_failed(res)

        summarise_genres(res$data)
    })

    output$genre_note <- renderUI({
        data <- quiet(genre_data())
        note <- count_note(shared$shown_count(), if (is.null(data)) NULL else nrow(data),
                           "genre", "genres", cap = GENRE_CHART_MAX)
        if (!is.null(note)) tags$p(class = "list-note", note)
    })

    # The chart sits in a plain container that fills the rest of the screen but never gets
    # less than the bars need. Placed directly in the page's fill layout the plot would be
    # squeezed into whatever height is left.
    output$genre_plot_ui <- renderUI({
        data <- quiet(genre_data())
        n <- if (is.null(data)) 0L else displayed_count(shared$shown_count(), nrow(data), cap = GENRE_CHART_MAX)
        plotlyOutput("genre_plot", height = genre_chart_css_height(n))
    })

    # Genre distribution plot - green bars, title case
    output$genre_plot <- renderPlotly({
        req(genre_data())
        data <- genre_data()

        validate(need(nrow(data) > 0, TXT$no_genres))

        # Take the top N genres (never more than the chart can show)
        top_count <- displayed_count(shared$shown_count(), nrow(data), cap = GENRE_CHART_MAX)
        genre_chart(head(data, top_count))
    })

    list(data = genre_data)
}
