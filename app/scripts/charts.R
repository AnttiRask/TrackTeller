# The genre bar chart. Lives here (not in server.R) so that it can be rendered on its
# own, in tests and in a throwaway page.

# The chart fills the height left on the screen, but never gets less than every bar
# and its label need (smaller than that and the labels overlap). The offset is the
# page above the chart: navbar, shared bar and the note line.
GENRE_CHART_ABOVE_PX  <- 235L
GENRE_CHART_BAR_PX    <- 18L
GENRE_CHART_MARGIN_PX <- 90L

# Least height, in pixels, that `n` bars can have
genre_chart_min_height <- function(n) {
    max(300L, as.integer(GENRE_CHART_BAR_PX * n + GENRE_CHART_MARGIN_PX))
}

# CSS height for the chart's container: the rest of the screen, or the minimum
genre_chart_css_height <- function(n) {
    sprintf("calc(max(100vh - %dpx, %dpx))", GENRE_CHART_ABOVE_PX, genre_chart_min_height(n))
}

# `data` is the top of summarise_genres(): one row per genre to draw. The plot has no
# height of its own: it takes that of its container (see genre_chart_css_height()).
genre_chart <- function(data, base_size = 13) {
    plot <- data |>
        dplyr::mutate(genre_display = factor(genre_display, levels = rev(genre_display))) |>
        ggplot2::ggplot(ggplot2::aes(
            x = genre_display, y = count,
            text = paste0(genre_display, "\n",
                          "Artists: ", count, "\n",
                          "Percentage: ", percentage, "%\n",
                          artist_names)
        )) +
        ggplot2::geom_col(fill = spotify_colors$dark_green, alpha = 0.8, width = 0.7) +
        ggplot2::coord_flip() +
        ggplot2::labs(
            title = paste("Your Top", nrow(data), "Genres"),
            x = NULL,
            y = "Number of Artists"
        ) +
        ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(0, 0.1))) +
        theme_spotify(base_size = base_size) +
        ggplot2::theme(
            panel.grid.major.x = ggplot2::element_line(
                color = spotify_colors$white,
                linewidth = 0.4,
                linetype = 2
            ),
            panel.grid.major.y = ggplot2::element_blank()
        )

    plotly::ggplotly(plot, tooltip = "text") |>
        plotly::layout(hoverlabel = list(bgcolor = spotify_colors$black))
}
