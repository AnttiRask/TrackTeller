library(shiny)
source(file.path(app_dir, "scripts", "playlists.R"))
source(file.path(app_dir, "scripts", "playlists_module.R"))

# A fake Spotify with `n` playlists, 50 to a page, that remembers how often it was asked.
# `fail_at` makes the request for that offset fail.
fake_spotify <- function(n, names = NULL, fail_at = NULL, duplicate_first_of_page_two = FALSE) {
    if (is.null(names)) {
        names <- sprintf("%s playlist %04d",
                         c("Zebra", "Mix", "Apple", "99 Songs", "Ääni", "banana")[(seq_len(n) %% 6) + 1],
                         seq_len(n))
    }
    ids <- paste0("id", seq_len(n))
    if (duplicate_first_of_page_two && n > 51) ids[51] <- ids[50]
    env <- new.env()
    env$calls <- 0L
    env$offsets <- integer(0)
    env$get_now <- function(path, query = list()) {
        env$calls <- env$calls + 1L
        offset <- query$offset
        env$offsets <- c(env$offsets, offset)
        if (!is.null(fail_at) && offset == fail_at) {
            return(list(state = "error", data = NULL, http_status = 500L, message = "Couldn't get this from Spotify. Please try again."))
        }
        idx <- seq_len(n)[seq_len(n) > offset & seq_len(n) <= offset + query$limit]
        items <- lapply(idx, function(i) list(
            id = ids[i], name = names[i], owner = list(display_name = "Pat"), public = (i %% 2 == 0),
            tracks = list(total = i), images = list(), external_urls = list(spotify = paste0("https://open.spotify.com/playlist/", ids[i]))
        ))
        list(state = "ok", data = list(items = items, total = n), http_status = 200L, message = NULL)
    }
    env$get <- function(path, query = list()) promises::promise_resolve(env$get_now(path, query))
    env
}

# One turn of the event loop: the answers that are ready are handled, then the reactives run
turn <- function(session, wait = 0) {
    later::run_now(wait)
    session$flushReact()
}

# Let the loader run until it is done (or gives up), a pause at a time
finish_loading <- function(session, status, max_steps = 600) {
    session$flushReact()
    for (i in seq_len(max_steps)) {
        turn(session, 0.02)
        if (!status() %in% c("loading")) break
    }
}

args_for <- function(api, authenticated = TRUE, active = TRUE, ...) {
    list(api_get = api$get, is_authenticated = reactiveVal(authenticated),
         tab_active = reactiveVal(active), pause_ms = 10, ...)
}

test_that("nothing is fetched until the tab is open and somebody is logged in", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api, active = FALSE), {
        session$flushReact(); turn(session, 0.1)
        expect_equal(status(), "idle")
        expect_equal(api$calls, 0)
    })
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api, authenticated = FALSE), {
        session$flushReact(); turn(session, 0.1)
        expect_equal(status(), "idle")
        expect_equal(api$calls, 0)
    })
})

test_that("the first page is there after one request, in Spotify's order", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        session$flushReact()
        turn(session)                      # the first answer
        expect_equal(status(), "loading")
        expect_equal(loaded(), 50L)
        expect_equal(total(), 120L)
        expect_equal(nrow(all_data()), 50)
        expect_equal(all_data()$id[1:3], c("id1", "id2", "id3"))   # not sorted
        # no letters yet: the filter is ignored while loading
        session$setInputs(letter = "A")
        expect_equal(nrow(filtered()), 50)
    })
})

test_that("it fetches one page at a time, until everything is here, and then sorts A-Z", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        expect_equal(status(), "done")
        expect_equal(loaded(), 120L)
        expect_equal(api$offsets, c(0, 50, 100))
        expect_equal(nrow(all_data()), 120)
        expect_equal(all_data()$name, playlist_sort(all_data())$name)
        expect_equal(substr(all_data()$name[1], 1, 5), "99 So")   # "#" ... see below
    })
})

test_that("the letter filter works once loading is done, and a new filter goes back to page 1", {
    api <- fake_spotify(240)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        session$setInputs(letter = "all")
        session$setInputs(next_top = 1); session$setInputs(next_top = 2)
        expect_equal(page(), 3L)

        session$setInputs(letter = "A")
        expect_equal(page(), 1L)
        expect_true(all(startsWith(filtered()$name, "Apple")))
        expect_equal(nrow(filtered()), 40)

        session$setInputs(letter = "Ä")
        expect_true(all(startsWith(filtered()$name, "Ääni")))
        session$setInputs(letter = "#")
        expect_true(all(startsWith(filtered()$name, "99")))
    })
})

