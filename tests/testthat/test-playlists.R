source(file.path(app_dir, "scripts", "playlists.R"))

pl <- function(names, ...) {
    tibble(
        id = paste0("id", seq_along(names)), name = names, description = "",
        track_count = seq_along(names), owner = "Pat", is_public = TRUE,
        image_url = NA_character_, spotify_url = "https://open.spotify.com/playlist/x", ...
    )
}

test_that("playlists are filed under their first letter, with Å Ä Ö after Z", {
    expect_equal(playlist_first_letter(c("Jazz", "jazz night", "Ääni", "öljy", "Åland", "99 Luftballons", "!!!", "", NA)),
                 c("J", "J", "Ä", "Ö", "Å", "#", "#", "#", "#"))
})

test_that("sorting is A-Z, case-insensitive, with Å Ä Ö after Z", {
    out <- playlist_sort(pl(c("zebra", "Äiti", "Apple", "banana", "Ålesund", "Ödön", "Zoo")))
    expect_equal(out$name, c("Apple", "banana", "zebra", "Zoo", "Ålesund", "Äiti", "Ödön"))
    expect_equal(nrow(playlist_sort(pl(character(0)))), 0)
    # a missing name doesn't break it
    expect_equal(nrow(playlist_sort(pl(c("b", NA, "a")))), 3)
})

test_that("the letter choices list only the letters that exist", {
    ch <- playlist_letter_choices(c("Jazz", "Blues", "99 Balloons", "Ääni", "Blue"))
    expect_equal(unname(ch), c("all", "#", "B", "J", "Ä"))
    expect_equal(names(ch)[1], "All playlists")
    expect_equal(unname(playlist_letter_choices(c("a", "b"))), c("all", "A", "B"))
    expect_equal(unname(playlist_letter_choices(character(0))), "all")
})

test_that("filtering by letter, or not at all", {
    d <- pl(c("Jazz", "Blues", "Jive", "99", "Ääni"))
    expect_equal(filter_playlists(d, "J")$name, c("Jazz", "Jive"))
    expect_equal(filter_playlists(d, "#")$name, "99")
    expect_equal(filter_playlists(d, "Ä")$name, "Ääni")
    expect_equal(nrow(filter_playlists(d, "all")), 5)
    expect_equal(nrow(filter_playlists(d, NULL)), 5)
    expect_equal(nrow(filter_playlists(d, "Q")), 0)
})

test_that("paging counts and slices pages", {
    expect_equal(playlist_page_count(0), 1L)
    expect_equal(playlist_page_count(50), 1L)
    expect_equal(playlist_page_count(51), 2L)
    expect_equal(playlist_page_count(4213), 85L)

    d <- pl(sprintf("p%03d", 1:120))
    expect_equal(nrow(playlist_page(d, 1, 50)), 50)
    expect_equal(playlist_page(d, 2, 50)$name[1], "p051")
    expect_equal(nrow(playlist_page(d, 3, 50)), 20)
    # outside the range is moved into it
    expect_equal(playlist_page(d, 99, 50)$name[1], "p101")
    expect_equal(playlist_page(d, 0, 50)$name[1], "p001")
    expect_equal(nrow(playlist_page(pl(character(0)), 1, 50)), 0)
})

test_that("the range note says what is shown", {
    expect_equal(playlist_range_note(1, 50, 0), "No playlists")
    expect_equal(playlist_range_note(1, 50, 1), "Showing the only playlist")
    expect_equal(playlist_range_note(1, 50, 7), "Showing all 7 playlists")
    expect_equal(playlist_range_note(1, 50, 4213), "Showing 1–50 of 4,213 playlists")
    expect_equal(playlist_range_note(2, 50, 4213), "Showing 51–100 of 4,213 playlists")
    expect_equal(playlist_range_note(85, 50, 4213), "Showing 4,201–4,213 of 4,213 playlists")
})

test_that("the browser copy round-trips, without the missing fields", {
    d <- pl(c("Jazz", "Blues"))
    d$image_url[2] <- "https://i.scdn.co/image/abc"
    packed <- compact_playlists(d)
    expect_length(packed, 2)
    expect_false("image_url" %in% names(packed[[1]]))
    expect_equal(packed[[2]]$image_url, "https://i.scdn.co/image/abc")
    # as it comes back from JSON: a list of lists
    back <- sanitise_cached_playlists(jsonlite::fromJSON(jsonlite::toJSON(packed, auto_unbox = TRUE), simplifyVector = FALSE))
    expect_equal(back$name, c("Jazz", "Blues"))
    expect_equal(back$track_count, 1:2)
    expect_true(all(back$is_public))
    expect_equal(back$image_url[2], "https://i.scdn.co/image/abc")
    expect_true(is.na(back$image_url[1]))
})

test_that("a damaged or edited browser copy is cleaned, not trusted", {
    expect_null(sanitise_cached_playlists(NULL))
    expect_null(sanitise_cached_playlists("nonsense"))
    expect_null(sanitise_cached_playlists(list()))
    expect_null(sanitise_cached_playlists(list(1, "a", NULL)))

    out <- sanitise_cached_playlists(list(
        list(id = "a", name = "Good", owner = "Pat", track_count = 3, is_public = TRUE,
             image_url = "http://insecure/x.jpg", spotify_url = "javascript:alert(1)"),
        list(id = "b"),                                  # no name: dropped
        list(name = "No id"),                            # no id: dropped
        list(id = c("x", "y"), name = "Two ids"),        # not a single value: dropped
        list(id = "c", name = "Odd count", track_count = "many"),
        "not a row"
    ))
    expect_equal(out$name, c("Good", "Odd count"))
    expect_true(all(is.na(out$image_url)))    # only https links survive
    expect_true(all(is.na(out$spotify_url)))
    expect_equal(out$track_count, c(3L, 0L))
    expect_equal(out$owner[2], "Unknown")
    expect_false(out$is_public[2])
})

test_that("the browser copy is capped", {
    big <- lapply(1:30, function(i) list(id = as.character(i), name = paste("p", i)))
    expect_equal(nrow(sanitise_cached_playlists(big, max_rows = 10L)), 10)
})

test_that("a browser copy that arrives as a data frame is read the same", {
    rows <- data.frame(id = c("a", "b"), name = c("Jazz", "Blues"), owner = "Pat", track_count = c(3, 4),
                       is_public = c(TRUE, FALSE), stringsAsFactors = FALSE)
    rows$spotify_url <- c("https://open.spotify.com/playlist/a", NA)
    out <- sanitise_cached_playlists(rows)
    expect_equal(out$name, c("Jazz", "Blues"))
    expect_equal(out$track_count, c(3L, 4L))
    expect_equal(out$is_public, c(TRUE, FALSE))
    expect_true(is.na(out$spotify_url[2]))
})

test_that("packing 4,000 playlists for the browser takes well under a second", {
    big <- pl(sprintf("Playlist %04d", 1:4213))
    expect_lt(system.time(packed <- compact_playlists(big))[["elapsed"]], 1)
    expect_length(packed, 4213)
    expect_equal(packed[[4213]]$name, "Playlist 4213")
})

test_that("reading a browser copy of 4,000 playlists is fast, also inside Shiny code", {
    big <- compact_playlists(pl(sprintf("Playlist %04d", 1:4213)))
    testServer(function(id) moduleServer(id, function(input, output, session) {}), args = list(), {
        elapsed <- system.time(out <- sanitise_cached_playlists(big))[["elapsed"]]
        expect_equal(nrow(out), 4213)
        # one tibble() per row took ~20 s here; from columns it is a fraction of a second
        expect_lt(elapsed, 1)
    })
})
