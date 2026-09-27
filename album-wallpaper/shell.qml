import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

/*
 * shell.qml — album-art wallpaper via caelestia's own CLI
 * ---------------------------------------------------------------
 * Runs as its OWN quickshell process — a separate module, not part
 * of caelestia-shell's QML tree. It only touches caelestia the same
 * way a shell script would: by calling the `caelestia wallpaper`
 * command. Nothing here imports or depends on caelestia's services.
 *
 * WHAT IT DOES
 *   - Watches MPRIS for a player that's actively playing.
 *   - On a new track's art, snapshots your current wallpaper (read
 *     from caelestia's own state file) once, then runs
 *       caelestia wallpaper -f <art>
 *     to set the real desktop background to the album cover.
 *   - When playback stops/pauses (after a short debounce so back-to-
 *     back tracks don't flicker), restores the wallpaper you had
 *     before, via the same command.
 *
 * PLAYER FILTERING
 *   MPRIS has no "this is music, not video" flag — a browser tab
 *   playing a YouTube video and a browser tab playing open.spotify.com
 *   both show up under the same player identity (e.g. "Firefox").
 *   There is no reliable way to distinguish them at the protocol
 *   level. So instead this only reacts to players whose MPRIS
 *   identity/desktopEntry matches the `allowedPlayers` whitelist
 *   below, which defaults to the native Spotify client only.
 *   Generic browsers are deliberately never matched, so YouTube (or
 *   any other video played in a browser) will never trigger a
 *   wallpaper change — even if you also listen to music in that same
 *   browser.
 *
 *   To also allow another *native* music app (not a browser), add
 *   its MPRIS identity or desktopEntry (lowercase, substring match)
 *   to allowedPlayers, e.g. ["spotify", "vlc"] if you use VLC only
 *   for audio. Do NOT add "firefox"/"chromium"/"chrome" etc. — that
 *   reopens the YouTube problem.
 *
 * REQUIRES
 *   - the `caelestia` CLI (ships with caelestia-shell)
 *   - `curl` on PATH, only for players whose MPRIS art url is remote
 *     (e.g. Spotify via spotifyd/mpris-proxy); local file:// art is
 *     used directly
 *
 * INSTALL
 *   ~/.config/quickshell/albumwallpaper/shell.qml   (this file)
 *
 * RUN
 *   quickshell -c albumwallpaper
 *   Add that as an exec-once in your Hyprland config, or wrap it in
 *   a systemd --user unit, to start it with your session.
 *
 * NOTE ON THEMING
 *   caelestia-shell regenerates its Material You colour scheme from
 *   whichever wallpaper is active. If your scheme mode is "dynamic",
 *   accent colours will shift with every track. Run
 *   `caelestia scheme set -n <name>` to pin a static scheme if you
 *   don't want that side effect.
 *
 * CONTROL
 *   qs ipc call albumwallpaper toggle
 *   qs ipc call albumwallpaper status
 */
