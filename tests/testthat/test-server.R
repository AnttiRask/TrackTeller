# The server as a whole (app/server.R and the parts in app/server/), with Spotify mocked.
# Nothing here reaches the network: a request the test didn't list is recorded and fails it.

me <- function(name = "Pat") response_json(200L, body = list(id = "user1", display_name = name))

artists_answer <- function(n = 2) {
    response_json(200L, body = list(items = lapply(seq_len(n), \(i) artist(
        id = paste0("a", i), name = paste("Artist", i), popularity = 60 + i, followers = 1000 * i
    ))))
}

tracks_answer <- function(n = 2) {
    response_json(200L, body = list(items = lapply(seq_len(n), \(i) track(
        id = paste0("t", i), name = paste("Song", i), duration_ms = 187000
    ))))
}

# Logged in, with what the browser reports when the page connects
log_in <- function(session, auth, time_range = "short_term", shown_count = 20L) {
    session$setInputs(saved_prefs = list(), time_range = time_range, shown_count = shown_count,
                      main_navbar = "top_artists")
    auth$token_info(fresh_token())
    session$flushReact()
}

test_that("logged out, nothing is asked from Spotify and the page says so", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(saved_prefs = list(), time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        session$flushReact()
        expect_false(auth$is_authenticated())
        expect_error(output$top_artists_list)
    })
    expect_length(spotify$requests, 0)
})

test_that("logged in, the top artists are listed with a note and the account box shows the name", {
    spotify <- spotify_router("GET /me" = me("Pat"), "GET /me/top/artists" = artists_answer(2))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        html <- output$top_artists_list$html
        expect_match(html, "Artist 1")
        expect_match(html, "Popularity: 61")
        expect_match(html, "2,000 followers")
        expect_equal(lengths(regmatches(html, gregexpr("artist-card", html))), 2)
        expect_match(output$top_artists_note$html, "Showing all 2 artists")
        expect_match(output$account_ui$html, "Signed in as Pat")
    })
    expect_length(spotify$unexpected, 0)
})

test_that("the number to show limits the list and the note says how many there are", {
    spotify <- spotify_router("GET /me" = me(), "GET /me/top/tracks" = tracks_answer(12))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth, shown_count = 10L)
        html <- output$top_tracks_list$html
        expect_equal(lengths(regmatches(html, gregexpr("track-card", html))), 10)
        expect_match(output$top_tracks_note$html, "Showing 10 of 12 tracks")

        session$setInputs(shown_count = 15L)
        expect_equal(lengths(regmatches(output$top_tracks_list$html, gregexpr("track-card", output$top_tracks_list$html))), 12)
    })
})

test_that("the time range goes to Spotify, and the data waits for the remembered one", {
    spotify <- spotify_router("GET /me" = me(), "GET /me/top/artists" = artists_answer(1))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        auth$token_info(fresh_token())
        session$flushReact()
        # the browser hasn't reported yet: no list request has been made
        expect_false("GET /me/top/artists" %in% spotify$keys())

        session$setInputs(saved_prefs = list(time_range = "long_term"), time_range = "long_term")
        session$flushReact()
        # (the genre tab asks for the top artists too)
        asked <- Filter(\(r) r$key == "GET /me/top/artists", spotify$requests)
        expect_gt(length(asked), 0)
        expect_true(all(grepl("time_range=long_term", vapply(asked, \(r) r$req$url, character(1)))))
    })
})

test_that("a failing Spotify shows its plain message in place of the list", {
    spotify <- spotify_router("GET /me" = me(), "GET /me/top/artists" = response_json(500L, body = list()))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        expect_error(output$top_artists_list, "Couldn't get this from Spotify")
        # the note under the list doesn't repeat the message
        expect_null(output$top_artists_note$html)
    })
})

test_that("an empty list says what to do", {
    spotify <- spotify_router("GET /me" = me(), "GET /me/player/recently-played" = response_json(200L, body = list(items = list())))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        expect_error(output$recently_played_list, "Play some music on Spotify first")
    })
})

