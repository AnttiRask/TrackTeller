# Fabricated responses shaped like Spotify's JSON (no real user data)
artist <- function(id = "a1", name = "Artist One", popularity = 70, followers = 12345,
                   genres = list("indie rock", "folk"), images = list(list(url = "https://img/a1.jpg")),
                   spotify = "https://open.spotify.com/artist/a1") {
    out <- list(id = id, name = name, genres = genres, images = images,
                external_urls = list(spotify = spotify))
    if (!is.null(popularity)) out$popularity <- popularity
    if (!is.null(followers)) out$followers <- list(total = followers)
    out
}

track <- function(id = "t1", name = "Song", artists = list(list(name = "Artist One")),
                  album = "Album", popularity = 50, duration_ms = 187000) {
    out <- list(id = id, name = name, artists = artists,
                album = list(name = album, images = list(list(url = "https://img/al.jpg"))),
                duration_ms = duration_ms, external_urls = list(spotify = "https://open.spotify.com/track/t1"))
    if (!is.null(popularity)) out$popularity <- popularity
    out
}
