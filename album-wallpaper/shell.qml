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
 * command.
 *
 * WHAT IT DOES
 *   - Watches MPRIS for an allowed player that's actively playing.
 *   - On a new track's art, snapshots your current wallpaper (read
 *     from caelestia's own state file) once, then runs
 *       caelestia wallpaper -f <art>
 *   - When playback stops/pauses (after a short debounce), restores
 *     the wallpaper you had before.
 *   - When you switch it OFF (or hide it) via IPC, it immediately
 *     restores the wallpaper you had before the song started and
 *     stops reacting to music until switched back ON (or shown).
 *
 * PLAYER FILTERING
 *   Only players whose MPRIS identity/desktopEntry matches
 *   `allowedPlayers` (default: spotify) are used. Never add browsers.
 *
 * REQUIRES
 *   - the `caelestia` CLI
 *   - `curl` on PATH for remote art urls
 *
 * INSTALL
 *   ~/.config/quickshell/albumwallpaper/shell.qml   (this file)
 *
 * RUN
 *   quickshell -c albumwallpaper
 *
 * CONTROL
 *   qs -c albumwallpaper ipc call albumwallpaper toggle
 *   qs -c albumwallpaper ipc call albumwallpaper on
 *   qs -c albumwallpaper ipc call albumwallpaper off
 *   qs -c albumwallpaper ipc call albumwallpaper show     (same as on)
 *   qs -c albumwallpaper ipc call albumwallpaper hide     (same as off)
 *   qs -c albumwallpaper ipc call albumwallpaper status
 *   (If it's your only quickshell instance, `qs ipc call ...` works too.)
 */
ShellRoot {
    id: root

    // ---------------- config ----------------
    property bool enabled: true
    property int restoreDelayMs: 1200 // debounce before reverting between tracks
    property string cacheDir: (Quickshell.env("HOME") || "/tmp") + "/.cache/albumwallpaper"
    property string wallpaperStateFile: (Quickshell.env("HOME") || "/tmp") + "/.local/state/caelestia/wallpaper/path.txt"
    property int keepCachedFiles: 20 // how many past songs' art to keep on disk

    property var allowedPlayers: ["spotify"]

    // ---------------- internal state — don't touch ----------------
    property string previousWallpaper: ""
    property bool wallpaperOverridden: false
    property string lastAppliedArt: ""
    property string pendingArtUrl: ""
    property string pendingFileName: ""

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

    onEnabledChanged: {
        if (!enabled) {
            // Switched off: cancel anything pending and put the old
            // wallpaper back right away, regardless of playback state.
            console.log("[albumwallpaper] disabled");
            restoreTimer.stop();
            performRestore(true);
        } else {
            console.log("[albumwallpaper] enabled");
            evaluate();
        }
    }

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
            restoreTimer.stop();
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
                // disabled while we were reading the state file -> do nothing
                if (!root.enabled) return;
                root.previousWallpaper = text.trim();
                root.wallpaperOverridden = true;
                root.applyPendingArt();
            }
        }
    }

    function applyPendingArt() {
        if (!enabled) return;
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
            // If we were switched off mid-download, don't clobber the restored wallpaper.
            if (exitCode === 0 && root.enabled) {
                root.setWallpaper(outFile);
                root.pruneCache();
            }
        }
    }

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
        onTriggered: root.performRestore(false)
    }

    function scheduleRestore() {
        if (!wallpaperOverridden) return;
        console.log("[albumwallpaper] playback stopped/paused, restoring in", root.restoreDelayMs, "ms");
        restoreTimer.restart();
    }

    // force = true skips the "did playback resume?" check (used when switching off)
    function performRestore(force) {
        if (!wallpaperOverridden) return;

        if (!force) {
            const p = activePlayer;
            if (p && p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl) {
                console.log("[albumwallpaper] restore cancelled — playback resumed");
                return;
            }
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
        function on(): void { root.enabled = true; }
        function off(): void { root.enabled = false; }
        function show(): void { root.enabled = true; }
        function hide(): void { root.enabled = false; }
        function status(): string { return root.enabled ? "enabled" : "disabled"; }
    }
}
