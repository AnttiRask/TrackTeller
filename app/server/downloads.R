# The "Download stats card" buttons of Top Artists and Top Tracks

downloads_server <- function(input, output, session, auth, artists, tracks) {
    card_download <- function(type, prefix, data) {
        downloadHandler(
            filename = function() paste0(prefix, Sys.Date(), ".png"),
            content = function(file) {
                img <- stats_card_for(
                    type, isolate(data()), isolate(auth$user_display_name()), isolate(input$time_range)
                )
                image_write(img, path = file, format = "png")
            }
        )
    }

    output$download_artists_card <- card_download("artists", "top-artists-", artists$all)
    output$download_tracks_card  <- card_download("tracks", "top-tracks-", tracks$all)
}
