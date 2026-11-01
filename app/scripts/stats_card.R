# The shareable stats card: a 1200x630 PNG with the top ten artists or tracks.
# Everything here is pure (a data frame in, an image out), so it runs in the tests too.

# The pictures of a card, fetched all at once instead of one after another. ImageMagick's own
# download has no timeout (one slow answer held a whole card up) and accepts any address and
# follows redirects, so the pictures are fetched here instead:
#   - only addresses `allowed` lets through are contacted (Spotify's image hosts)
#   - redirects are not followed, each picture has a time limit and a size limit
#   - only bytes that start like a JPEG, PNG or WebP are handed to ImageMagick
# Whatever fails, for whatever reason, becomes a plain square: the card is made anyway.
# Returns a list of magick images, one per url, in order.
fetch_card_images <- function(urls, size = STATS_CARD$image_size, timeout = 5, max_bytes = 2e6,
                              max_active = 5, allowed = function(url) !is.na(spotify_image(url))) {
    urls <- as.character(urls)
    pictures <- vector("list", length(urls))

    wanted <- which(!is.na(urls) & nzchar(urls) & vapply(urls, allowed, logical(1)))
    if (length(wanted) > 0) {
        requests <- lapply(urls[wanted], function(url) {
            httr2::request(url) |>
                httr2::req_user_agent("TrackTeller (https://trackteller.youcanbeapirate.com)") |>
                httr2::req_timeout(timeout) |>
                httr2::req_options(followlocation = FALSE, maxfilesize = max_bytes) |>
                httr2::req_error(is_error = function(resp) FALSE)
        })
        responses <- tryCatch(
            httr2::req_perform_parallel(requests, max_active = max_active, on_error = "continue", progress = FALSE),
            error = function(e) vector("list", length(requests))
        )

        for (k in seq_along(wanted)) {
            resp <- responses[[k]]
            if (!inherits(resp, "httr2_response") || httr2::resp_status(resp) != 200L) next
            bytes <- tryCatch(httr2::resp_body_raw(resp), error = function(e) NULL)
            if (is.null(bytes) || length(bytes) > max_bytes || !card_image_bytes(bytes)) next
            # list(...) so that a NULL stays an entry instead of deleting it
            pictures[wanted[k]] <- list(tryCatch(
                image_scale(image_read(bytes), paste0(size, "x", size, "!")),
                error = function(e) NULL
            ))
        }
    }

    lapply(pictures, function(picture) picture %||% image_blank(size, size, color = STATS_CARD$placeholder))
}

# Does this start like a JPEG, a PNG or a WebP? (The formats Spotify serves; nothing else
# is handed to ImageMagick, which understands many formats and some of them run code.)
card_image_bytes <- function(bytes) {
    if (!is.raw(bytes) || length(bytes) < 12) return(FALSE)
    identical(bytes[1:3], as.raw(c(0xFF, 0xD8, 0xFF))) ||
        identical(bytes[1:4], as.raw(c(0x89, 0x50, 0x4E, 0x47))) ||
        (identical(bytes[1:4], charToRaw("RIFF")) && identical(bytes[9:12], charToRaw("WEBP")))
}

# The font for a text. ImageMagick uses one font for a whole text and doesn't fall back
# per character, so a text with any Chinese, Japanese or Korean in it is set in the CJK
# font (which has the Latin letters too); everything else keeps the card's own font.
card_font <- function(text) {
    cjk <- "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}\\x{3000}-\\x{303F}\\x{FF00}-\\x{FFEF}]"
    if (isTRUE(stringr::str_detect(text, cjk))) STATS_CARD$font_cjk else STATS_CARD$font
}

# Truncate a string to max_chars with ".." suffix if needed. max_chars counts widths, not
# characters: a Chinese, Japanese or Korean character is as wide as two letters.
trunc_str <- function(s, max_chars = 32) {
    if (stringi::stri_width(s) <= max_chars) return(s)
    chars <- strsplit(s, "")[[1]]
    keep <- cumsum(stringi::stri_width(chars)) <= max_chars - 2
    paste0(paste(chars[keep], collapse = ""), "..")
}

