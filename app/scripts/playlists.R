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

PLAYLIST_CACHE_FIELDS <- c("id", "name", "owner", "track_count", "is_public", "image_url", "spotify_url")

# One list per playlist, without the fields that are missing, ready to be sent as JSON
compact_playlists <- function(data) {
    lapply(seq_len(nrow(data)), function(i) {
        row <- as.list(data[i, PLAYLIST_CACHE_FIELDS])
        row[!vapply(row, function(x) length(x) != 1 || is.na(x), logical(1))]
    })
}

# What comes back from the browser is untrusted (it may be old, damaged or edited by
# hand): keep only rows that are well-formed, and only https links. NULL if nothing is left.
sanitise_cached_playlists <- function(items, max_rows = 20000L) {
    if (!is.list(items) || length(items) == 0) return(NULL)

    one_string <- function(x, default = NA_character_) {
        if (is.character(x) && length(x) == 1 && !is.na(x)) x else default
    }
    https_or_na <- function(x) {
        x <- one_string(x)
        if (!is.na(x) && startsWith(x, "https://")) x else NA_character_
    }

    rows <- lapply(utils::head(items, max_rows), function(item) {
        if (!is.list(item)) return(NULL)
        id <- one_string(item$id)
        name <- one_string(item$name)
        if (is.na(id) || is.na(name)) return(NULL)

        count <- suppressWarnings(as.integer(item$track_count))
        tibble::tibble(
            id          = id,
            name        = name,
            description = "",
            track_count = if (length(count) == 1 && !is.na(count)) count else 0L,
            owner       = one_string(item$owner, "Unknown"),
            is_public   = isTRUE(item$is_public),
            image_url   = https_or_na(item$image_url),
            spotify_url = https_or_na(item$spotify_url)
        )
    })

    out <- dplyr::bind_rows(rows)
    if (nrow(out) == 0) NULL else out
}
