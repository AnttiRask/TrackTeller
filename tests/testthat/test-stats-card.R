skip_if_not_installed("magick")

size_of <- function(img) {
    info <- magick::image_info(img)
    c(info$width, info$height)
}

test_that("the card for artists is 1200 by 630, also with fewer than ten and with missing images", {
    data <- parse_top_artists(list(items = list(artist(images = list()), artist("a2", "Two", images = list()))))
    img <- stats_card_for("artists", data, "Pat", "short_term")
    expect_equal(size_of(img), c(1200, 630))
})

test_that("the card for tracks is 1200 by 630", {
    data <- parse_top_tracks(list(items = list(track(album = "A"), track("t2", "Two"))))
    # the album pictures are not reachable in the tests: the placeholder takes their place
    data$album_image_url <- NA_character_
    expect_equal(size_of(stats_card_for("tracks", data, "", "long_term")), c(1200, 630))
})

test_that("with nothing to show the card says so, at the same size", {
    expect_equal(size_of(stats_card_for("artists", NULL, "Pat", "short_term")), c(1200, 630))
    expect_equal(size_of(stats_card_for("tracks", parse_top_tracks(list(items = list())), "Pat", "short_term")), c(1200, 630))
})

test_that("a time range the card doesn't know falls back to All Time instead of failing", {
    data <- parse_top_artists(list(items = list(artist(images = list()))))
    expect_no_error(stats_card_for("artists", data, "Pat", "nonsense"))
    expect_no_error(stats_card_for("artists", data, "Pat", NULL))
})

test_that("a long name is cut with two dots", {
    expect_equal(trunc_str("short", 30), "short")
    expect_equal(trunc_str(strrep("a", 40), 30), paste0(strrep("a", 28), ".."))
})

test_that("a picture that can't be fetched becomes a plain square", {
    img <- fetch_card_image("http://127.0.0.1:1/nothing.jpg", size = 40)
    expect_equal(size_of(img), c(40, 40))
    expect_equal(size_of(fetch_card_image(NA_character_, size = 40)), c(40, 40))
})