# Build a 1200x630 stats card using magick
# type = "artists" or "tracks"
build_stats_card <- function(data, username, time_label, type) {
    W <- 1200L; H <- 630L

    img <- image_blank(W, H, color = "#191414")

    # ---- Header ----
    title_text <- if (nzchar(username)) {
        paste0(username, "\u2019s Top ", if (type == "artists") "Artists" else "Tracks")
    } else {
        paste0("My Top ", if (type == "artists") "Artists" else "Tracks")
    }

    img <- image_annotate(img, title_text,
        size = 38, color = "#1DB954", font = card_font(title_text),
        weight = 700, gravity = "NorthWest", location = "+40+18"
    )
    img <- image_annotate(img, time_label,
        size = 22, color = "#b3b3b3", font = STATS_CARD$font,
        gravity = "NorthWest", location = "+40+65"
    )

    # Header separator
    hline <- image_blank(1120L, 2L, color = "#2d2d2d")
    img <- image_composite(img, hline, offset = "+40+97")

    # Vertical column separator
    vline <- image_blank(2L, 470L, color = "#2d2d2d")
    img <- image_composite(img, vline, offset = "+600+103")

    # ---- Layout constants ----
    img_size    <- 70L
    row_h       <- 90L
    start_y     <- 108L
    left_img_x  <- 40L
    left_txt_x  <- 122L   # left_img_x + img_size + 12
    right_img_x <- 622L
    right_txt_x <- 704L   # right_img_x + img_size + 12

    top10 <- head(data, 10)

    # All the pictures at once, before the card is drawn
    picture_urls <- if (type == "artists") top10$image_url else top10$album_image_url
    pictures <- fetch_card_images(picture_urls, img_size)

    for (i in seq_len(nrow(top10))) {
        col    <- if (i <= 5L) 1L else 2L
        row    <- if (i <= 5L) i  else i - 5L
        x_img  <- if (col == 1L) left_img_x  else right_img_x
        x_txt  <- if (col == 1L) left_txt_x  else right_txt_x
        y_base <- start_y + (row - 1L) * row_h

        # Subtle row background (alternating)
        if (row %% 2L == 0L) {
            row_bg <- image_blank(550L, row_h - 4L, color = "#1d1d1d")
            img <- image_composite(img, row_bg, offset = paste0("+", x_img - 4L, "+", y_base + 4L))
        }

        # Image (artist photo or album art)
        img <- image_composite(img, pictures[[i]], offset = paste0("+", x_img, "+", y_base + 10L))

        if (type == "artists") {
            # Single text line: rank + name
            img <- image_annotate(img, paste0("#", i),
                size = 18L, color = "#1DB954", font = STATS_CARD$font,
                weight = 700L, gravity = "NorthWest",
                location = paste0("+", x_txt, "+", y_base + 30L)
            )
            name <- trunc_str(top10$name[i], 30L)
            img <- image_annotate(img, name,
                size = 22L, color = "#FFFFFF", font = card_font(name),
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 28L)
            )
        } else {
            # Two text lines: rank + track name, then artist
            img <- image_annotate(img, paste0("#", i),
                size = 18L, color = "#1DB954", font = STATS_CARD$font,
                weight = 700L, gravity = "NorthWest",
                location = paste0("+", x_txt, "+", y_base + 22L)
            )
            tname <- trunc_str(top10$name[i], 26L)
            img <- image_annotate(img, tname,
                size = 20L, color = "#FFFFFF", font = card_font(tname),
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 18L)
            )
            aname <- trunc_str(top10$artist[i], 26L)
            img <- image_annotate(img, aname,
                size = 17L, color = "#b3b3b3", font = card_font(aname),
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 46L)
            )
        }
    }

    # ---- Footer ----
    img <- image_annotate(img, "trackteller.youcanbeapirate.com",
        size = 18L, color = "#555555", font = STATS_CARD$font,
        gravity = "South", location = "+0+18"
    )

    img
}

# The card for `type` ("artists" or "tracks") from the full list, or a plain
# "No data available" card when there is nothing to show
stats_card_for <- function(type, data, username, time_range) {
    if (is.null(data) || nrow(data) == 0) {
        img <- image_blank(STATS_CARD$width, STATS_CARD$height, color = STATS_CARD$background)
        return(image_annotate(img, TXT$card_no_data,
            size = 30L, color = "#ffffff", gravity = "Center"))
    }

    known <- length(time_range) == 1 && !is.na(time_range) && time_range %in% names(CARD_TIME_LABELS)
    time_label <- unname(CARD_TIME_LABELS[if (known) time_range else "long_term"])
    build_stats_card(data, username, time_label, type)
}
