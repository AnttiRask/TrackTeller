html_of <- function(x) as.character(x)
count <- function(pattern, x) lengths(regmatches(x, gregexpr(pattern, x)))

test_that("an artist card shows rank, name, genres in title case, figures and the link", {
    data <- parse_top_artists(list(items = list(artist(), artist("a2", "Two", genres = list(), popularity = NULL, followers = NULL))))
    html <- html_of(artist_cards(data))
    expect_equal(count('class="artist-card"', html), 2)
    expect_match(html, "#1")
    expect_match(html, "Indie Rock, Folk")
    expect_match(html, "Popularity: 70")
    expect_match(html, "12,345 followers")
    expect_match(html, "No genres listed")
    expect_match(html, 'href="https://open.spotify.com/artist/a1"')
    expect_match(html, 'target="_blank"')
})

test_that("an artist without popularity or followers shows no figures for them", {
    data <- parse_top_artists(list(items = list(artist(popularity = NULL, followers = NULL))))
    html <- html_of(artist_cards(data))
    expect_no_match(html, "Popularity")
    expect_no_match(html, "followers")
})

test_that("a track card shows artist, album and the length", {
    data <- parse_top_tracks(list(items = list(track(duration_ms = 187000))))
    html <- html_of(track_cards(data))
    expect_equal(count('class="track-card"', html), 1)
    expect_match(html, "Artist One")
    expect_match(html, "Album")
    expect_match(html, "3:07")
    expect_match(html, "Popularity: 50")
})

test_that("recently played is numbered in order and has no figures", {
    data <- parse_recent_tracks(list(items = list(
        list(track = track("t1", "First")), list(track = track("t2", "Second")))))
    html <- html_of(recent_track_cards(data))
    expect_match(html, "#1")
    expect_match(html, "#2")
    expect_no_match(html, "Popularity")
    expect_no_match(html, "text-align: right")
})

test_that("text from Spotify is escaped, not read as markup", {
    data <- parse_top_tracks(list(items = list(track(name = "<script>alert(1)</script>"))))
    html <- html_of(track_cards(data))
    expect_no_match(html, "<script>")
    expect_match(html, "&lt;script&gt;")
})

test_that("the default title of a playlist depends on where it came from", {
    day <- as.Date("2026-10-26")
    expect_equal(playlist_title("", "top_tracks", day), "My Top Tracks (2026-10-26)")
    expect_equal(playlist_title("  ", "artist_tracks", day), "My Top Artists (2026-10-26)")
    expect_equal(playlist_title(NULL, "recently_played", day), "My Recently Played (2026-10-26)")
    expect_equal(playlist_title(" Summer ", "top_tracks", day), "Summer (2026-10-26)")
})

test_that("quiet turns a failing value into NULL", {
    expect_null(quiet(stop("nope")))
    expect_equal(quiet(3), 3)
})