test_that("paging stays within the pages", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        session$setInputs(letter = "all")
        expect_equal(page(), 1L)
        session$setInputs(prev_top = 1)
        expect_equal(page(), 1L)                 # not before the first
        session$setInputs(next_top = 1); session$setInputs(next_top = 2); session$setInputs(next_top = 3)
        expect_equal(page(), 3L)                 # not past the last (120 / 50 = 3 pages)
        session$setInputs(prev_bottom = 1)
        expect_equal(page(), 2L)
        session$setInputs(next_bottom = 1)
        expect_equal(page(), 3L)
    })
})

test_that("the list is not re-rendered for every batch", {
    api <- fake_spotify(4213)       # 85 pages, like the owner's account
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status, max_steps = 600)
        expect_equal(status(), "done")
        expect_equal(loaded(), 4213L)
        expect_equal(api$calls, 85L)
        # the start, the first page, and the end: a handful, not 85
        expect_lte(version(), 5L)
    })
})

test_that("a playlist added while loading is not shown twice", {
    api <- fake_spotify(120, duplicate_first_of_page_two = TRUE)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        expect_equal(status(), "done")
        expect_equal(nrow(all_data()), 119)
        expect_false(anyDuplicated(all_data()$id) > 0)
    })
})

test_that("a failure keeps what arrived, says so, and can be retried", {
    api <- fake_spotify(120, fail_at = 50)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        expect_equal(status(), "failed")
        expect_equal(loaded(), 50L)
        expect_equal(nrow(all_data()), 50)

        before <- api$calls
        session$setInputs(retry = 1)
        session$flushReact()
        expect_gt(api$calls, before)
        expect_equal(api$offsets[length(api$offsets)], 0)    # starts again from the beginning
    })
})

test_that("logging out empties the list, and the next login starts afresh", {
    api <- fake_spotify(120)
    auth <- reactiveVal(TRUE)
    testServer(playlists_server, args = list(api_get = api$get, is_authenticated = auth,
                                             tab_active = reactiveVal(TRUE), pause_ms = 10), {
        finish_loading(session, status)
        expect_equal(nrow(all_data()), 120)

        auth(FALSE); session$flushReact()
        expect_equal(status(), "idle")
        expect_null(all_data())
        expect_equal(loaded(), 0L)

        calls <- api$calls
        auth(TRUE); session$flushReact()
        expect_equal(status(), "loading")
        expect_gt(api$calls, calls)
    })
})

test_that("playlist_card shows what there is and nothing that isn't", {
    row <- tibble(id = "a", name = "Jazz <b>bold</b>", description = "", track_count = 3L, owner = "Pat",
                  is_public = TRUE, image_url = NA_character_, spotify_url = NA_character_)
    html <- as.character(playlist_card(row))
    expect_match(html, "Jazz &lt;b&gt;bold&lt;/b&gt;", fixed = TRUE)    # escaped
    expect_match(html, "3 tracks")
    expect_false(grepl("<a ", html, fixed = TRUE))                       # no link without an address
    row$spotify_url <- "https://open.spotify.com/playlist/a"
    expect_match(as.character(playlist_card(row)), 'rel="noopener noreferrer"', fixed = TRUE)
})

test_that("an answer that arrives after a logout is dropped", {
    resolve_late <- NULL
    late <- promises::promise(function(resolve, reject) resolve_late <<- resolve)
    asked <- 0L
    api_get <- function(path, query = list()) { asked <<- asked + 1L; late }
    auth <- reactiveVal(TRUE)
    testServer(playlists_server, args = list(api_get = api_get, is_authenticated = auth,
                                             tab_active = reactiveVal(TRUE), pause_ms = 10), {
        session$flushReact(); turn(session)
        expect_equal(status(), "loading")
        expect_equal(asked, 1L)

        auth(FALSE); session$flushReact()
        expect_equal(status(), "idle")

        # Spotify answers now, for a login that no longer exists
        resolve_late(list(state = "ok", http_status = 200L, message = NULL,
                          data = list(total = 1L, items = list(list(id = "x", name = "Secret", owner = list(display_name = "Pat"),
                                                                    public = TRUE, tracks = list(total = 1L), images = list(),
                                                                    external_urls = list(spotify = "https://open.spotify.com/playlist/x"))))))
        turn(session, 0.05)
        expect_equal(status(), "idle")
        expect_null(all_data())
        expect_equal(loaded(), 0L)
        expect_equal(asked, 1L)           # and it did not ask for more
    })
})

test_that("a request that fails outright ends the load visibly, not the session", {
    api_get <- function(path, query = list()) promises::promise_reject(simpleError("boom"))
    testServer(playlists_server, args = list(api_get = api_get, is_authenticated = reactiveVal(TRUE),
                                             tab_active = reactiveVal(TRUE), pause_ms = 10), {
        session$flushReact(); turn(session, 0.05)
        expect_equal(status(), "failed")
    })
})