test_that("an expired token is renewed before the call, and the new one is used", {
    spotify <- spotify_router(
        "POST /api/token" = response_json(200L, body = list(
            access_token = "renewed", token_type = "Bearer", expires_in = 3600, scope = "x")),
        "GET /me" = me(),
        "GET /me/top/artists" = artists_answer(1)
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(saved_prefs = list(), time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        auth$token_info(fresh_token("old", expires_in = -10))
        session$flushReact()

        expect_equal(auth$token_info()$access_token, "renewed")
        expect_equal(auth$token_info()$refresh_token, "ref")      # kept: Spotify sent none
        used <- vapply(Filter(\(r) r$key == "GET /me", spotify$requests),
                       \(r) httr2::req_get_headers(r$req, redacted = "reveal")$Authorization, character(1))
        expect_equal(used, "Bearer renewed")
        expect_match(output$top_artists_list$html, "Artist 1")
    })
})

test_that("renewing the token doesn't make the lists fetch again", {
    spotify <- spotify_router(
        "POST /api/token" = response_json(200L, body = list(access_token = "renewed", token_type = "Bearer", expires_in = 3600)),
        "GET /me" = me(),
        "GET /me/top/artists" = artists_answer(1)
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(saved_prefs = list(), time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        auth$token_info(fresh_token("old", expires_in = -10))
        session$flushReact()
        expect_equal(auth$token_info()$access_token, "renewed")
        expect_equal(sum(spotify$keys() == "GET /me"), 1)
        # one for the artists tab, one for the genres tab
        expect_equal(sum(spotify$keys() == "GET /me/top/artists"), 2)
    })
})

test_that("a token Spotify rejects is renewed once and the call repeated", {
    spotify <- spotify_router(
        "POST /api/token" = response_json(200L, body = list(access_token = "renewed", token_type = "Bearer", expires_in = 3600)),
        "GET /me" = me(),
        # the old token is refused, the renewed one is accepted (the genre tab asks for these too)
        "GET /me/top/artists" = function(req) {
            token <- httr2::req_get_headers(req, redacted = "reveal")$Authorization
            if (token == "Bearer renewed") artists_answer(1) else response_json(401L, body = list())
        }
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        expect_true(auth$is_authenticated())
        expect_match(output$top_artists_list$html, "Artist 1")
    })
})

test_that("when the login can't be renewed the session ends with a message", {
    spotify <- spotify_router(
        "POST /api/token" = response_json(400L, body = list(error = "invalid_grant")),
        "GET /me" = response_json(401L, body = list()),
        "GET /me/top/artists" = response_json(401L, body = list())
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        expect_false(auth$is_authenticated())
        expect_match(output$auth_status$html, "Session expired")
    })
})

test_that("logging out forgets the login and the name", {
    spotify <- spotify_router("GET /me" = me("Pat"), "GET /me/top/artists" = artists_answer(1))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        expect_equal(auth$user_display_name(), "Pat")
        expect_equal(auth$user_id(), "user1")

        session$setInputs(confirm_logout = 1)
        expect_false(auth$is_authenticated())
        expect_equal(auth$user_display_name(), "")
        expect_null(auth$user_id())
        expect_match(output$auth_status$html, "You have been logged out")
    })
})

# ---- the login's way back from Spotify ----

# Only the login part, with an address of our own (the mock session has none)
callback_harness <- function(url) {
    function(input, output, session) {
        auth <- auth_server(input, output, session, url_search = url)
    }
}

test_that("a login that comes back with a state we didn't make is not used", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)
    url <- reactiveVal("?code=abc&state=forged")

    testServer(callback_harness(url), {
        session$setInputs(oauth_nonce = "")
        session$flushReact()
        expect_false(auth$is_authenticated())
        expect_match(output$auth_status$html, "Couldn't verify this login")
    })
    expect_length(spotify$requests, 0)       # the code never went to Spotify
})

test_that("a good state from another browser is not used either", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)
    login <- oauth_state_new(SPOTIFY_CLIENT_SECRET)
    url <- reactiveVal(paste0("?code=abc&state=", login$state))

    testServer(callback_harness(url), {
        session$setInputs(oauth_nonce = oauth_state_new(SPOTIFY_CLIENT_SECRET)$nonce)
        session$flushReact()
        expect_false(auth$is_authenticated())
        expect_match(output$auth_status$html, "Couldn't verify this login")
    })
    expect_length(spotify$requests, 0)
})

