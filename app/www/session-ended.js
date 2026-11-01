// What the user sees when the connection to the server ends. Shiny only puts an empty
// grey layer over the page then (the "Disconnected from the server" box belongs to Shiny
// Server and Posit Connect), so the page looked frozen with no explanation. The connection
// ends after an hour at the latest (Cloud Run's limit for one request), and when the device
// sleeps or loses the network. The login lives in the server's memory, so there is nothing to
// resume: say so, offer Reload, and if the tab was in the background when it happened,
// reload it when the user comes back. The reloaded page says "Session expired".
(function () {
    var KEY = "trackteller.session_ended";
    var disconnected = false;
    var wasHidden = false;
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
        disconnected = true;
        wasHidden = document.visibilityState === "hidden";
        try { window.sessionStorage.setItem(KEY, "1"); } catch (e) { /* storage blocked: no message afterwards */ }
        show();
    });

    // Back in a tab that lost its connection while it was in the background: start over
    document.addEventListener("visibilitychange", function () {
        if (disconnected && wasHidden && document.visibilityState === "visible") {
            window.location.reload();
        }
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
