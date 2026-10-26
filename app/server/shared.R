# The two choices in the bar above the tabs (time range, number to show), and what the
# browser remembered of them from the last visit

shared_server <- function(input, output, session) {
    time_range  <- reactive(input$time_range %||% "short_term")
    shown_count <- reactive(input$shown_count %||% COUNT_DEFAULT)

    # What the browser remembered (www/preferences.js sends it once per session). The
    # data waits until the remembered time range is in place, so that a visit with a
    # saved range doesn't fetch the default range first.
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

    list(time_range = time_range, shown_count = shown_count, prefs_ready = prefs_ready)
}