ShellRoot {
    id: root

    // ---------------- config ----------------
    property bool enabled: true
    property int restoreDelayMs: 1200 // debounce before reverting between tracks
    property string cacheDir: (Quickshell.env("HOME") || "/tmp") + "/.cache/albumwallpaper"
    property string wallpaperStateFile: (Quickshell.env("HOME") || "/tmp") + "/.local/state/caelestia/wallpaper/path.txt"
    property int keepCachedFiles: 20 // how many past songs' art to keep on disk

    // Only players whose MPRIS identity or desktopEntry contains one of
    // these (case-insensitive, substring match) will ever trigger a
    // wallpaper change. Keep this to real music apps — never browsers —
    // since MPRIS can't tell a music tab from a video tab.
    property var allowedPlayers: ["spotify"]

    // ---------------- internal state — don't touch ----------------
    property string previousWallpaper: ""
    property bool wallpaperOverridden: false
    property string lastAppliedArt: ""
    property string pendingArtUrl: ""
    property string pendingFileName: ""

    // caelestia's own background renderer caches its Image by path, so
    // calling `caelestia wallpaper -f` twice with the SAME path won't
    // actually redraw — only a genuinely different path forces a reload.
    // Naming each cached file after the song guarantees a fresh path
    // every time AND makes the cache dir human-readable.
    function sanitize(s) {
        const cleaned = (s || "").toString().trim()
            .replace(/[^a-zA-Z0-9]+/g, "_")
            .replace(/^_+|_+$/g, "");
        return cleaned.length > 0 ? cleaned.slice(0, 60) : "unknown";
    }

    function fileNameFor(p) {
        const artist = sanitize(p.trackArtist);
        const title = sanitize(p.trackTitle);
        const id = (p.uniqueId !== undefined && p.uniqueId !== null) ? p.uniqueId : Date.now();
        return artist + "_-_" + title + "_" + id + ".jpg";
    }

    // Checks a player's MPRIS identity/desktopEntry against allowedPlayers.
    // Substring + lowercase match so "Spotify" identity or a
    // "spotify.desktop" desktopEntry both match an "spotify" entry.
    function isAllowedPlayer(p) {
        if (!p) return false;
        const identity = (p.identity || "").toString().toLowerCase();
        const desktopEntry = (p.desktopEntry || "").toString().toLowerCase();
        for (const needle of allowedPlayers) {
            const n = needle.toLowerCase();
            if (n.length > 0 && (identity.indexOf(n) !== -1 || desktopEntry.indexOf(n) !== -1))
                return true;
        }
        return false;
    }

    readonly property var activePlayer: {
        const list = Mpris.players ? Mpris.players.values : [];
        for (const p of list) {
            if (p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl && isAllowedPlayer(p))
                return p;
        }
        return null;
    }

    onActivePlayerChanged: evaluate()
    onEnabledChanged: evaluate()

    Connections {
        target: root.activePlayer
        function onTrackArtUrlChanged() { root.evaluate(); }
        function onPlaybackStateChanged() { root.evaluate(); }
    }

    Component.onCompleted: mkdirProc.running = true

    Process {
        id: mkdirProc
        command: ["mkdir", "-p", root.cacheDir]
    }

    // ---------------- core logic ----------------
    function evaluate() {
        if (!enabled) return;
        const p = activePlayer;
        if (p && p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl) {
            requestArt(p);
        } else {
            scheduleRestore();
        }
    }

    function requestArt(p) {
        const url = p.trackArtUrl;
        if (url === lastAppliedArt) return;
        pendingArtUrl = url;
        pendingFileName = fileNameFor(p);
        console.log("[albumwallpaper] new track:", p.trackArtist, "-", p.trackTitle, "| art:", url, "| file:", pendingFileName);

        if (wallpaperOverridden) {
            applyPendingArt();
        } else {
            // snapshot whatever wallpaper is active BEFORE we touch it
            captureProc.running = true;
        }
    }

    Process {
        id: captureProc
        command: ["cat", root.wallpaperStateFile]
        stdout: StdioCollector {
            onStreamFinished: {
                root.previousWallpaper = text.trim();
                root.wallpaperOverridden = true;
                root.applyPendingArt();
            }
        }
    }

    function applyPendingArt() {
        const url = pendingArtUrl;
        if (!url) return;
        lastAppliedArt = url;

        if (url.startsWith("file://")) {
            setWallpaper(decodeURIComponent(url.substring(7)));
        } else {
            downloadProc.artUrl = url;
            downloadProc.outFile = root.cacheDir + "/" + pendingFileName;
            downloadProc.running = true;
        }
    }

    Process {
        id: downloadProc
        property string artUrl: ""
        property string outFile: ""
        command: ["curl", "-sL", artUrl, "-o", outFile]
        onExited: (exitCode) => {
            console.log("[albumwallpaper] curl exit", exitCode, "->", outFile);
            if (exitCode === 0) {
                root.setWallpaper(outFile);
                root.pruneCache();
            }
        }
    }

    // Keep only the most recent `keepCachedFiles` art files so the cache
    // dir doesn't grow forever over a long listening session.
    function pruneCache() {
        pruneProc.running = true;
    }

    Process {
        id: pruneProc
        command: [
            "bash", "-c",
            "cd \"" + root.cacheDir + "\" && ls -1t | tail -n +" + (root.keepCachedFiles + 1) + " | xargs -r rm --"
        ]
    }

    function setWallpaper(path) {
        console.log("[albumwallpaper] setting wallpaper:", path);
        applyProc.path = path;
        applyProc.running = true;
    }

    Process {
        id: applyProc
        property string path: ""
        command: ["caelestia", "wallpaper", "-f", path]
        onExited: (exitCode) => console.log("[albumwallpaper] caelestia wallpaper exit", exitCode)
    }

    Timer {
        id: restoreTimer
        interval: root.restoreDelayMs
        onTriggered: root.performRestore()
    }

    function scheduleRestore() {
        if (!wallpaperOverridden) return;
        console.log("[albumwallpaper] playback stopped/paused, restoring in", root.restoreDelayMs, "ms");
        restoreTimer.restart();
    }

    function performRestore() {
        const p = activePlayer;
        if (p && p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl) {
            console.log("[albumwallpaper] restore cancelled — playback resumed");
            return; // something started again during the debounce
        }
        if (previousWallpaper.length > 0) {
            console.log("[albumwallpaper] restoring original wallpaper:", previousWallpaper);
            setWallpaper(previousWallpaper);
        } else {
            console.log("[albumwallpaper] restore skipped — no previous wallpaper was captured");
        }
        wallpaperOverridden = false;
        lastAppliedArt = "";
        pendingArtUrl = "";
        pendingFileName = "";
    }

    IpcHandler {
        target: "albumwallpaper"

        function toggle(): void { root.enabled = !root.enabled; }
        function status(): string { return root.enabled ? "enabled" : "disabled"; }
    }
}
