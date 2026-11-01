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

everything <- function(url) TRUE      # for the local server, which is not one of Spotify's hosts

test_that("pictures are fetched and scaled, in order, and anything that fails becomes a plain square", {
    server <- start_image_server()
    withr::defer(server$proc$kill())
    urls <- paste0(server$url, c("/ok.jpg", "/missing.jpg", "/ok.png", NA, ""))

    pictures <- fetch_card_images(urls, size = 40, allowed = everything)
    expect_length(pictures, 5)
    for (picture in pictures) expect_equal(size_of(picture), c(40, 40))

    # the real ones are the green of the test image, the failed ones the placeholder grey
    pixel <- function(picture) as.character(magick::image_data(magick::image_crop(picture, "1x1+20+20"), channels = "rgb"))[1:3]
    expect_equal(paste(pixel(pictures[[1]]), collapse = ""), "1db954")
    expect_equal(paste(pixel(pictures[[3]]), collapse = ""), "1db954")
    expect_equal(paste(pixel(pictures[[2]]), collapse = ""), "282828")
    expect_equal(paste(pixel(pictures[[4]]), collapse = ""), "282828")
})

test_that("only addresses on Spotify's image hosts are contacted", {
    server <- start_image_server()
    withr::defer(server$proc$kill())

    # the default rule: the local server is not Spotify, so it is never asked
    pictures <- fetch_card_images(paste0(server$url, "/ok.jpg"), size = 40)
    expect_equal(size_of(pictures[[1]]), c(40, 40))
    expect_length(server$hits(), 0)

    # and so are not addresses that only look like Spotify's
    for (url in c("http://i.scdn.co/image/a", "https://i.scdn.co.evil.example/a", "https://evil.example/i.scdn.co/a",
                  "https://i.scdn.co@evil.example/a", "file:///etc/passwd", "ftp://i.scdn.co/a", "/etc/passwd")) {
        expect_equal(size_of(fetch_card_images(url, size = 40)[[1]]), c(40, 40))
    }
})

test_that("a picture that arrives late is given up on, and the others still come", {
    server <- start_image_server(slow = 4)
    withr::defer(server$proc$kill())
    urls <- paste0(server$url, c("/ok.jpg", "/slow.jpg", "/ok.png"))

    elapsed <- system.time(pictures <- fetch_card_images(urls, size = 40, timeout = 1, allowed = everything))[["elapsed"]]
    expect_lt(elapsed, 3.5)                   # not the 4 s the slow one takes
    expect_length(pictures, 3)
    pixel <- function(picture) paste(as.character(magick::image_data(magick::image_crop(picture, "1x1+20+20"), channels = "rgb"))[1:3], collapse = "")
    expect_equal(c(pixel(pictures[[1]]), pixel(pictures[[2]]), pixel(pictures[[3]])), c("1db954", "282828", "1db954"))
})

test_that("redirects are not followed, and pages and oversized files are not turned into pictures", {
    server <- start_image_server()
    withr::defer(server$proc$kill())
    urls <- paste0(server$url, c("/redirect.jpg", "/page.jpg", "/big.jpg"))

    pictures <- fetch_card_images(urls, size = 40, max_bytes = 100000, allowed = everything)
    pixel <- function(picture) paste(as.character(magick::image_data(magick::image_crop(picture, "1x1+20+20"), channels = "rgb"))[1:3], collapse = "")
    expect_equal(vapply(pictures, pixel, character(1)), rep("282828", 3))
    # the redirect's target was never asked for
    expect_false("/ok.jpg" %in% names(server$hits()))
})

test_that("only the start of a JPEG, a PNG or a WebP counts as a picture", {
    expect_true(card_image_bytes(as.raw(c(0xFF, 0xD8, 0xFF, 0xE0, rep(0, 12)))))
    expect_true(card_image_bytes(as.raw(c(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, rep(0, 8)))))
    expect_true(card_image_bytes(c(charToRaw("RIFF"), as.raw(c(1, 2, 3, 4)), charToRaw("WEBPVP8 "))))
    expect_false(card_image_bytes(charToRaw("<html>not a picture at all</html>")))
    expect_false(card_image_bytes(charToRaw("%!PS-Adobe-3.0 EPSF")))          # PostScript: ImageMagick would run it
    expect_false(card_image_bytes(charToRaw("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")))
    expect_false(card_image_bytes(c(charToRaw("RIFF"), as.raw(c(1, 2, 3, 4)), charToRaw("WAVEfmt "))))
    expect_false(card_image_bytes(raw(0)))
    expect_false(card_image_bytes(NULL))
    expect_false(card_image_bytes("FF D8 FF"))
})

test_that("a card is still made when no picture can be had at all", {
    data <- parse_top_artists(list(items = lapply(1:10, function(i) artist(id = paste0("a", i), name = paste("Artist", i),
                                                                           images = list(list(url = "https://i.scdn.co/image/x"))))))
    # no network in the tests: every fetch fails, every picture is a placeholder
    elapsed <- system.time(img <- stats_card_for("artists", data, "Pat", "short_term"))[["elapsed"]]
    expect_equal(size_of(img), c(1200, 630))
    expect_lt(elapsed, 30)
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