test_that("while loading, pages that have arrived can be opened, and only those", {
    api <- fake_spotify(1000)
    testServer(playlists_server, args = args_for(api), {
        session$flushReact(); turn(session)              # first page (50)
        expect_equal(available(), 50L)
        session$setInputs(next_top = 1)
        expect_equal(page(), 1L)                         # nothing beyond what has arrived

        for (i in 1:3) turn(session, 0.02)                # a few more pages (up to 200)
        expect_gte(available(), 150L)
        session$setInputs(next_top = 2)
        expect_equal(page(), 2L)
        # page 2 holds what Spotify listed 51-100, not an old copy of page 1
        expect_equal(playlist_page(all_data(), page(), 50)$id[1], "id51")
        expect_equal(status(), "loading")

        # and the text speaks of all of them, not of what has arrived
        expect_equal(shown_total(), 1000L)
        expect_match(playlist_range_note(page(), 50, shown_total()), "of 1,000 playlists")
    })
})

test_that("the pager knows the page count from the first answer", {
    api <- fake_spotify(4213)
    testServer(playlists_server, args = args_for(api), {
        session$flushReact(); turn(session)
        expect_equal(shown_total(), 4213L)
        expect_equal(playlist_page_count(shown_total(), 50), 85L)
        expect_equal(output$label_top, "Page 1 of 85")
        expect_true(pager_visible())
        expect_match(output$list$html, "of 4,213 playlists")
    })
})

test_that("Previous is off on the first page and Next on the last", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        session$setInputs(letter = "all")
        expect_equal(buttons_off(), list(prev = TRUE, `next` = FALSE))

        session$setInputs(next_top = 1)
        expect_equal(buttons_off(), list(prev = FALSE, `next` = FALSE))
        session$setInputs(next_top = 2)
        expect_equal(page(), 3L)
        expect_equal(buttons_off(), list(prev = FALSE, `next` = TRUE))
        expect_equal(output$label_top, "Page 3 of 3")
        expect_equal(output$label_bottom, "Page 3 of 3")
    })
})

test_that("the pager is shown only when there is more than one page", {
    api <- fake_spotify(30)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        expect_false(pager_visible())
    })
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        expect_true(pager_visible())
    })
})

test_that("the letter filter is offered once everything is loaded, with Å Ä Ö after Z", {
    api <- fake_spotify(120)
    testServer(playlists_server, args = args_for(api), {
        finish_loading(session, status)
        choices <- playlist_letter_choices(all_data()$name)
        expect_equal(unname(choices), c("all", "#", "A", "B", "M", "Z", "\u00c4"))
    })
})

test_that("parsing a page of playlists is fast inside Shiny code", {
    # A tibble() per playlist took 230 ms per page inside the running app (30x slower than a
    # page built from columns), which blocked the session for seconds over 85 pages.
    items <- lapply(1:50, function(i) list(
        id = paste0("id", i), name = paste("P", i), owner = list(display_name = "A"), public = TRUE,
        tracks = list(total = i), images = list(), external_urls = list(spotify = paste0("https://x/", i))))
    testServer(function(id) moduleServer(id, function(input, output, session) {}), args = list(), {
        elapsed <- system.time(for (i in 1:5) parse_playlists_page(items))[["elapsed"]] / 5
        expect_lt(elapsed, 0.04)        # measured: 3 ms; the per-playlist version: 92 ms
    })
})

# ---- the copy kept in the browser ----

# Stands in for the browser: remembers the messages the module sends
message_log <- function() {
    env <- new.env(); env$sent <- list()
    env$send <- function(type, message) env$sent[[length(env$sent) + 1L]] <- list(type = type, message = message)
    env$of_type <- function(type) Filter(function(m) m$type == type, env$sent)
    env
}

# What the browser sends back: a list of rows, as Shiny delivers a JSON array of objects
browser_copy <- function(names, ids = paste0("old", seq_along(names))) {
    list(saved_at = "2026-10-24T10:00:00Z", items = lapply(seq_along(names), function(i) list(
        id = ids[i], name = names[i], owner = "Pat", track_count = i, is_public = TRUE,
        spotify_url = paste0("https://open.spotify.com/playlist/", ids[i]))))
}

copy_args <- function(api, log, user = "u1", ...) {
    c(args_for(api, ...), list(user_id = reactiveVal(user), send_message = log$send))
}

