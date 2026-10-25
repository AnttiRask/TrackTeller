# Dialogs that are the same wherever they are opened

# Asks before logging out: the button is in the navbar on every tab, so it is easy to
# hit by accident. Cancel is green (the safe choice stands out), Log out the brand red
# (the theme's secondary colour, as the navbar button's outline).
logout_dialog <- function() {
    modalDialog(
        title = "Log out?",
        p("You will need to log in with Spotify again to see your listening data."),
        footer = tagList(
            # Like Shiny's modalButton(), but with our own colour
            tags$button(type = "button", class = "btn btn-success", style = "color: #191414;",
                        `data-dismiss` = "modal", `data-bs-dismiss` = "modal", "Cancel"),
            actionButton("confirm_logout", "Log out", class = "btn-secondary")
        ),
        easyClose = TRUE
    )
}
