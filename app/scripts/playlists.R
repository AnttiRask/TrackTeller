# Pure helpers for the My Playlists tab: paging, letters, sorting, and the copy that is
# kept in the browser. No Shiny in here, so they can be tested on their own.

PLAYLIST_PAGE_SIZE <- 50L

# Letters a playlist can be filed under. Å, Ä and Ö come after Z, as in Finnish and Swedish;
# everything else (digits, symbols, other alphabets) is filed under "#".
PLAYLIST_LETTERS <- c(LETTERS, "Å", "Ä", "Ö")

playlist_first_letter <- function(names) {
    first <- toupper(stringr::str_sub(names, 1, 1))
    ifelse(first %in% PLAYLIST_LETTERS, first, "#")
}

# A-Z in Finnish order (ICU collation: case-insensitive, Å Ä Ö after Z)
playlist_sort <- function(data) {
    if (nrow(data) == 0) return(data)
    data[stringr::str_order(dplyr::coalesce(data$name, ""), locale = "fi"), ]
}

# Choices for the letter filter: "All playlists", then "#" and the letters that exist
playlist_letter_choices <- function(names) {
    present <- unique(playlist_first_letter(names))
    letters_in_order <- c(if ("#" %in% present) "#", intersect(PLAYLIST_LETTERS, present))
    c("All playlists" = "all", stats::setNames(letters_in_order, letters_in_order))
}

filter_playlists <- function(data, letter) {
    if (is.null(letter) || length(letter) != 1 || letter == "all") return(data)
    data[playlist_first_letter(data$name) == letter, ]
}

playlist_page_count <- function(n, page_size = PLAYLIST_PAGE_SIZE) {
    max(1L, as.integer(ceiling(n / page_size)))
}

# The rows of one page; a page outside the range is moved into it
playlist_page <- function(data, page, page_size = PLAYLIST_PAGE_SIZE) {
    n <- nrow(data)
    if (n == 0) return(data)
    page <- min(max(1L, as.integer(page)), playlist_page_count(n, page_size))
    data[seq.int((page - 1L) * page_size + 1L, min(page * page_size, n)), ]
}

# "Showing 51-100 of 4,213 playlists"
playlist_range_note <- function(page, page_size, n) {
    if (n == 0) return("No playlists")
    if (n == 1) return("Showing the only playlist")
    from <- (page - 1L) * page_size + 1L
    to <- min(page * page_size, n)
    if (from == 1L && to == n) return(paste0("Showing all ", format(n, big.mark = ","), " playlists"))
    paste0("Showing ", format(from, big.mark = ","), "–", format(to, big.mark = ","),
           " of ", format(n, big.mark = ","), " playlists")
}

# ---- the copy kept in the browser (see www/playlists-cache.js) ----

PLAYLIST_CACHE_PREFIX <- "trackteller.playlists."

PLAYLIST_CACHE_FIELDS <- c("id", "name", "owner", "track_count", "is_public", "image_url", "spotify_url")

# One list per playlist, without the fields that are missing, ready to be sent as JSON.
# Works on the columns, not row by row: subsetting a tibble 4,000 times takes seconds.
compact_playlists <- function(data) {
    columns <- stats::setNames(lapply(PLAYLIST_CACHE_FIELDS, function(f) data[[f]]), PLAYLIST_CACHE_FIELDS)
    lapply(seq_len(nrow(data)), function(i) {
        row <- lapply(columns, function(column) column[[i]])
        row[!vapply(row, function(x) length(x) != 1 || is.na(x), logical(1))]
    })
}

# The browser's JSON may arrive as a list of rows or as a data frame (an array of
# objects can be simplified into one): turn both into a list of rows
as_row_list <- function(items) {
    if (is.data.frame(items)) {
        return(lapply(seq_len(nrow(items)), function(i) lapply(items, function(column) column[[i]])))
    }
    items
}

# What comes back from the browser is untrusted (it may be old, damaged or edited by
# hand): keep only rows that are well-formed, and only https links. NULL if nothing is left.
# Built from columns, not one tibble() per row: with 4,000 rows that is the difference
# between milliseconds and 20 seconds of a blocked session.
sanitise_cached_playlists <- function(items, max_rows = 20000L) {
    items <- as_row_list(items)
    if (!is.list(items) || length(items) == 0) return(NULL)

    rows <- Filter(is.list, utils::head(items, max_rows))
    if (length(rows) == 0) return(NULL)

    text <- function(get, default = NA_character_) {
        vapply(rows, function(row) {
            x <- get(row)
            if (is.character(x) && length(x) == 1 && !is.na(x)) x else default
        }, character(1), USE.NAMES = FALSE)
    }

    id <- text(function(r) r$id)
    name <- text(function(r) r$name)
    count <- vapply(rows, function(r) {
        n <- suppressWarnings(as.integer(r$track_count))
        if (length(n) == 1 && !is.na(n)) n else 0L
    }, integer(1), USE.NAMES = FALSE)

    keep <- !is.na(id) & !is.na(name)
    if (!any(keep)) return(NULL)

    tibble::tibble(
        id          = id,
        name        = name,
        description = "",
        track_count = count,
        owner       = text(function(r) r$owner, "Unknown"),
        is_public   = vapply(rows, function(r) isTRUE(r$is_public), logical(1), USE.NAMES = FALSE),
        image_url   = spotify_image(text(function(r) r$image_url)),
        spotify_url = spotify_link(text(function(r) r$spotify_url))
    )[keep, ]
}