test_that("the copy is asked for once per login, under the account's name, as soon as it is known", {
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        session$flushReact()
        asked <- log$of_type("playlist_cache_load")
        expect_length(asked, 1)
        expect_equal(asked[[1]]$message$key, "trackteller.playlists.u1")
        expect_match(asked[[1]]$message$input_id, "cache$")
        turn(session, 0.05)
        expect_length(log$of_type("playlist_cache_load"), 1)    # not again
    })

    # not before it is known whose it is
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = c(args_for(api), list(user_id = reactiveVal(NULL), send_message = log$send)), {
        session$flushReact(); turn(session, 0.05)
        expect_length(log$of_type("playlist_cache_load"), 0)
    })
})

test_that("a saved copy is on screen at once, A-Z, with the letters, while the real list loads", {
    api <- fake_spotify(1000); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        session$flushReact()
        session$setInputs(cache = browser_copy(c("zebra", "Äiti", "Apple", "99 songs", "banana")))
        session$flushReact()

        expect_true(cache_present())
        expect_equal(status(), "loading")                       # the real list is on its way
        expect_equal(all_data()$name, c("99 songs", "Apple", "banana", "zebra", "Äiti"))
        expect_true(sorted_view())                                 # the letter filter works already
        expect_equal(unname(playlist_letter_choices(all_data()$name)), c("all", "#", "A", "B", "Z", "Ä"))
        # the pager and the note follow the copy, not the 1,000 that are still arriving
        expect_equal(shown_total(), 5L)
        session$setInputs(letter = "A")
        expect_equal(filtered()$name, "Apple")

        # more of the real list arriving does not change what is on screen
        turn(session, 0.05); turn(session, 0.05)
        expect_gt(loaded(), 50L)
        expect_equal(nrow(all_data()), 5)
    })
})

test_that("when the real list is complete it replaces the copy, and a new copy is saved", {
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        session$flushReact()
        session$setInputs(cache = browser_copy(c("old one", "old two")))
        session$flushReact()
        expect_equal(nrow(all_data()), 2)

        finish_loading(session, status)
        expect_equal(status(), "done")
        expect_false(cache_present())
        expect_equal(nrow(all_data()), 120)
        expect_false(any(startsWith(all_data()$id, "old")))

        saved <- log$of_type("playlist_cache_save")
        expect_length(saved, 1)
        expect_equal(saved[[1]]$message$key, "trackteller.playlists.u1")
        expect_length(saved[[1]]$message$items, 120)
        expect_match(saved[[1]]$message$saved_at, "^\\d{4}-\\d{2}-\\d{2}T")
        expect_setequal(names(saved[[1]]$message$items[[1]]),
                        c("id", "name", "owner", "track_count", "is_public", "spotify_url"))   # image_url is missing in this data
    })
})

test_that("without a copy, a finished load is saved too", {
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        finish_loading(session, status)
        expect_length(log$of_type("playlist_cache_save"), 1)
    })
})

test_that("nothing is saved when the load failed, or when it is not known whose list it is", {
    api <- fake_spotify(120, fail_at = 50); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        finish_loading(session, status)
        expect_equal(status(), "failed")
        expect_length(log$of_type("playlist_cache_save"), 0)
    })
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = c(args_for(api), list(user_id = reactiveVal(NULL), send_message = log$send)), {
        finish_loading(session, status)
        expect_equal(status(), "done")
        expect_length(log$of_type("playlist_cache_save"), 0)
    })
})

test_that("an empty, damaged or late copy is ignored", {
    api <- fake_spotify(120); log <- message_log()
    testServer(playlists_server, args = copy_args(api, log), {
        session$flushReact()
        session$setInputs(cache = list(items = list()))                     # nothing saved
        expect_false(cache_present())
        session$setInputs(cache = list(items = list("rubbish", 42, NULL)))   # damaged
        expect_false(cache_present())
        finish_loading(session, status)
        session$setInputs(cache = browser_copy(c("late one")))               # after the real list: no use
        session$flushReact()
        expect_false(cache_present())
        expect_equal(nrow(all_data()), 120)
    })
})

test_that("logging out empties the copy in memory and in the browser, and the next login asks again", {
    api <- fake_spotify(120); log <- message_log()
    auth <- reactiveVal(TRUE)
    testServer(playlists_server, args = c(list(api_get = api$get, is_authenticated = auth, tab_active = reactiveVal(TRUE),
                                               pause_ms = 10, user_id = reactiveVal("u1"), send_message = log$send)), {
        session$flushReact()
        session$setInputs(cache = browser_copy(c("a", "b")))
        session$flushReact()
        expect_true(cache_present())

        auth(FALSE); session$flushReact()
        expect_false(cache_present())
        expect_null(all_data())
        cleared <- log$of_type("playlist_cache_clear")
        expect_length(cleared, 1)
        expect_equal(cleared[[1]]$message$prefix, "trackteller.playlists.")

        auth(TRUE); session$flushReact()
        expect_length(log$of_type("playlist_cache_load"), 2)
    })
})
