# Login, logout, the token and every call to Spotify made on the user's behalf.
# Returns what the other parts need: who is logged in and how to ask Spotify.
# url_search is the address's query (what Spotify's redirect adds); the tests give their own.

auth_server <- function(input, output, session,
                        url_search = reactive(session$clientData$url_search)) {
    token_info <- reactiveVal(NULL)

    user_display_name <- reactiveVal("")
    user_id <- reactiveVal(NULL)

    # Whether somebody is logged in. It changes only at a login or a logout: renewing the
    # token replaces token_info() too, and everything that asks "logged in?" (all the lists)
    # must not fetch again for that.
    is_authenticated <- reactiveVal(FALSE)
    observe({
        now <- !is.null(token_info()) && !is.null(token_info()$access_token)
        if (!identical(isolate(is_authenticated()), now)) is_authenticated(now)
    })

    # The message under the login button (login failed, session expired, logged out).
    # Defined once; the observers only change the value. (An output defined inside an
    # observer is thrown away when that observer re-runs, which is what happens right
    # after the address is cleared.)
    auth_message <- reactiveVal(NULL)

    set_auth_message <- function(class, icon_name, text) {
        auth_message(list(class = class, icon = icon_name, text = text))
    }

    output$auth_status <- renderUI({
        msg <- auth_message()
        req(msg)
        div(class = msg$class, icon(msg$icon), paste0(" ", msg$text))
    })
    # These two sit in panels that start hidden (the login or the logged-in view), and
    # Shiny doesn't compute outputs it thinks are hidden: always compute them
    outputOptions(output, "auth_status", suspendWhenHidden = FALSE)

    # Output for conditional panel
    output$is_authenticated <- reactive({
        is_authenticated()
    })
    outputOptions(output, "is_authenticated", suspendWhenHidden = FALSE)

    # Handle OAuth callback on session start
    observe({
        # Get the OAuth code from the address (set by Spotify's redirect)
        query <- parseQueryString(url_search())

        if (!is.null(query$code) && is.null(isolate(token_info()))) {
            # The browser reports the nonce it kept from the login (www/redirect.js) once it
            # connects; until then there is nothing to check the state against
            if (is.null(input$oauth_nonce)) return()

            # A code that comes back with a state this app didn't issue (or for another
            # browser, or too late) is not used
            checked <- oauth_state_check(query$state, input$oauth_nonce, SPOTIFY_CLIENT_SECRET)
            if (!checked$ok) {
                message("[oauth] state check failed: ", checked$reason)
                updateQueryString("?", mode = "replace")
                set_auth_message("text-danger", "exclamation-triangle", TXT$login_unverified)
                return()
            }

            result <- spotify_exchange_code(
                code = query$code,
                client_id = SPOTIFY_CLIENT_ID,
                client_secret = SPOTIFY_CLIENT_SECRET,
                redirect_uri = REDIRECT_URI
            )

            # The code can only be used once: clear it from the address either way
            updateQueryString("?", mode = "replace")

            if (result$state == "ok") {
                token_info(result$token)

                set_auth_message("text-success", "check-circle", TXT$login_ok)
            } else {
                set_auth_message("text-danger", "exclamation-triangle",
                                 paste(TXT$login_failed, result$message))
            }
        }

        # Handle OAuth error
        if (!is.null(query$error)) {
            set_auth_message("text-danger", "exclamation-triangle", TXT$login_denied)
        }
    })

    # The last page lost its connection (www/session-ended.js): say why this one starts logged out
    observeEvent(input$session_ended, {
        if (!is_authenticated()) {
            set_auth_message("text-warning", "exclamation-triangle", TXT$session_expired)
        }
    }, once = TRUE)

    # Logged out in this session: Spotify would sign the same account straight back in
    after_logout <- reactiveVal(FALSE)

    # Handle login button click
    observeEvent(input$login_btn, {
        login <- oauth_state_new(SPOTIFY_CLIENT_SECRET)
        url <- spotify_authorize_url(
            client_id = SPOTIFY_CLIENT_ID,
            redirect_uri = REDIRECT_URI,
            scope = SPOTIFY_SCOPES,
            state = login$state,
            force_dialog = isolate(after_logout())
        )

        # The browser keeps the nonce while it is away at Spotify (www/redirect.js)
        session$sendCustomMessage("redirect", list(url = url, nonce = login$nonce))
    })

    # Forget the login and go back to the first tab, which is the one that works logged out
    forget_login <- function() {
        token_info(NULL)
        nav_select("main_navbar", "top_artists")
        user_display_name("")
        user_id(NULL)
    }

    # Handle logout button click
    # The button is in the navbar on every tab, so it is easy to hit by accident: ask first
    observeEvent(input$logout_btn, {
        showModal(logout_dialog())
    })

    observeEvent(input$confirm_logout, {
        removeModal()
        after_logout(TRUE)      # the next login asks which account again
        forget_login()
        set_auth_message("text-info", "info-circle", TXT$logged_out)
    })

    # The login ended (expired or revoked): forget the token, say so on the login view
    end_session <- function() {
        forget_login()
        set_auth_message("text-warning", "exclamation-triangle", TXT$session_expired)
    }

    # A valid access token for the current login, renewed when it is about to
    # expire. NULL when nobody is logged in, or when the login could not be renewed.
    # A plain function, not a reactive: reading the token must not make the data
    # reactives re-run every time it is renewed.
    current_token <- function(force_refresh = FALSE) {
        tok <- isolate(token_info())
        if (is.null(tok)) return(NULL)

        if (force_refresh || token_is_expired(tok)) {
            result <- spotify_refresh_token(
                refresh_token = tok$refresh_token,
                client_id = SPOTIFY_CLIENT_ID,
                client_secret = SPOTIFY_CLIENT_SECRET
            )
            if (result$state == "reauth") {
                end_session()
                return(NULL)
            }
            if (result$state != "ok") {
                showNotification(result$message, type = "error", duration = 10)
                return(NULL)
            }
            token_info(result$token)
            tok <- result$token
        }

        tok$access_token
    }

    # What a call answers when there is no token to make it with
    no_token_result <- function() {
        state <- if (is.null(isolate(token_info()))) "reauth" else "error"
        list(state = state, data = NULL, http_status = NA_integer_,
             message = spotify_messages[[state]])
    }

    # Run one Spotify call with the current token. `call` is function(token) that
    # returns a result from spotify_get() / spotify_post(). If Spotify says the
    # token is no longer valid, renew it once and try again.
    api_request <- function(call) {
        token <- current_token()
        if (is.null(token)) return(no_token_result())

        res <- call(token)

        if (res$state == "reauth") {
            token <- current_token(force_refresh = TRUE)
            if (!is.null(token)) res <- call(token)
            if (res$state == "reauth") end_session()
        }
        res
    }

    api_get <- function(path, query = list()) {
        api_request(function(token) spotify_get(path, token, query))
    }

    # The same, but a promise, and the R session isn't blocked while Spotify answers (for
    # jobs of many requests in a row: see playlists_module.R). If the token is rejected,
    # it is renewed once and the call repeated, as in api_request().
    api_get_async <- function(path, query = list()) {
        token <- current_token()
        if (is.null(token)) return(promises::promise_resolve(no_token_result()))

        promises::then(spotify_get_async(path, token, query), onFulfilled = function(res) {
            if (res$state != "reauth") return(res)

            token <- current_token(force_refresh = TRUE)
            if (is.null(token)) return(res)

            promises::then(spotify_get_async(path, token, query), onFulfilled = function(again) {
                if (again$state == "reauth") end_session()
                again
            })
        })
    }

    # Inside a reactive or output: stop with Spotify's message in place of the data
    # when the call failed (nothing is shown when the login ended; the page then
    # switches to the login view)
    stop_if_failed <- function(res) {
        if (res$state == "reauth") req(FALSE)
        validate(need(res$state == "ok", res$message))
    }

    # Top right of the navbar: who is signed in, and the Log out button
    output$account_ui <- renderUI({
        req(is_authenticated())
        name <- user_display_name()
        div(
            class = "account-box",
            span(class = "account-name",
                 icon("circle-user"),
                 if (nzchar(name)) paste("Signed in as", name) else "Signed in"),
            actionButton("logout_btn", "Log out", class = "btn-outline-secondary btn-sm")
        )
    })

    # Get user profile to display
    observe({
        req(is_authenticated())
        res <- api_get("/me")

        if (res$state == "ok") {
            user_display_name(res$data$display_name %||% "")
            user_id(res$data$id)
        }
    })

    list(
        token_info = token_info,
        is_authenticated = is_authenticated,
        user_display_name = user_display_name,
        user_id = user_id,
        api_get = api_get,
        api_get_async = api_get_async,
        api_request = api_request,
        stop_if_failed = stop_if_failed
    )
}
