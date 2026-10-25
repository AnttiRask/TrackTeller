library(ggplot2)
source(file.path(app_dir, "scripts", "global.R"))
source(file.path(app_dir, "scripts", "charts.R"))

genre_rows <- function(n) {
    tibble(
        genre_display = paste("Genre", seq_len(n)),
        count = rev(seq_len(n)),
        percentage = round(rev(seq_len(n)) / sum(seq_len(n)) * 100, 1),
        artist_names = "A, B, C"
    )
}

test_that("the chart never gets less height than its bars need", {
    expect_equal(genre_chart_min_height(1), 300L)
    expect_equal(genre_chart_min_height(10), 300L)
    expect_equal(genre_chart_min_height(20), 450L)
    heights <- vapply(1:30, genre_chart_min_height, integer(1))
    expect_false(is.unsorted(heights))
})

test_that("the container height is the rest of the screen, or the minimum", {
    expect_equal(genre_chart_css_height(20), "calc(max(100vh - 235px, 450px))")
    expect_equal(genre_chart_css_height(5), "calc(max(100vh - 235px, 300px))")
    # what plotlyOutput() will accept
    expect_no_error(plotly::plotlyOutput("x", height = genre_chart_css_height(20)))
})

test_that("the genre chart is an interactive bar chart with one bar per genre", {
    w <- plotly::plotly_build(genre_chart(genre_rows(12)))
    expect_s3_class(w, "plotly")
    bars <- Filter(function(tr) identical(tr$type, "bar"), w$x$data)
    expect_length(bars, 1)
    expect_length(bars[[1]]$x, 12)
    expect_match(bars[[1]]$text[1], "Artists: ")
    # no height of its own: it takes the one of its container
    expect_null(w$x$layout$height)
    expect_match(w$x$layout$title$text, "Your Top 12 Genres", fixed = TRUE)
})

test_that("the panel stays dark (ggplot2 4 drew the border white in ggplotly)", {
    w <- plotly::plotly_build(genre_chart(genre_rows(5)))
    fills <- vapply(w$x$layout$shapes, function(s) s$fillcolor %||% "", character(1))
    expect_false(any(fills %in% c("rgba(255,255,255,1)", "white", "#FFFFFF", "#ffffff")))
    expect_equal(w$x$layout$plot_bgcolor, "rgba(25,20,20,1)")
})
