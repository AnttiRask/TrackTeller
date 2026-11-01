test_that("parse_top_artists reads a normal response", {
    out <- parse_top_artists(list(items = list(artist(), artist("a2", "Two", genres = list()))))
    expect_equal(nrow(out), 2)
    expect_equal(out$rank, 1:2)
    expect_equal(out$genres, c("indie rock, folk", ""))
    expect_equal(out$popularity[1], 70L)
    expect_equal(out$followers[1], 12345)
    expect_equal(out$image_url[1], "https://i.scdn.co/image/a1")
})

test_that("parse_top_artists copes with popularity, followers and images being gone", {
    out <- parse_top_artists(list(items = list(artist(popularity = NULL, followers = NULL, images = list()))))
    expect_equal(nrow(out), 1)
    expect_true(is.na(out$popularity))
    expect_true(is.na(out$followers))
    expect_true(is.na(out$image_url))
})

test_that("parsers return NULL when there is nothing", {
    expect_null(parse_top_artists(list(items = list())))
    expect_null(parse_top_artists(NULL))
    expect_null(parse_top_tracks(list(items = list())))
    expect_null(parse_recent_tracks(list(items = list())))
    expect_null(parse_playlists_page(list()))
    expect_null(summarise_genres(list(items = list())))
    expect_null(parse_first_track(list(tracks = list())))
})

test_that("parse_top_tracks joins artists and tolerates a missing popularity", {
    out <- parse_top_tracks(list(items = list(
        track(artists = list(list(name = "A"), list(name = "B"))),
        track("t2", popularity = NULL)
    )))
    expect_equal(out$artist[1], "A, B")
    expect_equal(out$duration_ms[1], 187000)
    expect_true(is.na(out$popularity[2]))
    expect_equal(out$album_image_url[1], "https://i.scdn.co/image/al")
})

test_that("parse_recent_tracks keeps the first of each track and caps the count", {
    item <- function(...) list(track = track(...), played_at = "2026-01-01T00:00:00Z")
    data <- list(items = list(item("t1", "One"), item("t2", "Two"), item("t1", "One"), item("t3", "Three")))
    expect_equal(parse_recent_tracks(data, count = 20)$id, c("t1", "t2", "t3"))
    expect_equal(parse_recent_tracks(data, count = 2)$id, c("t1", "t2"))
})

test_that("parse_playlists_page reads either track count field", {
    pl <- function(...) modifyList(list(id = "p", name = "Mix", owner = list(display_name = "Pat"),
                                        public = TRUE, external_urls = list(spotify = "https://s/p")), list(...))
    out <- parse_playlists_page(list(
        pl(tracks = list(total = 7L)),
        pl(items = list(total = 9L), tracks = list(total = 7L)),
        pl(),
        pl(public = FALSE, name = NULL)
    ))
    expect_equal(out$track_count, c(7L, 9L, 0L, 0L))
    expect_equal(out$is_public, c(TRUE, TRUE, TRUE, FALSE))
    expect_equal(out$name[4], "(Untitled)")
    expect_true(is.na(out$image_url[1]))
})

test_that("summarise_genres counts, ranks and names artists", {
    data <- list(items = list(
        artist(name = "A", genres = list("rock", "indie rock")),
        artist(name = "B", genres = list("rock")),
        artist(name = "C", genres = list()),
        artist(name = "D", genres = list("jazz"))
    ))
    out <- summarise_genres(data)
    expect_equal(out$genre, c("rock", "indie rock", "jazz"))
    expect_equal(out$count, c(2L, 1L, 1L))
    expect_equal(out$percentage, c(50, 25, 25))
    expect_equal(out$genre_display, c("Rock", "Indie Rock", "Jazz"))
    expect_equal(out$artist_names[1], "A, B")
})

test_that("summarise_genres shortens long artist lists and handles no genres at all", {
    many <- lapply(LETTERS[1:7], function(n) artist(name = n, genres = list("pop")))
    expect_equal(summarise_genres(list(items = many))$artist_names, "A, B, C, D, E...")
    expect_null(summarise_genres(list(items = list(artist(genres = list())))))
})

test_that("parse_first_track picks the first track of a top-tracks answer", {
    out <- parse_first_track(list(tracks = list(track("t9", "Nine"), track("t8"))))
    expect_equal(out$id, "t9")
    expect_equal(out$name, "Nine")
})

test_that("format_duration gives M:SS", {
    expect_equal(format_duration(187000), "3:07")
    expect_equal(format_duration(60000), "1:00")
    expect_equal(format_duration(5000), "0:05")
    expect_equal(format_duration(NA), "")
    expect_equal(format_duration(NULL), "")
})

test_that("to_title_case capitalises each word", {
    expect_equal(to_title_case(c("indie rock", "hip hop", "jazz")), c("Indie Rock", "Hip Hop", "Jazz"))
})

# ---- addresses that come from Spotify ----

test_that("a link is only let through when it is https on open.spotify.com", {
    ok <- c("https://open.spotify.com/artist/a1", "https://OPEN.SPOTIFY.COM/track/t", "https://open.spotify.com:443/x", "https://open.spotify.com")
    expect_equal(spotify_link(ok), ok)

    bad <- c("http://open.spotify.com/artist/a1", "https://spotify.com/x", "https://open.spotify.com.evil.example/x",
             "https://evil.example/open.spotify.com", "https://open.spotify.com@evil.example/x", "javascript:alert(1)",
             "//open.spotify.com/x", "data:text/html,x", "https://", "", NA_character_)
    expect_true(all(is.na(spotify_link(bad))))
    expect_true(is.na(spotify_link(NULL)) || length(spotify_link(NULL)) == 0)
})

test_that("a picture is only let through when it is https on Spotify's image hosts", {
    ok <- c("https://i.scdn.co/image/ab67", "https://mosaic.scdn.co/640/a", "https://image-cdn-ak.spotifycdn.com/image/x")
    expect_equal(spotify_image(ok), ok)

    bad <- c("http://i.scdn.co/image/a", "https://scdn.co/a", "https://i.scdn.co.evil.example/a", "https://evil.example/i.scdn.co/a",
             "https://i.scdn.co@evil.example/a", "https://open.spotify.com/a.png", "javascript:alert(1)", "data:image/png;base64,AAAA", NA_character_)
    expect_true(all(is.na(spotify_image(bad))))
})

test_that("the parsers keep the addresses Spotify's hosts give and drop the others", {
    good <- artist(images = list(list(url = "https://i.scdn.co/image/a")), spotify = "https://open.spotify.com/artist/a1")
    bad <- artist("a2", "Two", images = list(list(url = "https://evil.example/a.png")), spotify = "javascript:alert(1)")
    out <- parse_top_artists(list(items = list(good, bad)))
    expect_equal(out$image_url, c("https://i.scdn.co/image/a", NA))
    expect_equal(out$spotify_url, c("https://open.spotify.com/artist/a1", NA))

    out <- parse_top_tracks(list(items = list(track())))
    expect_equal(out$spotify_url, "https://open.spotify.com/track/t1")
    expect_equal(out$album_image_url, "https://i.scdn.co/image/al")

    elsewhere <- track()
    elsewhere$album$images <- list(list(url = "https://evil.example/a.png"))
    expect_equal(parse_top_tracks(list(items = list(elsewhere)))$album_image_url, NA_character_)
})
