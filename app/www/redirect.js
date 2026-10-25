// Sends the browser to Spotify to log in. The nonce of the login is kept here while the
// browser is away and reported to the server when the page connects again, so the server
// can check that the login that returns is the one that left (see oauth_state_check()).
// If the browser blocks storage the nonce is never found and the login is refused.
(function () {
    var KEY = "trackteller.oauth_nonce";

    Shiny.addCustomMessageHandler("redirect", function (target) {
        try {
            window.sessionStorage.setItem(KEY, target.nonce);
        } catch (e) { /* blocked: the check will fail and say so */ }
        window.location.href = target.url;
    });

    $(document).on("shiny:connected", function () {
        var nonce = "";
        try {
            nonce = window.sessionStorage.getItem(KEY) || "";
            window.sessionStorage.removeItem(KEY);   // good for one return only
        } catch (e) { /* nothing kept */ }
        Shiny.setInputValue("oauth_nonce", nonce, { priority: "event" });
    });
})();
