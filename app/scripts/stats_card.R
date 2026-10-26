# The shareable stats card: a 1200x630 PNG with the top ten artists or tracks.
# Everything here is pure (a data frame in, an image out), so it runs in the tests too.

# Download an image from a URL and resize it; returns a blank placeholder on failure
fetch_card_image <- function(url, size = STATS_CARD$image_size) {
    tryCatch({
        if (!is.na(url) && nzchar(url)) {
            art <- image_read(url)
            image_scale(art, paste0(size, "x", size, "!"))
        } else {
            image_blank(size, size, color = STATS_CARD$placeholder)
        }
    }, error = function(e) {
        image_blank(size, size, color = STATS_CARD$placeholder)
    })
}

# Truncate a string to max_chars with ".." suffix if needed
trunc_str <- function(s, max_chars = 32) {
    if (nchar(s) > max_chars) paste0(substr(s, 1, max_chars - 2), "..") else s
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
        size = 38, color = "#1DB954", font = "Liberation Sans",
        weight = 700, gravity = "NorthWest", location = "+40+18"
    )
    img <- image_annotate(img, time_label,
        size = 22, color = "#b3b3b3", font = "Liberation Sans",
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
        img_url <- if (type == "artists") top10$image_url[i] else top10$album_image_url[i]
        art_img <- fetch_card_image(img_url, img_size)
        img <- image_composite(img, art_img, offset = paste0("+", x_img, "+", y_base + 10L))

        if (type == "artists") {
            # Single text line: rank + name
            img <- image_annotate(img, paste0("#", i),
                size = 18L, color = "#1DB954", font = "Liberation Sans",
                weight = 700L, gravity = "NorthWest",
                location = paste0("+", x_txt, "+", y_base + 30L)
            )
            name <- trunc_str(top10$name[i], 30L)
            img <- image_annotate(img, name,
                size = 22L, color = "#FFFFFF", font = "Liberation Sans",
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 28L)
            )
        } else {
            # Two text lines: rank + track name, then artist
            img <- image_annotate(img, paste0("#", i),
                size = 18L, color = "#1DB954", font = "Liberation Sans",
                weight = 700L, gravity = "NorthWest",
                location = paste0("+", x_txt, "+", y_base + 22L)
            )
            tname <- trunc_str(top10$name[i], 26L)
            img <- image_annotate(img, tname,
                size = 20L, color = "#FFFFFF", font = "Liberation Sans",
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 18L)
            )
            aname <- trunc_str(top10$artist[i], 26L)
            img <- image_annotate(img, aname,
                size = 17L, color = "#b3b3b3", font = "Liberation Sans",
                gravity = "NorthWest",
                location = paste0("+", x_txt + 48L, "+", y_base + 46L)
            )
        }
    }

    # ---- Footer ----
    img <- image_annotate(img, "trackteller.youcanbeapirate.com",
        size = 18L, color = "#555555", font = "Liberation Sans",
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
