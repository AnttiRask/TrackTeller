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
# that Shiny sees as unchanged and ignores. The same goes for the banner: re-creating it for
# every count made its spinner start over, which looked like flashing.
playlist_pager_ui <- function(ns, where) {
    green <- "btn-success btn-sm"
    dark_text <- "color: #191414;"
    conditionalPanel(
        condition = "output.show_pager",
        ns = ns,
        div(
            class = "playlist-pager",
            actionButton(ns(paste0("first_", where)), "", icon = icon("angles-left"), class = green, style = dark_text,
                         title = "First page", `aria-label` = "First page", disabled = TRUE),
            actionButton(ns(paste0("prev_", where)), "Previous", icon = icon("chevron-left"), class = green,
                         style = dark_text, disabled = TRUE),
            span(
                class = "playlist-pager-goto",
                "Page",
                numericInput(ns(paste0("goto_", where)), NULL, value = 1, min = 1, step = 1, width = "80px"),
                "of",
                textOutput(ns(paste0("of_", where)), inline = TRUE)
            ),
            actionButton(ns(paste0("next_", where)), "Next", icon = icon("chevron-right"), class = green,
                         style = dark_text, disabled = TRUE),
            actionButton(ns(paste0("last_", where)), "", icon = icon("angles-right"), class = green, style = dark_text,
                         title = "Last page", `aria-label` = "Last page", disabled = TRUE)
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
            actionButton(ns("reload"), "Reload playlists", icon = icon("rotate"),
                         class = "btn-outline-success btn-sm"),
            uiOutput(ns("sidebar_note")),
            create_app_footer("trackteller")
        ),
        # The banners are there once; only their text changes (see playlist_pager_ui)
        conditionalPanel(
            condition = "output.banner_state == 'loading'",
            ns = ns,
            div(class = "playlist-banner",
                div(class = "playlist-spinner"),
                span(textOutput(ns("banner_text"), inline = TRUE)))
        ),
        conditionalPanel(
            condition = "output.banner_state == 'failed'",
            ns = ns,
            div(class = "playlist-banner playlist-banner-error",
                span(textOutput(ns("failed_text"), inline = TRUE)),
                actionButton(ns("retry"), "Try again", class = "btn-outline-secondary btn-sm"))
        ),
        uiOutput(ns("sync_note")),
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
# send_message:     function(type, message), by default the session's sendCustomMessage;
#                   only the tests pass another
playlists_server <- function(id, api_get, is_authenticated, tab_active, user_id = reactive(NULL),
                             page_size = PLAYLIST_PAGE_SIZE, batch_size = 50L, pause_ms = 100,
                             send_message = NULL) {
    moduleServer(id, function(input, output, session) {
        ns <- session$ns
        send <- send_message %||% function(type, message) session$sendCustomMessage(type, message)

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

        # A copy saved in the browser (sorted A-Z), shown at once while the real list loads
        cached <- new.env()
        cached$data <- NULL
        cache_present <- reactiveVal(FALSE)
        cache_from_browser <- reactiveVal(TRUE)  # the copy on screen: from the browser, or the list that was already here
        cache_requested <- reactiveVal(FALSE)  # once per login

        status <- reactiveVal("idle")          # idle | loading | done | failed
        missing_count <- reactiveVal(0L)       # how many Spotify counted that never arrived
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
            } else if (!is.null(cached$data)) {
                data <- cached$data
            }
            shown$data <- data
            bump()
        }

        # A-Z order and the letter filter: when everything is here, or from the saved copy
        sorted_view <- reactive(status() == "done" || cache_present())

        # How many playlists can be paged through: while loading, what has arrived so far
        # (the list on screen is only redrawn when it has to be)
        available <- reactive({
            if (status() == "loading" && !cache_present()) loaded() else nrow(filtered())
        })

        # The count to show in text: while loading, how many there will be
        shown_total <- reactive({
            if (status() == "loading" && !cache_present() && !is.na(total())) total() else nrow(filtered())
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
                        # Spotify's list can change while we page through it (a playlist played,
                        # created or removed): a page boundary then moves, one playlist is seen
                        # twice and another is never seen. Say so, don't pretend.
                        reported <- isolate(total())
                        missing_count(if (!is.na(reported) && nrow(fetched$data) < reported) reported - nrow(fetched$data) else 0L)
                        had_copy <- !is.null(cached$data)
                        status("done")
                        cached$data <- NULL
                        cache_present(FALSE)
                        # From Spotify's order to A-Z moves things, so start again at the top;
                        # from a saved copy (already A-Z) the page stays where it is
                        if (!had_copy) page(1L)
                        refresh_shown()
                        save_copy()
                    } else {
                        # The page being looked at changes only while it is not yet full
                        # (never, with a saved copy on screen)
                        if (is.null(cached$data) && nrow(fetched$data) <= isolate(page()) * page_size) refresh_shown()
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
            # Reloading a finished list: keep it on screen, like a saved copy, while the new one loads
            if (isolate(status()) == "done" && !is.null(shown$data)) {
                cached$data <- shown$data
                cache_from_browser(FALSE)
                cache_present(TRUE)
            }
            missing_count(0L)
            reset_data()
            loaded(0L)
            total(NA_integer_)
            page(1L)
            status("loading")
            refresh_shown()
            load_next(fetched$run)
        }

        observeEvent(list(tab_active(), is_authenticated()), {
            if (isTRUE(tab_active()) && isTRUE(is_authenticated()) && status() == "idle") {
                start_loading()
            }
        })

        observeEvent(input$retry, start_loading())
        observeEvent(input$reload, start_loading())
        observe(updateActionButton(session, "reload", disabled = status() == "loading"))

        # ---- the copy kept in the browser ----

        cache_key <- reactive({
            id <- user_id()
            if (is.null(id) || !nzchar(id)) NULL else paste0(PLAYLIST_CACHE_PREFIX, id)
        })

        # Ask for it once per login, as soon as we know whose it is
        observeEvent(list(cache_key(), is_authenticated()), {
            key <- cache_key()
            if (!is.null(key) && isTRUE(is_authenticated()) && !cache_requested()) {
                cache_requested(TRUE)
                send("playlist_cache_load", list(key = key, input_id = ns("cache")))
            }
        })

        observeEvent(input$cache, {
            if (status() == "done" || !isTRUE(is_authenticated())) return()
            data <- sanitise_cached_playlists(input$cache$items)
            if (is.null(data)) return()
            cached$data <- playlist_sort(data)
            cache_from_browser(TRUE)
            cache_present(TRUE)
            refresh_shown()
        })

        # Keep the complete list for next time
        save_copy <- function() {
            key <- isolate(cache_key())
            if (is.null(key) || is.null(shown$data)) return(invisible(NULL))
            send("playlist_cache_save", list(
                key = key,
                saved_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                items = compact_playlists(shown$data)
            ))
        }

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
            if (status() == "loading" && !cache_present()) refresh_shown()
        }, ignoreInit = TRUE)

        output$sidebar_note <- renderUI({
            tagList(
                if (status() %in% c("loading", "failed") && !cache_present()) {
                    tags$p(class = "text-muted small",
                           "The letters and A–Z order appear when all your playlists have loaded.")
                },
                tags$p(class = "text-muted small",
                       "A copy of your playlist list is kept in this browser, so that it opens faster ",
                       "next time. Logging out removes it.")
            )
        })

        # ---- paging ----

        # The last page that can be opened: while loading, what has arrived so far
        last_page <- reactive(playlist_page_count(available(), page_size))
        current_page <- reactive(min(page(), last_page()))

        # Open a page by number; out of range goes to the nearest one, and the boxes show where we ended up
        go_to <- function(value) {
            number <- suppressWarnings(as.integer(value))
            if (length(number) != 1 || is.na(number)) return(invisible(NULL))
            target <- min(max(1L, number), last_page())
            page(target)
            for (where in c("top", "bottom")) updateNumericInput(session, paste0("goto_", where), value = target)
        }
        observeEvent(input$goto_top, go_to(input$goto_top), ignoreInit = TRUE)
        observeEvent(input$goto_bottom, go_to(input$goto_bottom), ignoreInit = TRUE)

        observeEvent(list(input$first_top, input$first_bottom), page(1L), ignoreInit = TRUE)
        observeEvent(list(input$prev_top, input$prev_bottom), page(max(1L, page() - 1L)), ignoreInit = TRUE)
        observeEvent(list(input$next_top, input$next_bottom), page(min(last_page(), page() + 1L)), ignoreInit = TRUE)
        observeEvent(list(input$last_top, input$last_bottom), page(last_page()), ignoreInit = TRUE)

        # The pager: shown when there is more than a page (while loading: when there will be)
        pager_visible <- reactive(shown_total() > page_size)
        output$show_pager <- pager_visible

        # While loading, the pager already knows how many pages there will be
        pages_in_all <- reactive(format(playlist_page_count(shown_total(), page_size), big.mark = ","))
        output$of_top <- renderText(pages_in_all())
        output$of_bottom <- renderText(pages_in_all())

        # The page boxes follow the page (and the number of pages that can be opened)
        observeEvent(list(current_page(), last_page()), {
            for (where in c("top", "bottom")) {
                updateNumericInput(session, paste0("goto_", where), value = current_page(), max = last_page())
            }
        })

        # Which buttons are off: only sent to the browser when it changes
        buttons_off <- reactiveVal(list(first = TRUE, prev = TRUE, `next` = TRUE, last = TRUE))
        observe({
            at_start <- current_page() <= 1
            at_end <- current_page() >= last_page()
            now <- list(first = at_start, prev = at_start, `next` = at_end, last = at_end)
            if (!identical(now, isolate(buttons_off()))) buttons_off(now)
        })
        observeEvent(buttons_off(), {
            for (where in c("top", "bottom")) {
                for (button in c("first", "prev", "next", "last")) {
                    updateActionButton(session, paste0(button, "_", where), disabled = buttons_off()[[button]])
                }
            }
        })

        # ---- what is on screen ----

        # Only the text changes while loading; the banner itself stays (no flashing)
        banner_state <- reactive(switch(status(), loading = "loading", failed = "failed", "none"))
        output$banner_state <- banner_state
        output$banner_text <- renderText({
            paste0(
                if (cache_present() && cache_from_browser()) "Showing the copy saved in this browser while your playlists refresh\u2026 "
                else if (cache_present()) "Refreshing your playlists\u2026 "
                else "Loading your playlists\u2026 ",
                format(loaded(), big.mark = ","),
                if (!is.na(total())) paste0(" of ", format(total(), big.mark = ","))
            )
        })
        output$failed_text <- renderText({
            paste0("Couldn't load all your playlists (", format(loaded(), big.mark = ","), " so far). ")
        })

        output$sync_note <- renderUI({
            if (status() == "done" && missing_count() > 0) {
                tags$p(
                    class = "playlist-warning",
                    paste0("Spotify says you have ", format(total(), big.mark = ","), " playlists, but ",
                           format(loaded(), big.mark = ","), " arrived: your list changed while it was loading. ",
                           "Use \"Reload playlists\" to load it again.")
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

            # The cards in one container of their own: Shiny's output div is transparent to the
            # layout, so without it the page's 24 px gap would come on top of each card's margin
            tagList(
                tags$p(class = "list-note", playlist_range_note(current, page_size, shown_total())),
                tags$div(
                    class = "playlist-cards",
                    style = "padding-right: 10px;",
                    lapply(seq_len(nrow(rows)), function(i) playlist_card(rows[i, ]))
                )
            )
        })

        # Shiny decides that an output is hidden when the browser sends an input, and the tab
        # switch sends one just before the tab is shown; nothing re-checks until the next
        # input. Here nothing else is sent while the playlists load, so the page would stay
        # empty until the very end. These outputs are small: compute them whatever Shiny thinks.
        for (name in c("banner_state", "banner_text", "failed_text", "sync_note", "show_pager", "of_top",
                       "of_bottom", "list", "sidebar_note")) {
            outputOptions(output, name, suspendWhenHidden = FALSE)
        }

        # ---- a login that ends takes the playlists with it ----

        observeEvent(is_authenticated(), {
            if (!isTRUE(is_authenticated())) {
                reset_data()
                cached$data <- NULL
                cache_present(FALSE)
                cache_requested(FALSE)
                status("idle")
                missing_count(0L)
                loaded(0L)
                total(NA_integer_)
                page(1L)
                bump()
                send("playlist_cache_clear", list(prefix = PLAYLIST_CACHE_PREFIX))
            }
        }, ignoreInit = TRUE)
    })
}
