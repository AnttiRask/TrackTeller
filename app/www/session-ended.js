// What the user sees when the connection to the server ends. Shiny only puts an empty
// grey layer over the page then (the "Disconnected from the server" box belongs to Shiny
// Server and Posit Connect), so the page looked frozen with no explanation. The connection
// ends after an hour at the latest (Cloud Run's limit for one request), and when the device
// sleeps or loses the network. The login lives in the server's memory, so there is nothing to
// resume: say so and offer Reload. The page is never reloaded on its own: a first version did
// that when the user came back to a tab that had dropped in the background, and the dialog
// was on screen the whole time with a button that could no longer be pressed. The reloaded
// page says "Session expired".
(function () {
    var KEY = "trackteller.session_ended";
    var unloading = false;

    // Closing or reloading the page also closes the connection: that is not a lost session
    window.addEventListener("beforeunload", function () { unloading = true; });
    window.addEventListener("pagehide", function () { unloading = true; });
    window.addEventListener("pageshow", function () { unloading = false; });

    function show() {
        if (document.getElementById("session-ended")) return;

        var box = document.createElement("div");
        box.id = "session-ended";
        box.setAttribute("role", "alertdialog");
        box.setAttribute("aria-labelledby", "session-ended-title");

        var title = document.createElement("h2");
        title.id = "session-ended-title";
        title.textContent = "Your session has ended";

        var text = document.createElement("p");
        text.textContent = "The connection to the server was closed. That happens after about an hour, " +
            "or when the device goes to sleep or loses its network. Reload the page and log in again.";

        var button = document.createElement("button");
        button.type = "button";
        button.className = "btn btn-success";
        button.textContent = "Reload";
        button.addEventListener("click", function () { window.location.reload(); });

        box.appendChild(title);
        box.appendChild(text);
        box.appendChild(button);
        document.body.appendChild(box);
        button.focus();
    }

    $(document).on("shiny:disconnected", function () {
        if (unloading) return;
        try { window.sessionStorage.setItem(KEY, "1"); } catch (e) { /* storage blocked: no message afterwards */ }
        show();
    });

    // On the next page: tell the server that the last one ended, once
    $(document).on("shiny:connected", function () {
        var ended = false;
        try {
            ended = window.sessionStorage.getItem(KEY) === "1";
            window.sessionStorage.removeItem(KEY);
        } catch (e) { /* nothing kept */ }
        if (ended) Shiny.setInputValue("session_ended", true, { priority: "event" });
    });
})();
