source(file.path(app_dir, "scripts", "display.R"))

test_that("displayed_count is what was asked for, capped by what exists", {
    expect_equal(displayed_count(20, 50), 20L)
    expect_equal(displayed_count(30, 32), 30L)
    expect_equal(displayed_count(50, 37), 37L)
    expect_equal(displayed_count(50, 48, cap = 20), 20L)
    expect_equal(displayed_count(10, 48, cap = 20), 10L)
    expect_equal(displayed_count(20, 7, cap = 20), 7L)
    expect_equal(displayed_count(20, NULL), 0L)
    expect_equal(displayed_count(20, NA), 0L)
})

test_that("count_note says what is shown", {
    expect_equal(count_note(20, 50, "artist", "artists"), "Showing 20 of 50 artists")
    expect_equal(count_note(50, 32, "artist", "artists"), "Showing all 32 artists")
    expect_equal(count_note(32, 32, "artist", "artists"), "Showing all 32 artists")
    expect_equal(count_note(50, 37, "track", "tracks"), "Showing all 37 tracks")
    expect_equal(count_note(20, 1, "track", "tracks"), "Showing the only track")
})

test_that("count_note explains a cap, but only when the cap is what limits the list", {
    expect_equal(count_note(50, 48, "genre", "genres", cap = 20),
                 "Showing 20 of 48 genres (the chart shows at most 20)")
    expect_equal(count_note(10, 48, "genre", "genres", cap = 20), "Showing 10 of 48 genres")
    expect_equal(count_note(50, 12, "genre", "genres", cap = 20), "Showing all 12 genres")
})

test_that("count_note says nothing when there is nothing to show", {
    expect_null(count_note(20, 0, "artist", "artists"))
    expect_null(count_note(20, NULL, "artist", "artists"))
    expect_null(count_note(20, NA, "artist", "artists"))
})

test_that("sanitise_prefs keeps valid choices", {
    out <- sanitise_prefs(list(time_range = "long_term", shown_count = 30))
    expect_equal(out$time_range, "long_term")
    expect_equal(out$shown_count, 30L)
    # every allowed step
    for (n in seq(COUNT_MIN, COUNT_MAX, by = COUNT_STEP)) {
        expect_equal(sanitise_prefs(list(shown_count = n))$shown_count, as.integer(n))
    }
})

test_that("sanitise_prefs drops anything that is not a valid choice", {
    expect_equal(sanitise_prefs(list()), list())
    expect_equal(sanitise_prefs(NULL), list())
    expect_equal(sanitise_prefs("long_term"), list())
    expect_null(sanitise_prefs(list(time_range = "forever"))$time_range)
    expect_null(sanitise_prefs(list(time_range = c("short_term", "long_term")))$time_range)
    expect_null(sanitise_prefs(list(time_range = 3))$time_range)
    for (bad in list(5, 55, 12, 20.5, "many", NA, -10, list(), c(10, 20))) {
        expect_null(sanitise_prefs(list(shown_count = bad))$shown_count, info = format(bad))
    }
    # a good value next to a bad one is still kept
    out <- sanitise_prefs(list(time_range = "nope", shown_count = 40))
    expect_null(out$time_range)
    expect_equal(out$shown_count, 40L)
})