test_that("the login waits for the browser to report its nonce", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)
    login <- oauth_state_new(SPOTIFY_CLIENT_SECRET)
    url <- reactiveVal(paste0("?code=abc&state=", login$state))

    testServer(callback_harness(url), {
        session$flushReact()
        expect_false(auth$is_authenticated())
        expect_error(output$auth_status)          # nothing said yet
    })
    expect_length(spotify$requests, 0)
})

test_that("a good state from the same browser logs in, and the code is exchanged once", {
    spotify <- spotify_router(
        "POST /api/token" = response_json(200L, body = list(
            access_token = "first", token_type = "Bearer", expires_in = 3600, refresh_token = "r1")),
        "GET /me" = me()
    )
    local_mocked_responses(spotify$mock)
    login <- oauth_state_new(SPOTIFY_CLIENT_SECRET)
    url <- reactiveVal(paste0("?code=abc&state=", login$state))

    testServer(callback_harness(url), {
        session$setInputs(oauth_nonce = login$nonce)
        session$flushReact()
        expect_true(auth$is_authenticated())
        expect_equal(auth$token_info()$access_token, "first")
        expect_match(output$auth_status$html, "Successfully logged in")
    })
    expect_equal(sum(spotify$keys() == "POST /api/token"), 1)
})

test_that("a refused login shows our words, never the address's or Spotify's", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)
    url <- reactiveVal("?error=%3Cb%3Eyou%20won%20a%20prize%3C%2Fb%3E")

    testServer(callback_harness(url), {
        session$flushReact()
        expect_match(output$auth_status$html, "didn't give access")
        expect_no_match(output$auth_status$html, "prize")
    })
})

# ---- creating a playlist ----

test_that("a playlist made from the top tracks is public, named, dated and filled", {
    spotify <- spotify_router(
        "GET /me" = me(),
        "GET /me/top/tracks" = tracks_answer(3),
        "POST /users/user1/playlists" = response_json(201L, body = list(id = "newpl")),
        "POST /playlists/newpl/tracks" = response_json(201L, body = list(snapshot_id = "s"))
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_tracks = 1)
        session$setInputs(new_playlist_name = "  Summer  ", confirm_create_playlist = 1)
        session$flushReact()

        made <- Filter(\(r) r$key == "POST /users/user1/playlists", spotify$requests)[[1]]$req$body$data
        expect_equal(made$name, paste0("Summer (", Sys.Date(), ")"))
        expect_true(made$public)

        added <- Filter(\(r) r$key == "POST /playlists/newpl/tracks", spotify$requests)[[1]]$req$body$data
        expect_equal(unlist(added$uris), paste0("spotify:track:t", 1:3))
    })
    expect_length(spotify$unexpected, 0)
})

test_that("an empty name gets the default for where the tracks came from", {
    spotify <- spotify_router(
        "GET /me" = me(),
        "GET /me/top/tracks" = tracks_answer(1),
        "POST /users/user1/playlists" = response_json(201L, body = list(id = "newpl")),
        "POST /playlists/newpl/tracks" = response_json(201L, body = list())
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_tracks = 1)
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$flushReact()
        made <- Filter(\(r) r$key == "POST /users/user1/playlists", spotify$requests)[[1]]$req$body$data
        expect_equal(made$name, paste0("My Top Tracks (", Sys.Date(), ")"))
    })
})

test_that("a playlist from the artists takes each shown artist's top track, each once", {
    top_track <- function(id) response_json(200L, body = list(tracks = list(track(id = id))))
    spotify <- spotify_router(
        "GET /me" = me(),
        "GET /me/top/artists" = artists_answer(2),
        "GET /artists/a1/top-tracks" = top_track("same"),
        "GET /artists/a2/top-tracks" = top_track("same"),
        "POST /users/user1/playlists" = response_json(201L, body = list(id = "newpl")),
        "POST /playlists/newpl/tracks" = response_json(201L, body = list())
    )
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_artists = 1)
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$flushReact()
        added <- Filter(\(r) r$key == "POST /playlists/newpl/tracks", spotify$requests)[[1]]$req$body$data
        expect_equal(unlist(added$uris), "spotify:track:same")
    })
    expect_length(spotify$unexpected, 0)
})

