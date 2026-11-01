# The cards of the Top Artists, Top Tracks and Recently Played lists. They differ only
# in the lines of text, the figures on the right and the class.

card_title  <- function(text) tags$div(style = "color: #fff; font-size: 1.1em; font-weight: 500;", text)
card_line   <- function(text) tags$div(style = "color: #b3b3b3; font-size: 0.9em; margin-top: 4px;", text)
card_detail <- function(text) tags$div(style = "color: #666; font-size: 0.85em; margin-top: 2px;", text)

# A figure on the right, green when it is the one to look at
card_figure <- function(text, accent = FALSE) {
    if (accent) tags$div(style = "color: #1DB954;", text) else tags$div(text)
}

# class:  "artist-card" or "track-card"
# rank:   what stands in the green number
# lines:  the card_title() / card_line() / card_detail() elements, in order
# figures: card_figure() elements, or NULL for none
# url:    the Spotify link (NA when there is none: the card then has no Open button)
list_card <- function(class, rank, lines, figures = NULL, url) {
    tags$div(
        class = class,
        style = LIST_CARD_STYLE,
        tags$div(
            style = "color: #1DB954; font-size: 1.4em; font-weight: bold; width: 40px; text-align: center;",
            paste0("#", rank)
        ),
        tags$div(style = "flex: 1; margin-left: 15px;", lines),
        if (!is.null(figures)) tags$div(
            style = "text-align: right; color: #b3b3b3; font-size: 0.85em;",
            figures
        ),
        if (!is.na(url)) tags$a(
            href = url,
            target = "_blank",
            rel = "noopener noreferrer",
            style = paste0(
                "margin-left: 15px; padding: 8px 12px; ",
                "background: #1DB954; color: #fff; border-radius: 20px; ",
                "text-decoration: none; font-size: 0.85em; font-weight: 500; ",
                "display: flex; align-items: center; gap: 5px;"
            ),
            icon("spotify"),
            "Open"
        )
    )
}

# The rows of a list, in the one container that gives them their right padding
list_of_cards <- function(cards) {
    tags$div(style = "padding-right: 10px;", cards)
}

artist_cards <- function(data) {
    list_of_cards(lapply(seq_len(nrow(data)), function(i) {
        artist <- data[i, ]
        list_card(
            "artist-card", artist$rank,
            lines = list(
                card_title(artist$name),
                card_line(if (nchar(artist$genres) > 0) to_title_case(artist$genres) else "No genres listed")
            ),
            figures = list(
                if (!is.na(artist$popularity)) card_figure(paste0("Popularity: ", artist$popularity), accent = TRUE),
                if (!is.na(artist$followers)) card_figure(paste0(format(artist$followers, big.mark = ","), " followers"))
            ),
            url = artist$spotify_url
        )
    }))
}

track_cards <- function(data) {
    list_of_cards(lapply(seq_len(nrow(data)), function(i) {
        track <- data[i, ]
        list_card(
            "track-card", track$rank,
            lines = list(card_title(track$name), card_line(track$artist), card_detail(track$album)),
            figures = list(
                if (!is.na(track$popularity)) card_figure(paste0("Popularity: ", track$popularity), accent = TRUE),
                card_figure(format_duration(track$duration_ms))
            ),
            url = track$spotify_url
        )
    }))
}

# Recently played: numbered in the order they were played, no figures
recent_track_cards <- function(data) {
    list_of_cards(lapply(seq_len(nrow(data)), function(i) {
        track <- data[i, ]
        list_card(
            "track-card", i,
            lines = list(card_title(track$name), card_line(track$artist), card_detail(track$album)),
            url = track$spotify_url
        )
    }))
}
