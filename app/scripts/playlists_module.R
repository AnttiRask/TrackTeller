# The My Playlists tab, as a Shiny module so that it can be tested on its own (with a fake
# Spotify). Everything about the list lives here: loading, paging, the letter filter.
#
# Spotify's /me/playlists gives 50 playlists per request and nothing to search or filter
# on, and overlapping requests are throttled (measured: 85 pages take 47 s one after
# another, and 73-85 s with 3-5 at once). So:
#   * the loader asks for one page at a time WITHOUT blocking the R session (a blocked
#     session can't answer the browser; with 85 half-second requests in a row the page
#     stayed empty until the very end), and shows the playlists as they arrive, in
#     Spotify's own order, 50 to a page;
#   * A-Z order and the letter filter need everything, so they switch on when loading is
#     done (or at once, when a copy saved in this browser is available);
#   * nothing in the list is re-rendered per batch; only the progress line changes.

playlist_card <- function(playlist) {
    tags$div(
        class = "playlist-card",
        style = paste0(
            "display: flex; align-items: center; padding: 12px; ",
            "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
            "transition: background 0.2s; cursor: default;"
        ),
        if (!is.na(playlist$image_url)) {
            tags$img(
                src = playlist$image_url, loading = "lazy",
                style = "width: 50px; height: 50px; border-radius: 4px; object-fit: cover;"
            )
        } else {
            tags$div(
                style = "width: 50px; height: 50px; border-radius: 4px; background: #333; display: flex; align-items: center; justify-content: center;",
                icon("music", style = "color: #666;")
            )
        },
        tags$div(
            style = "flex: 1; margin-left: 15px;",
            tags$div(style = "color: #fff; font-size: 1.1em; font-weight: 500;", playlist$name),
            tags$div(style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;", paste0("By ", playlist$owner))
        ),
        tags$div(
            style = "text-align: right; color: #b3b3b3; font-size: 0.85em;",
            tags$div(style = "color: #1DB954;", paste0(playlist$track_count, " tracks")),
            tags$div(if (isTRUE(playlist$is_public)) "Public" else "Private")
        ),
        if (!is.na(playlist$spotify_url)) {
            tags$a(
                href = playlist$spotify_url, target = "_blank", rel = "noopener noreferrer",
                style = paste0(
                    "margin-left: 15px; padding: 8px 12px; ",
                    "background: #1DB954; color: #fff; border-radius: 20px; ",
                    "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                    "display: flex; align-items: center; gap: 5px;"
                ),
                icon("spotify"),
                "Open"
            )
        }
    )
}

# The pager's buttons are created once and only updated afterwards: a button that is
# re-created by renderUI starts counting from 0 again, and a click can then send a value
# that Shiny sees as unchanged and ignores.
playlist_pager_ui <- function(ns, where) {
    conditionalPanel(
        condition = "output.show_pager",
        ns = ns,
        div(
            class = "playlist-pager",
            actionButton(ns(paste0("prev_", where)), "Previous", icon = icon("chevron-left"),
                         class = "btn-outline-secondary btn-sm", disabled = TRUE),
            span(class = "playlist-pager-label", textOutput(ns(paste0("label_", where)), inline = TRUE)),
            actionButton(ns(paste0("next_", where)), "Next", icon = icon("chevron-right"),
                         class = "btn-outline-secondary btn-sm", disabled = TRUE)
        )
    )
}

playlists_ui <- function(id) {
    ns <- NS(id)

    layout_sidebar(
        sidebar = sidebar(
            width = 350,
            h3("Your Playlists"),
            br(),
            p("Browse all your Spotify playlists, 50 at a time, or by first letter."),
            br(),
            selectInput(
                ns("letter"),
                "Filter by first letter:",
                choices = c("All playlists" = "all"),
                selected = "all"
            ),
            uiOutput(ns("sidebar_note")),
            create_app_footer("trackteller")
        ),
        uiOutput(ns("progress")),
        playlist_pager_ui(ns, "top"),
        uiOutput(ns("list")),
        playlist_pager_ui(ns, "bottom"),
        div(style = "height: 40px;")
    )
}

# api_get:          function(path, query) -> a PROMISE of list(state, data, ...); it must not
#                   block (the app's api_get_async)
# is_authenticated: reactive, TRUE while somebody is logged in
# tab_active:       reactive, TRUE while the My Playlists tab is open
# user_id:          reactive, the Spotify user id (NULL until known); names the browser copy
playlists_server <- function(id, api_get, is_authenticated, tab_active, user_id = reactive(NULL),
                             page_size = PLAYLIST_PAGE_SIZE, batch_size = 50L, pause_ms = 100) {
    moduleServer(id, function(input, output, session) {
        ns <- session$ns

        # Not reactive: the playlists as they arrive (in Spotify's order), and what is shown
        fetched <- new.env()
        shown <- new.env()
        fetched$run <- 0L
        reset_data <- function() {
            fetched$data <- NULL
            fetched$offset <- 0L
            shown$data <- NULL
            fetched$run <- fetched$run + 1L     # what is still on its way now belongs to the past
        }
        reset_data()
        session$onSessionEnded(function() fetched$run <- fetched$run + 1L)

        status <- reactiveVal("idle")          # idle | loading | done | failed
        loaded <- reactiveVal(0L)              # how many have arrived
        total <- reactiveVal(NA_integer_)      # how many there are, once Spotify has said
        version <- reactiveVal(0L)             # bumped when what is shown has changed
        page <- reactiveVal(1L)

        bump <- function() version(isolate(version()) + 1L)

        # What is shown: Spotify's order while loading, A-Z once everything is here
        refresh_shown <- function() {
            data <- fetched$data
            if (isolate(status()) == "done" && !is.null(data)) {
                data <- playlist_sort(data)
            }
            shown$data <- data
            bump()
        }

        sorted_view <- reactive(status() == "done")

        # How many playlists can be paged through: while loading, what has arrived so far
        # (the list on screen is only redrawn when it has to be)
        available <- reactive({
            if (status() == "loading") loaded() else nrow(filtered())
        })

        # The count to show in text: while loading, how many there will be
        shown_total <- reactive({
            if (status() == "loading" && !is.na(total())) total() else nrow(filtered())
        })

        all_data <- reactive({
            version()
            shown$data
        })

        filtered <- reactive({
            data <- all_data()
            req(data)
            filter_playlists(data, if (sorted_view()) input$letter else "all")
        })

        # ---- loading ----

        # One page per step, each answered without blocking the session; the next step
        # follows after a short pause. `run` says which load a result belongs to: after a
        # logout or a restart, an answer still on its way is dropped.
        load_next <- function(run) {
            result <- promises::then(
                api_get("/me/playlists", list(limit = batch_size, offset = fetched$offset)),
                onFulfilled = function(res) {
                    if (run != fetched$run || !isTRUE(isolate(is_authenticated()))) return(invisible(NULL))

                    if (res$state != "ok") {
                        if (res$state != "reauth") {
                            showNotification(res$message, type = "error", duration = 10)
                        }
                        status("failed")
                        refresh_shown()
                        return(invisible(NULL))
                    }

                    items <- res$data$items
                    if (is.na(isolate(total()))) total(as.integer(res$data$total %||% NA_integer_))

                    if (length(items) > 0) {
                        batch <- parse_playlists_page(items)
                        fetched$data <- if (is.null(fetched$data)) batch else dplyr::bind_rows(fetched$data, batch)
                        fetched$offset <- fetched$offset + batch_size
                        loaded(nrow(fetched$data))
                    }

                    if (length(items) < batch_size) {
                        # A playlist added while we were loading shifts the pages: keep each once
                        fetched$data <- dplyr::distinct(fetched$data, id, .keep_all = TRUE)
                        loaded(nrow(fetched$data))
                        status("done")
                        page(1L)
                        refresh_shown()
                    } else {
                        # The page being looked at changes only while it is not yet full
                        if (nrow(fetched$data) <= isolate(page()) * page_size) refresh_shown()
                        pause <- promises::promise(function(resolve, reject) {
                            later::later(function() resolve(NULL), pause_ms / 1000)
                        })
                        promises::then(pause, onFulfilled = function(ignored) load_next(run))
                    }
                }
            )
            # Whatever goes wrong in a step ends the load, visibly, and doesn't take the session down
            promises::catch(result, function(e) {
                if (run == fetched$run) {
                    message("[playlists] load failed: ", conditionMessage(e))
                    status("failed")
                    refresh_shown()
                }
            })
            invisible(NULL)
        }

        start_loading <- function() {
            reset_data()
            loaded(0L)
            total(NA_integer_)
            page(1L)
            status("loading")
            bump()
            load_next(fetched$run)
        }

        observeEvent(list(tab_active(), is_authenticated()), {
            if (isTRUE(tab_active()) && isTRUE(is_authenticated()) && status() == "idle") {
                start_loading()
            }
        })

        observeEvent(input$retry, start_loading())

        # ---- the letter filter (needs everything, so only when loading is done) ----

        observe({
            data <- all_data()
            choices <- if (sorted_view() && !is.null(data)) {
                playlist_letter_choices(data$name)
            } else {
                c("All playlists" = "all")
            }
            current <- isolate(input$letter)
            updateSelectInput(session, "letter", choices = choices,
                              selected = if (!is.null(current) && current %in% choices) current else "all")
        })

        observeEvent(input$letter, page(1L), ignoreInit = TRUE)

        # While loading, the list on screen is only redrawn when the page being looked at
        # changes; a new page gets what has arrived by now
        observeEvent(page(), {
            if (status() == "loading") refresh_shown()
        }, ignoreInit = TRUE)

        output$sidebar_note <- renderUI({
            if (status() %in% c("loading", "failed")) {
                tags$p(class = "text-muted small",
                       "The letters and A–Z order appear when all your playlists have loaded.")
            }
        })

        # ---- paging ----

        observeEvent(list(input$prev_top, input$prev_bottom), {
            page(max(1L, page() - 1L))
        }, ignoreInit = TRUE)

        observeEvent(list(input$next_top, input$next_bottom), {
            last <- playlist_page_count(available(), page_size)
            page(min(last, page() + 1L))
        }, ignoreInit = TRUE)

        # The pager: shown when there is more than a page (while loading: when there will be)
        pager_visible <- reactive(shown_total() > page_size)
        output$show_pager <- pager_visible

        current_page <- reactive(min(page(), playlist_page_count(available(), page_size)))

        # While loading, the pager already knows how many pages there will be
        page_label <- reactive({
            paste0("Page ", format(current_page(), big.mark = ","), " of ",
                   format(playlist_page_count(shown_total(), page_size), big.mark = ","))
        })
        output$label_top <- renderText(page_label())
        output$label_bottom <- renderText(page_label())

        # Which buttons are off: only sent to the browser when it changes
        buttons_off <- reactiveVal(list(prev = TRUE, `next` = TRUE))
        observe({
            now <- list(prev = current_page() <= 1,
                        `next` = current_page() >= playlist_page_count(available(), page_size))
            if (!identical(now, isolate(buttons_off()))) buttons_off(now)
        })
        observeEvent(buttons_off(), {
            for (where in c("top", "bottom")) {
                updateActionButton(session, paste0("prev_", where), disabled = buttons_off()$prev)
                updateActionButton(session, paste0("next_", where), disabled = buttons_off()$`next`)
            }
        })

        # ---- what is on screen ----

        output$progress <- renderUI({
            st <- status()
            if (st == "loading") {
                tags$div(
                    class = "playlist-banner",
                    tags$div(class = "playlist-spinner"),
                    tags$span(
                        "Loading your playlists… ",
                        format(loaded(), big.mark = ","),
                        if (!is.na(total())) paste0(" of ", format(total(), big.mark = ","))
                    )
                )
            } else if (st == "failed") {
                tags$div(
                    class = "playlist-banner playlist-banner-error",
                    tags$span(paste0("Couldn't load all your playlists (", format(loaded(), big.mark = ","), " so far). ")),
                    actionButton(ns("retry"), "Try again", class = "btn-outline-secondary btn-sm")
                )
            }
        })

        output$list <- renderUI({
            if (status() == "loading" && is.null(all_data())) {
                return(tags$div(
                    style = "text-align: center; padding: 40px; color: #b3b3b3;",
                    tags$div(class = "playlist-spinner", style = "display: inline-block;"),
                    tags$p(style = "margin-top: 15px;", "Loading playlists...")
                ))
            }

            data <- filtered()
            validate(need(nrow(data) > 0, "No playlists found."))

            current <- min(page(), playlist_page_count(nrow(data), page_size))
            rows <- playlist_page(data, current, page_size)

            tagList(
                tags$p(class = "list-note", playlist_range_note(current, page_size, shown_total())),
                lapply(seq_len(nrow(rows)), function(i) playlist_card(rows[i, ]))
            )
        })

        # Shiny decides that an output is hidden when the browser sends an input, and the tab
        # switch sends one just before the tab is shown; nothing re-checks until the next
        # input. Here nothing else is sent while the playlists load, so the page would stay
        # empty until the very end. These outputs are small: compute them whatever Shiny thinks.
        for (name in c("progress", "show_pager", "label_top", "label_bottom", "list", "sidebar_note")) {
            outputOptions(output, name, suspendWhenHidden = FALSE)
        }

        # ---- a login that ends takes the playlists with it ----

        observeEvent(is_authenticated(), {
            if (!isTRUE(is_authenticated())) {
                reset_data()
                status("idle")
                loaded(0L)
                total(NA_integer_)
                page(1L)
                bump()
            }
        }, ignoreInit = TRUE)
    })
}
