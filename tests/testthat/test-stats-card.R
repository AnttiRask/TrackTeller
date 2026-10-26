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

test_that("names with Chinese, Japanese or Korean characters get the CJK font, others keep the card's", {
    expect_equal(card_font("Radiohead"), STATS_CARD$font)
    expect_equal(card_font("Mötley Crüe \u2013 \u0414\u044b\u043c"), STATS_CARD$font)
    expect_equal(card_font("\u5ba4\u5185\u697d"), STATS_CARD$font_cjk)                 # kanji
    expect_equal(card_font("\u3042\u3044\u3046"), STATS_CARD$font_cjk)                 # hiragana
    expect_equal(card_font("\u30ab\u30bf\u30ab\u30ca"), STATS_CARD$font_cjk)          # katakana
    expect_equal(card_font("\ubc29\ud0c4\uc18c\ub144\ub2e8"), STATS_CARD$font_cjk)  # hangul
    expect_equal(card_font("BTS (\ubc29\ud0c4\uc18c\ub144\ub2e8)"), STATS_CARD$font_cjk)  # mixed
    expect_equal(card_font("\uff21\uff22\uff23"), STATS_CARD$font_cjk)                 # fullwidth letters
    expect_equal(card_font(NA_character_), STATS_CARD$font)
})

test_that("a long name is cut with two dots", {
    expect_equal(trunc_str("short", 30), "short")
    expect_equal(trunc_str(strrep("a", 40), 30), paste0(strrep("a", 28), ".."))
})

test_that("truncation counts width: a CJK character takes the room of two letters", {
    kanji <- strrep("\u6f22", 40)
    cut <- trunc_str(kanji, 30)
    expect_equal(cut, paste0(strrep("\u6f22", 14), ".."))        # 14 x 2 + 2 = 30
    expect_lte(stringi::stri_width(cut), 30)
    expect_equal(trunc_str("\u6f22\u5b57", 30), "\u6f22\u5b57")
    expect_equal(trunc_str("", 30), "")
})

test_that("a picture that can't be fetched becomes a plain square", {
    img <- fetch_card_image("http://127.0.0.1:1/nothing.jpg", size = 40)
    expect_equal(size_of(img), c(40, 40))
    expect_equal(size_of(fetch_card_image(NA_character_, size = 40)), c(40, 40))
})

test_that("Chinese, Japanese and Korean names are drawn with real letters, not empty boxes", {
    # Needs the CJK font, which the image has (fonts-noto-cjk); elsewhere there is nothing to check
    skip_if_not(any(grepl("Noto Sans CJK", system("fc-list", intern = TRUE))), "no CJK font installed")

    card_with <- function(name) {
        data <- parse_top_artists(list(items = list(artist(name = name, images = list()))))
        stats_card_for("artists", data, "Pat", "short_term")
    }
    pixels <- function(img) as.integer(magick::image_data(img, channels = "gray"))

    # A missing glyph is the same box for every character: two different names then look alike
    expect_false(identical(pixels(card_with("\u5ba4\u5185\u697d")), pixels(card_with("\u30ab\u30bf\u30ab\u30ca"))))
    expect_false(identical(pixels(card_with("\u5ba4\u5185\u697d")), pixels(card_with("\ubc29\ud0c4\uc18c\ub144\ub2e8"))))
})
