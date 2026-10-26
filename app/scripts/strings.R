# What the user reads, in one place (the texts of the pages themselves are in ui.R and
# in the modules; Spotify's error messages are in spotify_api.R, the login's in
# spotify_oauth.R)

TXT <- list(
    # Under the login button
    login_ok          = "Successfully logged in!",
    login_failed      = "Authentication failed:",
    login_unverified  = "Couldn't verify this login. Please try logging in again.",
    login_denied      = "Spotify didn't give access, so you are not logged in.",
    logged_out        = "You have been logged out.",
    session_expired   = "Session expired. Please log in again.",

    # Lists with nothing in them
    no_top_artists    = "No top artists found. Listen to more music on Spotify!",
    no_top_tracks     = "No top tracks found. Listen to more music on Spotify!",
    no_recent_tracks  = "No recently played tracks found. Play some music on Spotify first!",
    no_genres         = "No genre data available.",

    # Creating a playlist
    playlist_no_tracks    = "No tracks available to create a playlist.",
    playlist_failed       = "Failed to create playlist. Please try again.",
    playlist_add_failed   = "Playlist created but failed to add tracks.",
    playlist_description  = "Created with TrackTeller — trackteller.youcanbeapirate.com",
    playlist_default_name = c(
        top_tracks      = "My Top Tracks",
        artist_tracks   = "My Top Artists",
        recently_played = "My Recently Played"
    ),

    # The share cards
    card_no_data = "No data available"
)