test_that("with nothing to add, no playlist is made", {
    spotify <- spotify_router("GET /me" = me(), "GET /me/player/recently-played" = response_json(200L, body = list(items = list())))
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_recent = 1)
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$flushReact()
    })
    expect_false(any(grepl("^POST", spotify$keys())))
})

test_that("a playlist that was made but couldn't be filled is not reported as done", {
    spotify <- spotify_router(
        "GET /me" = me(),
        "GET /me/top/tracks" = tracks_answer(1),
        "POST /users/user1/playlists" = response_json(201L, body = list(id = "newpl")),
        "POST /playlists/newpl/tracks" = response_json(500L, body = list()),
        "POST /playlists/newpl/items" = response_json(500L, body = list())
    )
    local_mocked_responses(spotify$mock)
    notes <- character(0)
    local_mocked_bindings(showNotification = function(ui, ...) notes <<- c(notes, ui), .package = "shiny")

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_tracks = 1)
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$flushReact()
    })
    expect_true(any(grepl("failed to add tracks", notes)))
})

# ---- a page whose connection ended ----

test_that("the page after a lost connection says the session expired", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(saved_prefs = list(), time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        session$setInputs(session_ended = TRUE)
        session$flushReact()
        expect_false(auth$is_authenticated())
        expect_match(output$auth_status$html, "Session expired")
    })
})

test_that("a fresh page that wasn't preceded by a lost connection says nothing", {
    spotify <- spotify_router()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        session$setInputs(saved_prefs = list(), time_range = "short_term", shown_count = 20L, main_navbar = "top_artists")
        session$flushReact()
        expect_error(output$auth_status)
    })
})

test_that("someone who is logged in is not told their session expired", {
    spotify <- spotify_router("GET /me" = me())
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(session_ended = TRUE)
        session$flushReact()
        expect_true(auth$is_authenticated())
        expect_error(output$auth_status)
    })
})

# ---- one playlist per dialog ----

create_requests <- function(spotify) sum(spotify$keys() == "POST /users/user1/playlists")

playlist_routes <- function() spotify_router(
    "GET /me" = me(),
    "GET /me/top/tracks" = tracks_answer(2),
    "POST /users/user1/playlists" = response_json(201L, body = list(id = "newpl")),
    "POST /playlists/newpl/tracks" = response_json(201L, body = list(snapshot_id = "s"))
)

test_that("a second click on Create in the same dialog doesn't make a second playlist", {
    spotify <- playlist_routes()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_tracks = 1)
        # the first click is still being served when the impatient second one arrives
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$setInputs(confirm_create_playlist = 2)
        session$setInputs(confirm_create_playlist = 3)
        session$flushReact()
    })
    expect_equal(create_requests(spotify), 1)
    expect_equal(sum(spotify$keys() == "POST /playlists/newpl/tracks"), 1)
})

test_that("opening the dialog again allows the next playlist", {
    spotify <- playlist_routes()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        session$setInputs(create_playlist_tracks = 1)
        session$setInputs(new_playlist_name = "", confirm_create_playlist = 1)
        session$setInputs(confirm_create_playlist = 2)           # ignored: same dialog
        session$setInputs(create_playlist_tracks = 2)            # a new dialog
        session$setInputs(new_playlist_name = "Again", confirm_create_playlist = 3)
        session$flushReact()
    })
    expect_equal(create_requests(spotify), 2)
})

test_that("a click that finds the dialog already handled changes nothing else", {
    spotify <- playlist_routes()
    local_mocked_responses(spotify$mock)

    testServer(server, {
        log_in(session, auth)
        before <- length(spotify$requests)
        session$setInputs(confirm_create_playlist = 1)       # no dialog was ever opened
        session$flushReact()
        expect_equal(create_requests(spotify), 0)
    })
})
