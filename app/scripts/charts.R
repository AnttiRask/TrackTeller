# The genre bar chart. Lives here (not in server.R) so that it can be rendered on its
# own, in tests and in a throwaway page.

# Pixels the chart needs for `n` bars: each bar and its label need room, or the
# labels overlap
genre_chart_height <- function(n) {
    max(320L, as.integer(32L * n + 130L))
}

# `data` is the top of summarise_genres(): one row per genre to draw
genre_chart <- function(data, height = genre_chart_height(nrow(data))) {
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
        theme_spotify() +
        ggplot2::theme(
            panel.grid.major.x = ggplot2::element_line(
                color = spotify_colors$white,
                linewidth = 0.4,
                linetype = 2
            ),
            panel.grid.major.y = ggplot2::element_blank()
        )

    plotly::ggplotly(plot, tooltip = "text", height = height) |>
        plotly::layout(hoverlabel = list(bgcolor = spotify_colors$black))
}
