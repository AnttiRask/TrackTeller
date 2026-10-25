# Choices shared by the whole app (the bar above the tabs) and the small pure
# helpers that go with them

TIME_RANGES <- c(
    "Last 4 weeks"  = "short_term",
    "Last 6 months" = "medium_term",
    "All time"      = "long_term"
)

COUNT_MIN     <- 10L
COUNT_MAX     <- 50L
COUNT_STEP    <- 5L
COUNT_DEFAULT <- 20L

# The genre chart is unreadable with more bars than this
GENRE_CHART_MAX <- 20L

# How many items a list shows: what was asked for, but never more than there are
# (nor more than `cap`, when the list has one)
displayed_count <- function(wanted, available, cap = NULL) {
    if (is.null(available) || is.na(available)) return(0L)
    as.integer(min(wanted, available, if (is.null(cap)) Inf else cap))
}

# The line under a list: "Showing all 32 artists", "Showing 20 of 50 artists", or,
# when a cap applies, "Showing 20 of 48 genres (the chart shows at most 20)".
# `one` and `many` are the singular and plural noun. NULL when there is nothing to show.
count_note <- function(wanted, available, one, many, cap = NULL) {
    if (is.null(available) || is.na(available) || available < 1) return(NULL)

    shown <- displayed_count(wanted, available, cap)

    if (shown >= available) {
        if (available == 1) return(paste0("Showing the only ", one))
        return(paste0("Showing all ", available, " ", many))
    }

    note <- paste0("Showing ", shown, " of ", available, " ", many)
    if (!is.null(cap) && wanted > cap) {
        note <- paste0(note, " (the chart shows at most ", cap, ")")
    }
    note
}

# What the browser sends back from localStorage -> only values that are valid
# choices; anything else (missing, edited by hand, from an older version) is dropped.
# Returns a list with time_range and/or shown_count.
sanitise_prefs <- function(prefs) {
    out <- list()
    if (!is.list(prefs)) return(out)

    tr <- prefs$time_range
    if (is.character(tr) && length(tr) == 1 && tr %in% TIME_RANGES) {
        out$time_range <- tr
    }

    n <- suppressWarnings(as.numeric(prefs$shown_count))
    if (length(n) == 1 && !is.na(n) && n == round(n) &&
        n >= COUNT_MIN && n <= COUNT_MAX && (n - COUNT_MIN) %% COUNT_STEP == 0) {
        out$shown_count <- as.integer(n)
    }

    out
}
