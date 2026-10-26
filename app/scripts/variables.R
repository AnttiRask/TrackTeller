# Numbers and colours that are not about Spotify's brand (those are in global.R) or the
# shared choices (display.R)

# The cards in the Top Artists, Top Tracks and Recently Played lists
LIST_CARD_STYLE <- paste0(
    "display: flex; align-items: center; padding: 12px; ",
    "margin-bottom: 8px; background: #282828; border-radius: 8px; ",
    "transition: background 0.2s; cursor: default;"
)

# The shareable stats card image
STATS_CARD <- list(
    width = 1200L, height = 630L,
    background = "#191414", placeholder = "#282828",
    font = "Liberation Sans",
    image_size = 70L, row_height = 90L, start_y = 108L,
    per_column = 5L,                     # 10 rows: five on the left, five on the right
    footer = "trackteller.youcanbeapirate.com"
)

# The time range as the card says it
CARD_TIME_LABELS <- c(
    short_term  = "Last 4 Weeks",
    medium_term = "Last 6 Months",
    long_term   = "All Time"
)

# Spotify's market for an artist's top tracks (the endpoint needs one)
TOP_TRACKS_MARKET <- "US"
