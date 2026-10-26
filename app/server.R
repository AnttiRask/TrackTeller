# The server: one part for each piece of the app (app/server/), put together here.
# What a part needs from another comes in as an argument, and what others need from it
# goes out as its result.

server <- function(input, output, session) {
    auth   <- auth_server(input, output, session)
    shared <- shared_server(input, output, session)

    artists <- artists_server(input, output, session, auth, shared)
    tracks  <- tracks_server(input, output, session, auth, shared)
    recent  <- recent_server(input, output, session, auth, shared)
    genres  <- genres_server(input, output, session, auth, shared)

    # My Playlists is a module of its own (scripts/playlists_module.R)
    playlists_server(
        "playlists",
        api_get = auth$api_get_async,
        is_authenticated = auth$is_authenticated,
        tab_active = reactive(identical(input$main_navbar, "my_playlists")),
        user_id = auth$user_id
    )

    downloads_server(input, output, session, auth, artists, tracks)
    create_playlist_server(input, output, session, auth, artists, tracks, recent)
}
