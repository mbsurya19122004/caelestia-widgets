// shell.qml — standalone Quickshell MPRIS now-playing card (minimalist)

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell.Services.Mpris

ShellRoot {
    PanelWindow {
        id: pin

        // ============================================================
        // OPTIONS
        // ============================================================

        // Card background opacity.
        //   0.0 = fully transparent (only the art, text and buttons show)
        //   1.0 = solid
        // Text, album art and buttons always stay fully opaque.
        property real cardOpacity: 0

        // Show the seek bar and timestamps. Set to false for an even
        // more minimal card.
        property bool showSeekBar: true

        // How far the card bulges out of the background.
        //   0.0 = flat (no shading), 1.0 = default, 2.0 = strong
        // It fades along with cardOpacity, so a fully transparent card
        // has no shadows either.
        property real bulge: 0.5

        // The card only shows while something is playing. When playback
        // stops, or is paused from somewhere else (media keys, the player
        // itself), it hides after this many milliseconds (the delay stops
        // it flickering away between tracks). Pausing with the card's own
        // play/pause button keeps it on screen so you can resume.
        property int hideDelay: 2500

        // Lock button visibility.
        //   false = the lock button only appears while the pointer is
        //           over it (plus `lockHoverPad` px of slack around it)
        //   true  = it appears whenever the pointer is anywhere over the
        //           card (and stays while you move onto it)
        property bool lockOnCardHover: false

        // Extra pixels around the 26px lock button that also count as
        // "over the button" (only used when lockOnCardHover is false).
        // Raise it if the button is fiddly to trigger.
        property int lockHoverPad: 8

        // Set to true to log pointer position / hover state to the
        // Quickshell log (helps if the button ever fails to show).
        property bool debugLock: false
 
        // Keep the card on screen even when nothing is playing, as long as
        // a media player exists (it then shows the last / paused track).
        property bool alwaysShow: false

        // Spin the CD (and counter-spin the dashed orbit) while playing.
        property bool spinCD: true

        // Mouse wheel over the card changes the player's volume by this
        // much per notch (0..1 scale). Wheel over the seek bar seeks by
        // `seekStep` seconds per notch instead.
        property real volumeStep: 0.05
        property int seekStep: 5

        // Shuffle / repeat buttons flanking prev / next (they dim if the
        // player doesn't support them).
        property bool showModeButtons: true

        // Dragging keeps the card inside the screen and snaps it to the
        // screen edges (`edgeGap` px in) when within `snapDistance` px.
        property bool clampToScreen: false
        property int snapDistance: 14
        property int edgeGap: 16

        // Snap to 9 points: 4 corners, 4 edge midpoints and the centre.
        // The card sticks when dragged within `pointSnapDistance` px of a
        // point, and pulls free again if you keep dragging past that.
        property bool snapToPoints: true
        property int pointSnapDistance: 28


        // ============================================================
        // WINDOW / POSITION
        // ============================================================

        anchors {
            top: true
            left: true
        }

        // The window is bigger than the card so the soft shadows have
        // room to spread. The card itself still sits at top 200 /
        // left 460: these margins are that position minus `pad`.
        readonly property int pad: 28

        margins {
            top: 172
            left: 432
        }

        readonly property int cardWidth: 500
        readonly property int cardHeight: showSeekBar ? 186 : 168

        implicitWidth: cardWidth + pad * 2
        implicitHeight: cardHeight + pad * 2

        // Only the card takes mouse input; the transparent shadow
        // margin lets clicks fall through to the desktop.
        //
        // This is a FIXED rectangle on purpose. `Region { item: card }`
        // maps the card through its parents' transforms, but Quickshell
        // only recomputes it when the card's own x/y/width/height change,
        // not when `stage` scales during the pop-in animation. The mask
        // therefore got stuck at the small size it had while the card was
        // still shrunk (scale 0.6), which left the card's edges and
        // corners (including the lock button) outside the input region:
        // the compositor never sent hover events there.
        mask: Region {
            x: pin.pad
            y: pin.pad
            width: pin.cardWidth
            height: pin.cardHeight
        }

        color: "transparent"

        exclusiveZone: -1
        focusable: false

        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "mpris-pin"


        // ============================================================
        // COLORS
        // ============================================================

        // Live caelestia theme.
        //
        // caelestia writes its active scheme to
        //   $XDG_STATE_HOME/caelestia/scheme.json
        // (default ~/.local/state/caelestia/scheme.json).
        // We watch that file and re-read it whenever it changes,
        // so every colour below updates automatically.

        readonly property string stateDir:
            Quickshell.env("XDG_STATE_HOME") ||
            (Quickshell.env("HOME") + "/.local/state")

        readonly property string schemePath:
            stateDir + "/caelestia/scheme.json"

        // "colours" object from scheme.json (hex strings, no '#').
        property var sch: ({})

        // Returns "#rrggbb" for a scheme colour, or the fallback
        // (your current scheme) until the file has been loaded.
        function schemeColour(name, fallback) {
            const v = sch[name]
            return v ? "#" + v : fallback
        }

        FileView {
            id: schemeFile

            path: pin.schemePath

            watchChanges: true

            onFileChanged: reload()

            onLoaded: {
                try {
                    const data = JSON.parse(text())

                    if (data && data.colours)
                        pin.sch = data.colours
                } catch (e) {
                    // Can happen if we read while caelestia is
                    // mid-write; keep the old colours, the next
                    // change event will fix it.
                    console.warn(
                        "[mprispin] could not parse scheme.json:",
                        e
                    )
                }
            }

            onLoadFailed: (error) => {
                console.warn(
                    "[mprispin] could not read",
                    pin.schemePath
                )
            }
        }

        // Accent / text colours
        readonly property color colGold:
            schemeColour("primary", "#d7c688")

        readonly property color colOnGold:
            schemeColour("onPrimary", "#4b400f")

        readonly property color colCream:
            schemeColour("onSurface", "#ede5d1")

        readonly property color colDim:
            schemeColour("onSurfaceVariant", "#b2ab99")

        readonly property color colTrack:
            schemeColour("outlineVariant", "#4c4839")

        // Card background: the scheme's dark surfaces with a
        // subtle wash of the primary colour so it isn't flat black.
        readonly property color colSurfaceHigh:
            schemeColour("surfaceContainerHigh", "#0b0904")

        readonly property color colSurfaceHighest:
            schemeColour("surfaceContainerHighest", "#0d0b05")

        readonly property color colBgTop:
            Qt.tint(colSurfaceHighest, Qt.alpha(colGold, 0.14))

        readonly property color colBgBottom:
            Qt.tint(colSurfaceHigh, Qt.alpha(colGold, 0.07))

        readonly property color colButtonBg: "#00000055"

        // cardOpacity clamped to 0..1.
        readonly property real bgAlpha:
            Math.max(0, Math.min(1, cardOpacity))


        // ============================================================
        // MPRIS
        // ============================================================

        readonly property var players: Mpris.players.values

        property int manualPlayerIndex: -1

        readonly property MprisPlayer player: bestPlayer()

        readonly property bool hasPlayer:
            player !== null

        readonly property bool isPlaying:
            hasPlayer &&
            player.playbackState === MprisPlaybackState.Playing


        function bestPlayer() {
            if (players.length === 0)
                return null

            // Manually selected player.
            if (manualPlayerIndex >= 0 &&
                manualPlayerIndex < players.length) {
                return players[manualPlayerIndex]
            }

            // Prefer a local player that is playing.
            for (const p of players) {
                if (p.playbackState === MprisPlaybackState.Playing &&
                    p.desktopEntry !== "") {
                    return p
                }
            }

            // Otherwise any playing player.
            for (const p of players) {
                if (p.playbackState === MprisPlaybackState.Playing)
                    return p
            }

            // Otherwise prefer a local player.
            for (const p of players) {
                if (p.desktopEntry !== "")
                    return p
            }

            return players[0]
        }


        // ============================================================
        // HELPERS
        // ============================================================

        function formatTime(seconds) {
            if (seconds === undefined ||
                seconds === null ||
                isNaN(seconds) ||
                seconds < 0) {
                return "0:00"
            }

            const total = Math.floor(seconds)
            const minutes = Math.floor(total / 60)
            const secs = total % 60

            return minutes + ":" +
                   (secs < 10 ? "0" : "") +
                   secs
        }


        function seekTo(mouseX, width) {
            if (!hasPlayer ||
                player.length <= 0 ||
                width <= 0) {
                return
            }

            const ratio = Math.max(
                0,
                Math.min(1, mouseX / width)
            )

            player.position = ratio * player.length
        }


        function togglePlayback() {
            if (!hasPlayer)
                return

            const p = player

            if (p.playbackState === MprisPlaybackState.Playing) {
                // Remember that this pause came from the card, so it
                // stays visible instead of hiding (see SHOW / HIDE).
                if (p.canPause || p.canTogglePlaying) {
                    pausedByWidget = true
                    pauseIntentTimer.restart()
                }

                if (p.canPause)
                    p.pause()
                else if (p.canTogglePlaying)
                    p.togglePlaying()
            } else {
                if (p.canPlay)
                    p.play()
                else if (p.canTogglePlaying)
                    p.togglePlaying()
            }
        }


        // Returns the nearest of the 9 snap points if (l, t) is within
        // pointSnapDistance of one, otherwise the position unchanged.
        // l / t are window margins; the card sits `pad` px inside them.
        function snapPoint(l, t) {
            if (!snapToPoints || !screen || screen.width <= 0)
                return { l: l, t: t }

            const xs = [
                edgeGap,
                Math.round((screen.width - cardWidth) / 2),
                screen.width - cardWidth - edgeGap
            ]
            const ys = [
                edgeGap,
                Math.round((screen.height - cardHeight) / 2),
                screen.height - cardHeight - edgeGap
            ]

            let best = null
            let bestDist = pointSnapDistance

            for (const x of xs) {
                for (const y of ys) {
                    const dx = (l + pad) - x
                    const dy = (t + pad) - y
                    const d = Math.sqrt(dx * dx + dy * dy)

                    if (d <= bestDist) {
                        bestDist = d
                        best = { l: x - pad, t: y - pad }
                    }
                }
            }

            return best ? best : { l: l, t: t }
        }


        // Relative move used by dragging: snaps to the 9 points, and
        // optionally clamps to the screen / snaps to its edges.
        function moveBy(dx, dy) {
            let l = margins.left + dx
            let t = margins.top + dy

            const s = snapPoint(l, t)
            l = s.l
            t = s.t

            if (clampToScreen && screen && screen.width > 0) {
                // The card sits `pad` px inside the window.
                const minL = edgeGap - pad
                const maxL = screen.width - cardWidth - edgeGap - pad
                const minT = edgeGap - pad
                const maxT = screen.height - cardHeight - edgeGap - pad

                if (Math.abs(l - minL) < snapDistance) l = minL
                if (Math.abs(l - maxL) < snapDistance) l = maxL
                if (Math.abs(t - minT) < snapDistance) t = minT
                if (Math.abs(t - maxT) < snapDistance) t = maxT

                l = Math.max(minL, Math.min(maxL, l))
                t = Math.max(minT, Math.min(maxT, t))
            }

            margins.left = l
            margins.top = t
        }


        function seekBy(seconds) {
            if (!hasPlayer || !player.canSeek || player.length <= 0)
                return

            player.position = Math.max(
                0,
                Math.min(player.length, player.position + seconds)
            )
        }


        // Small "Volume 55%" pill at the top of the card (see `toast`).
        property string toastLabel: ""
        property real toastValue: 0

        Timer {
            id: toastTimer

            interval: 1200
        }

        function changeVolume(angleDelta) {
            if (!hasPlayer || !player.volumeSupported)
                return

            const v = Math.max(
                0,
                Math.min(1, player.volume + angleDelta / 120 * volumeStep)
            )

            player.volume = v

            toastValue = v
            toastLabel = "Volume  " + Math.round(v * 100) + "%"
            toastTimer.restart()
        }


        function toggleShuffle() {
            if (hasPlayer && player.shuffleSupported)
                player.shuffle = !player.shuffle
        }


        // Off -> repeat playlist -> repeat track -> off.
        function cycleLoop() {
            if (!hasPlayer || !player.loopSupported)
                return

            if (player.loopState === MprisLoopState.None)
                player.loopState = MprisLoopState.Playlist
            else if (player.loopState === MprisLoopState.Playlist)
                player.loopState = MprisLoopState.Track
            else
                player.loopState = MprisLoopState.None
        }


        // Changes whenever the track does; restarts the info animation.
        readonly property string trackKey:
            hasPlayer
            ? (player.trackTitle + "|" + player.trackArtist + "|" +
               player.trackAlbum)
            : ""

        // Right-hand time label: total length, or time remaining.
        property bool showRemaining: false


        // ============================================================
        // DEBUG
        // ============================================================

        onPlayersChanged: {
            console.log(
                "[mprispin] players detected:",
                players.length
            )

            for (const p of players) {
                console.log(
                    "[mprispin] -",
                    p.identity,
                    "canControl:", p.canControl,
                    "canPlay:", p.canPlay,
                    "canPause:", p.canPause,
                    "canTogglePlaying:", p.canTogglePlaying,
                    "canGoNext:", p.canGoNext,
                    "canGoPrevious:", p.canGoPrevious
                )
            }
        }


        // ============================================================
        // STATE
        // ============================================================

        property bool locked: false

        // Position persistence.
        //
        // Whenever you lock the card, its position is saved to
        //   $XDG_STATE_HOME/mprispin/position.json
        // (default ~/.local/state/mprispin/position.json)
        // and restored, locked, on the next start. Delete that file to
        // reset to the default position.

        readonly property string positionPath:
            stateDir + "/mprispin/position.json"

        // The window stays hidden until the saved position has been
        // read, so it doesn't flash at the default spot first.
        property bool stateReady: false

        // Mapped only while the position has been read AND the card is
        // wanted (or still animating out).
        visible: stateReady && (active || reveal > 0)


        function toggleLock() {
            locked = !locked

            if (locked)
                savePosition()
        }


        function savePosition() {
            const data = JSON.stringify({
                left: margins.left,
                top: margins.top,
                locked: true
            })

            // $1 = file, $2 = json. Written to a temp file and then
            // moved into place, so a crash can't leave a half-written
            // file behind.
            Quickshell.execDetached([
                "sh",
                "-c",

                "mkdir -p \"$(dirname \"$1\")\" && " +
                "printf '%s' \"$2\" > \"$1.tmp\" && " +
                "mv \"$1.tmp\" \"$1\"",

                "sh",
                positionPath,
                data
            ])
        }


        FileView {
            id: positionFile

            path: pin.positionPath

            onLoaded: {
                try {
                    const d = JSON.parse(text())

                    if (typeof d.left === "number" &&
                        typeof d.top === "number") {
                        pin.margins.left = d.left
                        pin.margins.top = d.top

                        if (d.locked === true)
                            pin.locked = true
                    }
                } catch (e) {
                    console.warn(
                        "[mprispin] could not parse",
                        pin.positionPath,
                        e
                    )
                }

                pin.stateReady = true
            }

            // No saved position yet (first run): just show the widget
            // at the default spot.
            onLoadFailed: (error) => {
                pin.stateReady = true
            }
        }


        // Safety net: never leave the widget hidden if the file read
        // somehow never reports back.
        Timer {
            interval: 500
            running: true

            onTriggered: pin.stateReady = true
        }


        // ============================================================
        // SHOW / HIDE
        //
        // `active` follows "something is playing" (hiding is delayed by
        // hideDelay), or "paused with the card's own button".
        // `reveal` drives the pop-in / pop-out animation:
        // 0 = hidden, 1 = fully out, with a brief overshoot on the way
        // in so the card swells out of the screen and settles.
        // ============================================================

        property bool active: false

        property real reveal: 0

        // Clamped copy used for shadow / bulge strength.
        readonly property real lift:
            Math.max(0, Math.min(1.3, reveal))


        // True after the card's own button paused playback. While set,
        // the card stays on screen even though nothing is playing.
        // Cleared when playback resumes (from anywhere) or the player
        // goes away.
        property bool pausedByWidget: false

        function updateActive() {
            if (!hasPlayer)
                pausedByWidget = false

            if (isPlaying) {
                pausedByWidget = false
                hideTimer.stop()
                active = true
            } else if (pausedByWidget || (alwaysShow && hasPlayer)) {
                hideTimer.stop()
                active = true
            } else {
                hideTimer.restart()
            }
        }

        onIsPlayingChanged: updateActive()

        onHasPlayerChanged: updateActive()

        onAlwaysShowChanged: updateActive()


        // If we asked the player to pause but it's still playing shortly
        // after (the request was ignored), drop the flag so a later
        // pause from elsewhere hides the card as usual.
        Timer {
            id: pauseIntentTimer

            interval: 2000

            onTriggered: {
                if (pin.isPlaying)
                    pin.pausedByWidget = false
            }
        }

        // Already playing when the shell starts.
        Component.onCompleted: {
            if (isPlaying || (alwaysShow && hasPlayer))
                active = true
        }

        onActiveChanged: {
            if (active) {
                hideAnim.stop()
                showAnim.restart()
            } else {
                showAnim.stop()
                hideAnim.restart()
            }
        }


        Timer {
            id: hideTimer

            interval: pin.hideDelay

            onTriggered:
                pin.active = false
        }


        // Pop out: fast rise, overshoots, settles.
        NumberAnimation {
            id: showAnim

            target: pin
            property: "reveal"

            to: 1

            duration: 650

            easing.type:
                Easing.OutBack

            easing.overshoot: 2.2
        }


        // Pop back in: a small swell, then shrinks away.
        NumberAnimation {
            id: hideAnim

            target: pin
            property: "reveal"

            to: 0

            duration: 330

            easing.type:
                Easing.InBack
        }


        // ============================================================
        // ALBUM ART
        // ============================================================

        readonly property string artSource: {
            if (!hasPlayer || !player.trackArtUrl)
                return ""

            const url = String(player.trackArtUrl)

            if (url.startsWith("http://") ||
                url.startsWith("https://") ||
                url.startsWith("file://") ||
                url.startsWith("qrc:")) {
                return url
            }

            return "file://" + url
        }


        // ============================================================
        // POSITION UPDATE
        // ============================================================

        Timer {
            interval: 500
            repeat: true
            running: pin.isPlaying

            onTriggered: {
                if (pin.hasPlayer)
                    pin.player.positionChanged()
            }
        }


        // ============================================================
        // BULGE SHADOWS
        //
        // Soft shadows around the card, built from a stack of slightly
        // different sized, faintly translucent rounded rectangles that
        // add up to a blur. A dark one is offset down-right and a light
        // one up-left, so the card looks like it is pushing out of the
        // background. Rendered once into a texture (layer.enabled), so
        // the CD animation doesn't re-draw them every frame.
        // ============================================================

        readonly property int shadowSteps: 28
        // Grows as the card lifts out of the background.
        readonly property real shadowOffset: 8 * lift

        // Overall bulge strength (0 when flat or fully transparent).
        readonly property real k:
            Math.max(0, bulge) * bgAlpha * lift

        // Alpha for each layer so that `steps` stacked layers add up to
        // roughly `maxAlpha` at the densest point.
        function layerAlpha(maxAlpha) {
            const m = Math.max(0, Math.min(0.95, maxAlpha))

            return 1 - Math.pow(1 - m, 1 / shadowSteps)
        }


        // Everything visible lives in `stage`, so the pop-in / pop-out
        // animation scales and fades the card and its shadows together.
        Item {
            id: stage

            anchors.fill: parent

            transformOrigin:
                Item.Center

            scale:
                0.6 + 0.4 * pin.reveal

            opacity:
                Math.max(0, Math.min(1, pin.reveal * 2))

            // Flatten into one texture only while animating, so the
            // fade doesn't show shadows through the card.
            layer.enabled:
                showAnim.running || hideAnim.running

            layer.smooth: true


            Item {
                id: shadowLayers

                anchors.fill: parent

                visible: pin.k > 0

                layer.enabled: true


                // Dark shadow, down-right
                Item {
                    x: pin.pad + pin.shadowOffset
                    y: pin.pad + pin.shadowOffset

                    width: pin.cardWidth
                    height: pin.cardHeight

                    Repeater {
                        model:
                            pin.shadowSteps

                        delegate: Rectangle {
                            required property int index

                            readonly property int grow:
                                index - pin.shadowSteps / 2

                            x: -grow
                            y: -grow

                            width: parent.width + grow * 2
                            height: parent.height + grow * 2

                            radius:
                                Math.max(0, card.radius + grow)

                            color:
                                Qt.rgba(
                                    0, 0, 0,
                                    pin.layerAlpha(0.55 * pin.k)
                                )
                        }
                    }
                }


                // Light glow, up-left
                Item {
                    x: pin.pad - pin.shadowOffset
                    y: pin.pad - pin.shadowOffset

                    width: pin.cardWidth
                    height: pin.cardHeight

                    Repeater {
                        model:
                            pin.shadowSteps

                        delegate: Rectangle {
                            required property int index

                            readonly property int grow:
                                index - pin.shadowSteps / 2

                            x: -grow
                            y: -grow

                            width: parent.width + grow * 2
                            height: parent.height + grow * 2

                            radius:
                                Math.max(0, card.radius + grow)

                            color:
                                Qt.alpha(
                                    pin.colCream,
                                    pin.layerAlpha(0.14 * pin.k)
                                )
                        }
                    }
                }
            }


            // ============================================================
            // CARD
            // ============================================================

            Rectangle {
                id: card

                anchors.fill: parent

                // Leave room around the card for the shadows.
                anchors.margins: pin.pad

                radius: 26
                clip: true

                // Flat mode (bulge = 0) keeps the accent outline; when
                // bulging, the lit / shaded edges replace it.
                border.width: pin.bulge > 0 ? 0 : 1
                border.color: Qt.alpha(pin.colGold, 0.2 * pin.bgAlpha)

                gradient: Gradient {
                    orientation: Gradient.Vertical

                    GradientStop {
                        position: 0
                        color: Qt.alpha(pin.colBgTop, pin.bgAlpha)
                    }

                    GradientStop {
                        position: 1
                        color: Qt.alpha(pin.colBgBottom, pin.bgAlpha)
                    }
                }


                // ========================================================
                // DRAG
                // ========================================================

                MouseArea {
                    id: dragArea

                    anchors.fill: parent

                    // Always enabled: while locked it stops moving the
                    // card but still handles the click-the-CD shortcut.

                    property real pressX: 0
                    property real pressY: 0

                    // Total pointer travel since the press, to tell a click
                    // from a drag.
                    property real travel: 0

                    cursorShape:
                        pin.locked
                        ? Qt.ArrowCursor
                        : Qt.SizeAllCursor

                    onPressed: (mouse) => {
                        pressX = mouse.x
                        pressY = mouse.y
                        travel = 0
                    }

                    onPositionChanged: (mouse) => {
                        if (!pressed)
                            return

                        const dx = mouse.x - pressX
                        const dy = mouse.y - pressY

                        travel += Math.abs(dx) + Math.abs(dy)

                        if (!pin.locked)
                            pin.moveBy(dx, dy)
                    }

                    // Clicking (not dragging) the CD toggles play / pause.
                    onReleased: (mouse) => {
                        if (travel > 4 || !pin.hasPlayer)
                            return

                        const c = artWrap.mapToItem(
                            dragArea,
                            artWrap.width / 2,
                            artWrap.height / 2
                        )

                        const dx = mouse.x - c.x
                        const dy = mouse.y - c.y

                        if (Math.sqrt(dx * dx + dy * dy) <= 62)
                            pin.togglePlayback()
                    }
                }


                // ========================================================
                // INNER BORDER (flat mode only)
                // ========================================================

                Rectangle {
                    anchors.fill: parent

                    anchors.margins: 1

                    radius: parent.radius - 1

                    visible: pin.bulge <= 0

                    color: "transparent"

                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.08 * pin.bgAlpha)
                }


                // ========================================================
                // BULGE SHADING
                //
                // Makes the face look convex, lit from the top-left: a
                // diagonal light -> shade sweep, a thin lit bevel along the
                // top/left edges and a shaded bevel along the bottom/right
                // edges. ClippingRectangle keeps it inside the rounded
                // corners.
                // ========================================================

                ClippingRectangle {
                    id: bulgeShading

                    anchors.fill: parent

                    radius: card.radius

                    color: "transparent"

                    visible: pin.k > 0


                    // Diagonal light -> shade sweep (lit corner: top-left)
                    Rectangle {
                        anchors.centerIn: parent

                        width:
                            Math.sqrt(
                                parent.width * parent.width +
                                parent.height * parent.height
                            ) + 8

                        height: width

                        rotation: -45

                        gradient: Gradient {
                            orientation: Gradient.Vertical

                            GradientStop {
                                position: 0.0
                                color: Qt.alpha(pin.colCream, 0.12 * pin.k)
                            }

                            GradientStop {
                                position: 0.5
                                color: "transparent"
                            }

                            GradientStop {
                                position: 1.0
                                color: Qt.rgba(0, 0, 0, 0.30 * pin.k)
                            }
                        }
                    }


                    // Lit bevel: top and left edges.
                    // Each layer is a card-sized hole, shifted down-right,
                    // inside a thick border. The border shows through as a
                    // thin strip along the top and left edges.
                    Repeater {
                        model: 3

                        delegate: Rectangle {
                            required property int index

                            readonly property int off: index + 1
                            readonly property int thick: 40

                            x: off - thick
                            y: off - thick

                            width: bulgeShading.width + thick * 2
                            height: bulgeShading.height + thick * 2

                            radius: card.radius + thick

                            color: "transparent"

                            border.width: thick
                            border.color:
                                Qt.alpha(pin.colCream, 0.07 * pin.k)
                        }
                    }


                    // Shaded bevel: bottom and right edges
                    Repeater {
                        model: 3

                        delegate: Rectangle {
                            required property int index

                            readonly property int off: index + 1
                            readonly property int thick: 40

                            x: -off - thick
                            y: -off - thick

                            width: bulgeShading.width + thick * 2
                            height: bulgeShading.height + thick * 2

                            radius: card.radius + thick

                            color: "transparent"

                            border.width: thick
                            border.color:
                                Qt.rgba(0, 0, 0, 0.12 * pin.k)
                        }
                    }
                }


                // ========================================================
                // CONTENT
                // ========================================================

                RowLayout {
                    anchors.fill: parent

                    anchors.margins: 20

                    spacing: 20


                    // =================================================
                    // CD / ALBUM ART
                    // =================================================

                    Item {
                        id: artWrap

                        Layout.preferredWidth: 128
                        Layout.preferredHeight: 128

                        Layout.alignment:
                            Qt.AlignVCenter


                        // -------------------------------------------------
                        // GOLD DASHED ORBIT
                        // -------------------------------------------------

                        Canvas {
                            id: orbit

                            anchors.centerIn: parent

                            width: parent.width + 14
                            height: parent.height + 14

                            // Slow counter-rotation, opposite to the CD.
                            RotationAnimation on rotation {
                                running: pin.isPlaying && pin.spinCD

                                from: 360
                                to: 0

                                duration: 24000

                                loops:
                                    Animation.Infinite

                                easing.type:
                                    Easing.Linear
                            }

                            // Canvas doesn't repaint on its own when a
                            // colour used inside onPaint changes.
                            Connections {
                                target: pin

                                function onColGoldChanged() {
                                    orbit.requestPaint()
                                }
                            }

                            onPaint: {
                                const ctx = getContext("2d")

                                ctx.reset()

                                ctx.strokeStyle =
                                    pin.colGold

                                ctx.globalAlpha = 0.65

                                ctx.lineWidth = 2

                                ctx.setLineDash([
                                    3,
                                    7
                                ])

                                ctx.beginPath()

                                ctx.arc(
                                    width / 2,
                                    height / 2,
                                    width / 2 - 2,
                                    0,
                                    Math.PI * 2
                                )

                                ctx.stroke()
                            }
                        }


                        // =================================================
                        // ROTATING CD
                        // =================================================

                        Item {
                            id: cd

                            width: 120
                            height: 120

                            anchors.centerIn: parent

                            transformOrigin:
                                Item.Center


                            // -------------------------------------------------
                            // Continuous CD rotation
                            // -------------------------------------------------

                            RotationAnimation on rotation {
                                running: pin.isPlaying && pin.spinCD

                                from: 0
                                to: 360

                                duration: 5000

                                loops:
                                    Animation.Infinite

                                easing.type:
                                    Easing.Linear
                            }


                            // =================================================
                            // CIRCULAR ALBUM ART
                            // ClippingRectangle clips its children to the
                            // rounded corner radius, so radius = width / 2
                            // gives a true circle.
                            // =================================================

                            ClippingRectangle {
                                id: circularArtwork

                                anchors.fill: parent

                                radius: width / 2

                                // Shown when there is no artwork.
                                color: pin.colTrack

                                Image {
                                    id: albumArt

                                    anchors.fill: parent

                                    source:
                                        pin.artSource

                                    fillMode:
                                        Image.PreserveAspectCrop

                                    asynchronous: true
                                    cache: true

                                    sourceSize:
                                        Qt.size(256, 256)

                                    smooth: true

                                    // Fades in when a new cover has loaded.
                                    opacity:
                                        status === Image.Ready
                                        ? 1
                                        : 0

                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: 260
                                        }
                                    }
                                }
                            }


                            // =================================================
                            // CD EDGE
                            // =================================================

                            Rectangle {
                                anchors.fill: parent

                                radius:
                                    width / 2

                                color:
                                    "transparent"

                                border.width: 1

                                border.color:
                                    "#88ffffff"

                                z: 10
                            }


                            // =================================================
                            // INNER CD RINGS
                            // =================================================

                            Rectangle {
                                anchors.fill: parent

                                anchors.margins: 8

                                radius:
                                    width / 2

                                color:
                                    "transparent"

                                border.width: 1

                                border.color:
                                    "#35ffffff"

                                opacity: 0.65

                                z: 11
                            }


                            Rectangle {
                                anchors.fill: parent

                                anchors.margins: 20

                                radius:
                                    width / 2

                                color:
                                    "transparent"

                                border.width: 1

                                border.color:
                                    "#25ffffff"

                                opacity: 0.6

                                z: 11
                            }


                            Rectangle {
                                anchors.fill: parent

                                anchors.margins: 34

                                radius:
                                    width / 2

                                color:
                                    "transparent"

                                border.width: 1

                                border.color:
                                    "#18ffffff"

                                opacity: 0.5

                                z: 11
                            }


                            // =================================================
                            // CD REFLECTION
                            // =================================================

                            Rectangle {
                                anchors.fill: parent

                                radius:
                                    width / 2

                                color:
                                    "transparent"

                                opacity: 0.16

                                z: 12

                                gradient: Gradient {
                                    orientation:
                                        Gradient.Vertical

                                    GradientStop {
                                        position: 0.0
                                        color: "#ffffff"
                                    }

                                    GradientStop {
                                        position: 0.38
                                        color: "#00ffffff"
                                    }

                                    GradientStop {
                                        position: 1.0
                                        color: "#000000"
                                    }
                                }
                            }


                            // =================================================
                            // CENTER LABEL
                            // =================================================

                            Rectangle {
                                id: cdCenter

                                width: 30
                                height: 30

                                radius: 15

                                anchors.centerIn:
                                    parent

                                color:
                                    pin.colBgBottom

                                border.width: 1

                                border.color:
                                    Qt.alpha(pin.colGold, 0.47)

                                z: 20


                                // Center hole
                                Rectangle {
                                    width: 9
                                    height: 9

                                    radius: 4.5

                                    anchors.centerIn:
                                        parent

                                    color:
                                        "#070605"

                                    border.width: 1

                                    border.color:
                                        "#80ffffff"
                                }
                            }
                        }
                    }


                    // =================================================
                    // INFO + CONTROLS
                    // =================================================

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        spacing: 8


                        // -------------------------------------------------
                        // TRACK INFO
                        // -------------------------------------------------

                        ColumnLayout {
                            id: trackInfo

                            Layout.fillWidth: true

                            spacing: 3

                            // Slide + fade in whenever the track changes.
                            transform: Translate {
                                id: trackShift
                            }

                            ParallelAnimation {
                                id: trackAnim

                                NumberAnimation {
                                    target: trackInfo
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    duration: 320
                                }

                                NumberAnimation {
                                    target: trackShift
                                    property: "x"
                                    from: -16
                                    to: 0
                                    duration: 380
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Connections {
                                target: pin

                                function onTrackKeyChanged() {
                                    trackAnim.restart()
                                }
                            }


                            Text {
                                Layout.fillWidth: true

                                text:
                                    pin.hasPlayer
                                    ? (
                                        pin.player.trackTitle ||
                                        "Unknown Title"
                                    )
                                    : "Nothing playing"

                                color:
                                    pin.colCream

                                font.pixelSize: 19
                                font.bold: true

                                elide:
                                    Text.ElideRight
                            }


                            Text {
                                Layout.fillWidth: true

                                text:
                                    pin.hasPlayer
                                    ? (
                                        pin.player.trackArtist ||
                                        "Unknown Artist"
                                    )
                                    : "Open a media player"

                                color:
                                    pin.colDim

                                font.pixelSize: 13

                                elide:
                                    Text.ElideRight
                            }


                            Text {
                                Layout.fillWidth: true

                                visible:
                                    pin.hasPlayer &&
                                    pin.player.trackAlbum !== ""

                                text:
                                    pin.hasPlayer
                                    ? pin.player.trackAlbum
                                    : ""

                                color:
                                    pin.colDim

                                opacity: 0.75

                                font.pixelSize: 11

                                elide:
                                    Text.ElideRight
                            }
                        }


                        Item {
                            Layout.fillHeight: true
                            Layout.minimumHeight: 0
                        }


                        // =================================================
                        // SEEK BAR (optional, see showSeekBar)
                        // =================================================

                        RowLayout {
                            Layout.fillWidth: true

                            visible:
                                pin.showSeekBar

                            spacing: 10


                            Text {
                                text:
                                    pin.hasPlayer
                                    ? pin.formatTime(
                                        pin.player.position
                                    )
                                    : "0:00"

                                color:
                                    pin.colDim

                                font.pixelSize: 11
                            }


                            Item {
                                id: seek

                                Layout.fillWidth: true

                                implicitHeight: 14

                                // Grows while hovered / dragged.
                                readonly property bool hot:
                                    seekMouse.containsMouse ||
                                    seekMouse.pressed

                                property real thick:
                                    hot ? 6 : 4

                                Behavior on thick {
                                    NumberAnimation {
                                        duration: 120
                                    }
                                }


                                readonly property real ratio:
                                    (
                                        pin.hasPlayer &&
                                        pin.player.length > 0
                                    )
                                    ? Math.max(
                                        0,
                                        Math.min(
                                            1,
                                            pin.player.position /
                                            pin.player.length
                                        )
                                    )
                                    : 0


                                Rectangle {
                                    anchors.verticalCenter:
                                        parent.verticalCenter

                                    width:
                                        parent.width

                                    height: seek.thick

                                    radius: seek.thick / 2

                                    color:
                                        pin.colTrack
                                }


                                Rectangle {
                                    anchors.verticalCenter:
                                        parent.verticalCenter

                                    width:
                                        parent.width *
                                        seek.ratio

                                    height: seek.thick

                                    radius: seek.thick / 2

                                    color:
                                        pin.colGold
                                }


                                Rectangle {
                                    width: seek.hot ? 14 : 12
                                    height: width

                                    radius: width / 2

                                    color:
                                        pin.colCream

                                    anchors.verticalCenter:
                                        parent.verticalCenter

                                    x:
                                        Math.max(
                                            0,
                                            Math.min(
                                                parent.width - width,
                                                parent.width *
                                                seek.ratio -
                                                width / 2
                                            )
                                        )

                                    visible:
                                        pin.hasPlayer
                                }


                                // Time bubble that follows the pointer.
                                Rectangle {
                                    visible:
                                        seekMouse.containsMouse &&
                                        pin.hasPlayer &&
                                        pin.player.length > 0

                                    width: bubbleText.implicitWidth + 14
                                    height: 18

                                    radius: 9

                                    color: "#c8000000"

                                    y: -height - 3

                                    x:
                                        Math.max(
                                            0,
                                            Math.min(
                                                seek.width - width,
                                                seekMouse.mouseX - 6 -
                                                width / 2
                                            )
                                        )

                                    Text {
                                        id: bubbleText

                                        anchors.centerIn: parent

                                        text:
                                            pin.formatTime(
                                                Math.max(
                                                    0,
                                                    Math.min(
                                                        1,
                                                        (seekMouse.mouseX - 6) /
                                                        Math.max(1, seek.width)
                                                    )
                                                ) * (
                                                    pin.hasPlayer
                                                    ? pin.player.length
                                                    : 0
                                                )
                                            )

                                        color: pin.colCream

                                        font.pixelSize: 10
                                    }
                                }


                                MouseArea {
                                    id: seekMouse

                                    anchors.fill: parent

                                    anchors.margins: -6

                                    hoverEnabled: true

                                    enabled:
                                        pin.hasPlayer &&
                                        pin.player.canSeek &&
                                        pin.player.length > 0

                                    // Wheel over the bar seeks instead of
                                    // changing the volume.
                                    WheelHandler {
                                        acceptedDevices:
                                            PointerDevice.Mouse |
                                            PointerDevice.TouchPad

                                        onWheel: (event) => {
                                            pin.seekBy(
                                                event.angleDelta.y > 0
                                                ? pin.seekStep
                                                : -pin.seekStep
                                            )
                                        }
                                    }

                                    // mouse.x - 6 undoes the -6 margin.
                                    onPressed: (mouse) => {
                                        pin.seekTo(
                                            mouse.x - 6,
                                            seek.width
                                        )
                                    }

                                    onPositionChanged: (mouse) => {
                                        if (pressed) {
                                            pin.seekTo(
                                                mouse.x - 6,
                                                seek.width
                                            )
                                        }
                                    }
                                }
                            }


                            Text {
                                // Click to switch between total length and
                                // time remaining.
                                text:
                                    !pin.hasPlayer
                                    ? "0:00"
                                    : (
                                        pin.showRemaining
                                        ? "-" + pin.formatTime(
                                            pin.player.length -
                                            pin.player.position
                                        )
                                        : pin.formatTime(
                                            pin.player.length
                                        )
                                    )

                                color:
                                    pin.colDim

                                font.pixelSize: 11

                                Layout.minimumWidth: 34

                                horizontalAlignment:
                                    Text.AlignRight

                                MouseArea {
                                    anchors.fill: parent

                                    anchors.margins: -4

                                    cursorShape:
                                        Qt.PointingHandCursor

                                    onClicked:
                                        pin.showRemaining =
                                            !pin.showRemaining
                                }
                            }
                        }


                        // =================================================
                        // BUTTONS  (previous / play-pause / next)
                        // =================================================

                        RowLayout {
                            Layout.alignment:
                                Qt.AlignHCenter

                            spacing: 14


                            // -------------------------------------------------
                            // Shuffle
                            // -------------------------------------------------

                            Rectangle {
                                visible:
                                    pin.showModeButtons

                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28

                                radius: 14

                                color:
                                    (
                                        pin.hasPlayer &&
                                        pin.player.shuffle
                                    )
                                    ? Qt.alpha(pin.colGold, 0.28)
                                    : pin.colButtonBg


                                Text {
                                    anchors.centerIn:
                                        parent

                                    text: "⇄"

                                    font.pixelSize: 13

                                    color:
                                        (
                                            pin.hasPlayer &&
                                            pin.player.shuffle
                                        )
                                        ? pin.colGold
                                        : pin.colCream

                                    opacity:
                                        (
                                            pin.hasPlayer &&
                                            pin.player.shuffleSupported
                                        )
                                        ? 1
                                        : 0.3
                                }


                                MouseArea {
                                    anchors.fill:
                                        parent

                                    enabled:
                                        pin.hasPlayer &&
                                        pin.player.shuffleSupported

                                    onClicked:
                                        pin.toggleShuffle()
                                }
                            }


                            // -------------------------------------------------
                            // Previous
                            // -------------------------------------------------

                            Rectangle {
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32

                                radius: 16

                                color:
                                    pin.colButtonBg


                                Text {
                                    anchors.centerIn:
                                        parent

                                    text: "◀◀"

                                    font.pixelSize: 10

                                    color:
                                        pin.colCream

                                    opacity:
                                        (
                                            pin.hasPlayer &&
                                            pin.player.canGoPrevious
                                        )
                                        ? 1
                                        : 0.35
                                }


                                MouseArea {
                                    anchors.fill:
                                        parent

                                    enabled:
                                        pin.hasPlayer &&
                                        pin.player.canGoPrevious

                                    onClicked:
                                        pin.player.previous()
                                }
                            }


                            // -------------------------------------------------
                            // Play / Pause
                            // -------------------------------------------------

                            Rectangle {
                                Layout.preferredWidth: 42
                                Layout.preferredHeight: 42

                                radius: 21

                                color:
                                    pin.colGold

                                opacity:
                                    (
                                        pin.hasPlayer &&
                                        (
                                            pin.player.canPlay ||
                                            pin.player.canPause ||
                                            pin.player.canTogglePlaying
                                        )
                                    )
                                    ? 1
                                    : 0.4


                                Text {
                                    anchors.centerIn:
                                        parent

                                    anchors.horizontalCenterOffset:
                                        pin.isPlaying ? 0 : 1

                                    text:
                                        pin.isPlaying
                                        ? "❚❚"
                                        : "▶"

                                    font.pixelSize: 15

                                    color:
                                        pin.colOnGold
                                }


                                MouseArea {
                                    anchors.fill:
                                        parent

                                    enabled:
                                        pin.hasPlayer &&
                                        (
                                            pin.player.canPlay ||
                                            pin.player.canPause ||
                                            pin.player.canTogglePlaying
                                        )

                                    onClicked:
                                        pin.togglePlayback()
                                }
                            }


                            // -------------------------------------------------
                            // Next
                            // -------------------------------------------------

                            Rectangle {
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32

                                radius: 16

                                color:
                                    pin.colButtonBg


                                Text {
                                    anchors.centerIn:
                                        parent

                                    text: "▶▶"

                                    font.pixelSize: 10

                                    color:
                                        pin.colCream

                                    opacity:
                                        (
                                            pin.hasPlayer &&
                                            pin.player.canGoNext
                                        )
                                        ? 1
                                        : 0.35
                                }


                                MouseArea {
                                    anchors.fill:
                                        parent

                                    enabled:
                                        pin.hasPlayer &&
                                        pin.player.canGoNext

                                    onClicked:
                                        pin.player.next()
                                }
                            }


                            // -------------------------------------------------
                            // Repeat (off -> playlist -> track)
                            // -------------------------------------------------

                            Rectangle {
                                id: repeatButton

                                visible:
                                    pin.showModeButtons

                                readonly property bool on:
                                    pin.hasPlayer &&
                                    pin.player.loopState !==
                                        MprisLoopState.None

                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28

                                radius: 14

                                color:
                                    on
                                    ? Qt.alpha(pin.colGold, 0.28)
                                    : pin.colButtonBg


                                Text {
                                    anchors.centerIn:
                                        parent

                                    text: "↻"

                                    font.pixelSize: 14

                                    color:
                                        repeatButton.on
                                        ? pin.colGold
                                        : pin.colCream

                                    opacity:
                                        (
                                            pin.hasPlayer &&
                                            pin.player.loopSupported
                                        )
                                        ? 1
                                        : 0.3
                                }


                                // "1" badge when repeating a single track
                                Text {
                                    visible:
                                        pin.hasPlayer &&
                                        pin.player.loopState ===
                                            MprisLoopState.Track

                                    anchors.centerIn:
                                        parent

                                    text: "1"

                                    font.pixelSize: 7
                                    font.bold: true

                                    color:
                                        pin.colGold
                                }


                                MouseArea {
                                    anchors.fill:
                                        parent

                                    enabled:
                                        pin.hasPlayer &&
                                        pin.player.loopSupported

                                    onClicked:
                                        pin.cycleLoop()
                                }
                            }
                        }
                    }
                }


                // ============================================================
                // SOURCE SWITCHER
                // ============================================================

                Rectangle {
                    id: sourceSwitcher

                    visible:
                        pin.players.length > 1

                    anchors.top:
                        parent.top

                    anchors.left:
                        parent.left

                    anchors.margins: 10

                    radius: 10

                    color:
                        "#00000066"

                    implicitHeight: 20

                    implicitWidth:
                        srcLabel.implicitWidth + 16


                    Text {
                        id: srcLabel

                        anchors.centerIn:
                            parent

                        text:
                            pin.hasPlayer
                            ? (
                                (
                                    pin.player.desktopEntry ||
                                    pin.player.identity
                                ) +
                                "  " +
                                (
                                    pin.players.indexOf(
                                        pin.player
                                    ) + 1
                                ) +
                                "/" +
                                pin.players.length
                            )
                            : ""

                        color:
                            pin.colDim

                        font.pixelSize: 10
                    }


                    MouseArea {
                        anchors.fill:
                            parent

                        cursorShape:
                            Qt.PointingHandCursor

                        onClicked: {
                            const count =
                                pin.players.length

                            if (count === 0)
                                return

                            const current =
                                pin.manualPlayerIndex >= 0
                                ? pin.manualPlayerIndex
                                : pin.players.indexOf(
                                    pin.player
                                )

                            pin.manualPlayerIndex =
                                (current + 1) % count
                        }
                    }
                }


                // ============================================================
                // LOCK BUTTON
                // Appears when the pointer is over the button's spot in the
                // top-right corner (see lockOnCardHover / lockHoverPad in
                // OPTIONS). It then swells out of the surface like a raised
                // dome: soft shadow beneath, lit from the top, with a
                // slight overshoot as it pops out.
                //
                // Hover is decided from the pointer POSITION reported by one
                // card-wide HoverHandler, instead of a hover-enabled
                // MouseArea on the button. That way the button's own
                // scale/fade animation can't shrink its hit area away, and
                // no child item can steal the hover from the card.
                // ============================================================

                HoverHandler {
                    id: cardHover

                    onPointChanged: {
                        if (pin.debugLock)
                            console.log(
                                "[mprispin] hover:", hovered,
                                "x:", point.position.x,
                                "y:", point.position.y,
                                "lock shown:", lockButton.shown
                            )
                    }
                }


                Item {
                    id: lockButton

                    width: 26
                    height: 26

                    anchors.top:
                        parent.top

                    anchors.right:
                        parent.right

                    anchors.margins: 10

                    // True while the pointer is within `pad` px of the
                    // button's rectangle (card coordinates).
                    function pointerWithin(pad) {
                        if (!cardHover.hovered)
                            return false

                        const p = cardHover.point.position

                        return p.x >= x - pad &&
                               p.x <= x + width + pad &&
                               p.y >= y - pad &&
                               p.y <= y + height + pad
                    }

                    readonly property bool shown:
                        pin.lockOnCardHover
                        ? cardHover.hovered
                        : (
                            pointerWithin(pin.lockHoverPad) ||
                            lockClick.containsMouse
                        )

                    // Pointer is directly over the button itself.
                    readonly property bool overButton:
                        pointerWithin(0) ||
                        lockClick.containsMouse

                    // Starts small and flat, swells past full size, settles.
                    // Dips slightly while pressed.
                    scale:
                        !shown
                        ? 0.55
                        : (
                            lockClick.pressed
                            ? 0.93
                            : 1.0
                        )

                    opacity:
                        shown
                        ? 1.0
                        : 0.0

                    Behavior on scale {
                        NumberAnimation {
                            duration: 300

                            easing.type:
                                Easing.OutBack

                            easing.overshoot: 2.2
                        }
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 220

                            easing.type:
                                Easing.OutQuad
                        }
                    }


                    // -------------------------------------------------
                    // Soft shadow under the bump (stacked translucent
                    // discs, largest and faintest first)
                    // -------------------------------------------------

                    Repeater {
                        model: [
                            { grow: 10, alpha: 0.05 },
                            { grow: 6,  alpha: 0.07 },
                            { grow: 2,  alpha: 0.10 }
                        ]

                        delegate: Rectangle {
                            required property var modelData

                            anchors.centerIn:
                                parent

                            anchors.verticalCenterOffset: 2

                            width:
                                lockButton.width + modelData.grow

                            height:
                                width

                            radius:
                                width / 2

                            color:
                                Qt.rgba(0, 0, 0, modelData.alpha)
                        }
                    }


                    // -------------------------------------------------
                    // The dome: lighter at the top, darker at the bottom
                    // -------------------------------------------------

                    Rectangle {
                        id: dome

                        anchors.fill:
                            parent

                        radius:
                            width / 2

                        gradient: Gradient {
                            orientation:
                                Gradient.Vertical

                            GradientStop {
                                position: 0.0

                                color:
                                    Qt.tint(
                                        pin.colSurfaceHighest,
                                        Qt.alpha(pin.colGold, 0.32)
                                    )
                            }

                            GradientStop {
                                position: 1.0

                                color:
                                    Qt.tint(
                                        pin.colSurfaceHighest,
                                        Qt.alpha(pin.colGold, 0.12)
                                    )
                            }
                        }

                        border.width: 1

                        border.color:
                            Qt.rgba(
                                1, 1, 1,
                                lockButton.overButton
                                ? 0.24
                                : 0.12
                            )


                        // Glossy highlight near the top-left
                        Rectangle {
                            width: 9
                            height: 5

                            radius: 2.5

                            x: 5
                            y: 4.5

                            rotation: -35

                            color:
                                Qt.rgba(1, 1, 1, 0.16)
                        }


                        // Padlock drawn from plain shapes so it follows the
                        // caelestia theme (accent when locked, dim when not).
                        Item {
                            id: lockIcon

                            width: 14
                            height: 16

                            anchors.centerIn:
                                parent

                            opacity:
                                lockButton.overButton
                                ? 1.0
                                : 0.75

                            readonly property color iconColor:
                                pin.locked
                                ? pin.colGold
                                : pin.colDim


                            // Shackle (drops into the body when locked,
                            // lifts away when unlocked)
                            Rectangle {
                                width: 10
                                height: 10

                                radius: 5

                                x: 2

                                y:
                                    pin.locked
                                    ? 0
                                    : -4

                                color:
                                    "transparent"

                                border.width: 2

                                border.color:
                                    lockIcon.iconColor

                                Behavior on y {
                                    NumberAnimation {
                                        duration: 140

                                        easing.type:
                                            Easing.OutQuad
                                    }
                                }
                            }


                            // Body
                            Rectangle {
                                width: 14
                                height: 9

                                radius: 2

                                y: 7

                                color:
                                    lockIcon.iconColor
                            }
                        }
                    }
                }


                // -------------------------------------------------
                // Click target for the lock button. It sits exactly on
                // the button, above the drag area, so clicking the lock
                // doesn't start a drag. It also reports hover, as a
                // second way (besides the pointer position from
                // cardHover) of knowing the pointer is on the button.
                // -------------------------------------------------

                // Mouse wheel over the card changes the volume (the seek bar
                // has its own wheel handler that seeks instead).
                WheelHandler {
                    acceptedDevices:
                        PointerDevice.Mouse |
                        PointerDevice.TouchPad

                    onWheel: (event) => {
                        pin.changeVolume(event.angleDelta.y)
                    }
                }


                MouseArea {
                    id: lockClick

                    x: lockButton.x
                    y: lockButton.y

                    width: lockButton.width
                    height: lockButton.height

                    hoverEnabled: true

                    cursorShape:
                        Qt.PointingHandCursor

                    onClicked:
                        pin.toggleLock()
                }


                // ============================================================
                // VOLUME TOAST
                // ============================================================

                Rectangle {
                    id: toast

                    anchors.horizontalCenter:
                        parent.horizontalCenter

                    anchors.top:
                        parent.top

                    anchors.topMargin: 10

                    width: toastRow.implicitWidth + 22
                    height: 22

                    radius: 11

                    color: "#b8000000"

                    opacity:
                        toastTimer.running
                        ? 1
                        : 0

                    visible:
                        opacity > 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 200
                        }
                    }

                    Row {
                        id: toastRow

                        anchors.centerIn:
                            parent

                        spacing: 8

                        Text {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            text:
                                pin.toastLabel

                            color:
                                pin.colCream

                            font.pixelSize: 11
                        }

                        Rectangle {
                            anchors.verticalCenter:
                                parent.verticalCenter

                            width: 56
                            height: 4

                            radius: 2

                            color:
                                pin.colTrack

                            Rectangle {
                                width:
                                    parent.width * pin.toastValue

                                height:
                                    parent.height

                                radius: 2

                                color:
                                    pin.colGold
                            }
                        }
                    }
                }
            }
        }
    }
}
