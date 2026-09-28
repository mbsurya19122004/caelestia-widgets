// shell.qml — standalone ChronoWidget (stopwatch / timer) for Hyprland,
// built on plain Quickshell. Single-file version.
//
// Design notes vs. the original two-file version:
//   - DRAG FIX: dragging used to write `posX`/`posY` into a
//     PersistentProperties object on every single pixel of movement, which
//     forces a disk write on every frame -> visible stutter. Now the drag
//     target is a plain, non-persisted Item; the position is only written
//     back to the persisted store once, when the drag finishes.
//   - RESTYLE: matches Caelestia's MPRIS/media widget — Material 3
//     tonal / filled icon buttons with hover + press state layers and
//     shape-morphing corners, the same colour roles (primary,
//     secondaryContainer, onSurfaceVariant ...) and no card border.
//   - ICONS: no emoji or unicode glyphs. Every icon is a vector path drawn
//     by the `Glyph` component and tinted from the scheme, so it always
//     matches the theme and needs no icon font.
//   - MERGE: ChronoWidget is now an inline `component` inside this file,
//     so there's only one file to ship/copy.
//   - KEYBOARD FIX: WlrKeyboardFocus was set to `None`, which tells the
//     compositor this layer-surface should never receive keyboard input.
//     That blocked the counters mode's TextInput fields from ever getting
//     keystrokes routed to them, even though they'd take local focus on
//     click. Switched to `OnDemand`, which grants keyboard focus only
//     while something inside the surface (a TextInput) actually has
//     active focus, and releases it the rest of the time — so typing
//     works in the counter label/amount fields without the widget
//     stealing focus from other windows while idle.
//   - COUNTER PERSISTENCE: counters used to live only in a
//     PersistentProperties field, which survives a live `qs` config
//     reload but not a full `qs kill` or a reboot. They're now written
//     as JSON to a real file (`$XDG_STATE_HOME/chrono-widget/counters.json`,
//     falling back to `~/.local/state/chrono-widget/counters.json`) on
//     every add/change/delete, and read back from that file on startup.
//   - DRAG GLITCH FIX: the drag handlers never re-anchored their
//     `pressX`/`pressY` reference point after each pointer move, so every
//     `onPositionChanged` measured distance from the *original* press
//     point rather than the last frame — and that ever-growing delta was
//     then added on top of the already-updated position each time,
//     compounding into runaway/jumpy movement. Dragging is now computed
//     as a pure function of total displacement from a fixed press-time
//     anchor (`setPosition(startLeft + dx, startTop + dy)`), so nothing
//     compounds across events and the widget tracks the cursor 1:1 with
//     no drift. The expanded panel is also now only draggable via its
//     header row (the title/icon strip), not anywhere on the card —
//     clicking the ring, controls, laps or counters no longer risks
//     starting a drag.
//
// This is a fully standalone module — it does NOT hook into the Caelestia
// shell. It only *optionally* reads the colour file that
// `caelestia scheme set` writes to, purely as a theme source. If that file
// doesn't exist, it falls back to a built-in dark palette.
//
// SETUP
//   1. Put this file in its own directory:
//        ~/.config/quickshell/chrono/shell.qml
//   2. Run it standalone: qs -c chrono
//   3. To start it with Hyprland, in your Hyprland config:
//        exec-once = qs -c chrono
//   4. To stop/reload just this widget:
//        qs -c chrono kill
//        qs -c chrono -d   (restart in the foreground, for debugging)
//   5. For real background blur, add a Hyprland layer rule:
//        layerrule = blur, chrono-widget
//        layerrule = ignorezero, chrono-widget
//   6. Delete/adjust the theme-file `path` in the FileView below if you're
//      not using Caelestia, or point it at whatever colour-scheme JSON you use.

import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    // ---- Icon set (24x24 grid, tinted from the theme) -------------------
    component Glyph: Item {
        id: g
        property string name
        property color color: "white"
        property real size: 22
        property bool filled: false      // outline -> filled variant (toggles)

        width: size; height: size
        layer.enabled: true
        layer.samples: 4

        // [stroked path, filled path]
        function def(n, on) {
            switch (n) {
            case "play":
                return ["", "M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"];
            case "pause":
                return ["", "M7 5.5a1.5 1.5 0 0 1 3 0v13a1.5 1.5 0 0 1-3 0z M14 5.5a1.5 1.5 0 0 1 3 0v13a1.5 1.5 0 0 1-3 0z"];
            case "reset":
                return ["M8.5 5.94A7 7 0 1 0 18.06 8.5", "M20.3 7.2L15.8 9.8L16.46 5.73z"];
            case "flag":
                return ["M6 20.5V4", "M6.5 5h11.2a.8.8 0 0 1 .6 1.3L15.5 9.5l2.8 3.2a.8.8 0 0 1-.6 1.3H6.5z"];
            case "pin": {
                var head = "M9 4h6l-.8 6.2L17 13v2H7v-2l2.8-2.8z";
                return on ? ["M12 15v5.5", head] : [head + " M12 15v5.5", ""];
            }
            case "swap":
                return ["M5 8.5h14M15.5 5l3.5 3.5-3.5 3.5M19 15.5H5M8.5 12L5 15.5 8.5 19", ""];
            case "chevron":
                return ["M6.5 9.5l5.5 5.5 5.5-5.5", ""];
            case "stopwatch":
                return ["M12 21a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15z M9.5 2.5h5 M12 2.5V6 M12 13.5l2.8-2.8", ""];
            case "hourglass":
                return ["M7 3.5h10 M7 20.5h10 M8 3.5c0 4.5 3 5.5 4 8.5-1 3-4 4-4 8.5 M16 3.5c0 4.5-3 5.5-4 8.5 1 3 4 4 4 8.5", ""];
            case "counter":
                return ["M12 3v18 M3 12h18", ""];
            case "undo":
                return ["M9 7H5v4 M5 7c1.8-2.4 4.2-3.5 7-3.5 5 0 9 3.5 9 8.5s-4 8.5-9 8.5c-2.4 0-4.5-.9-6.2-2.5", ""];
            case "trash":
                return ["M5 7h14 M9 7V4.8a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1V7 M7 7l1 13.2a1 1 0 0 0 1 .8h6a1 1 0 0 0 1-.8L17 7 M10 11v6 M14 11v6", ""];
            case "minus":
                return ["M5 12h14", ""];
            case "plus":
                return ["M12 5v14 M5 12h14", ""];
            }
            return ["", ""];
        }
        readonly property var d: def(name, filled)

        Shape {
            width: 24; height: 24
            scale: g.size / 24
            transformOrigin: Item.TopLeft

            ShapePath {
                strokeColor: g.color
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: g.d[0] || "M0 0" }
            }
            ShapePath {
                strokeColor: "transparent"
                fillColor: g.color
                PathSvg { path: g.d[1] || "M0 0" }
            }
        }
    }

    // ---- Icon button: mirrors Caelestia's IconButton (Filled / Tonal / Text)
    component IconBtn: Item {
        id: b
        required property var palette
        property string glyph
        property string kind: "tonal"    // "filled" | "tonal" | "text"
        property bool toggle: false      // toggles get an active colour + filled icon
        property bool checked: false     // active state (also morphs the corners)
        property real glyphSize: 22
        readonly property bool pressed: ma.pressed
        signal clicked()

        readonly property bool active: toggle && checked
        readonly property color bgColor: kind === "text" ? "transparent"
            : kind === "filled" ? palette.primary
            : active ? palette.secondary : palette.secondaryContainer
        readonly property color fgColor: kind === "filled" ? palette.onPrimary
            : kind === "tonal" ? (active ? palette.onSecondary : palette.onSecondaryContainer)
            : (active ? palette.primary : palette.onSurfaceVariant)

        opacity: enabled ? 1 : 0.38

        readonly property color glowColor: b.kind === "filled" ? b.palette.primary : b.fgColor
        property real glowOpacity: (ma.containsMouse && b.enabled) ? (b.kind === "filled" ? 0.85 : 0.55) : 0
        Behavior on glowOpacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Rectangle {
            id: bg
            anchors.fill: parent
            color: b.bgColor
            radius: b.pressed ? 12 : b.checked ? 16 : b.height / 2
            scale: b.pressed ? 0.92 : 1.0
            Behavior on radius { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 150 } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            // smooth glow hugging the button's own shape, only visible on hover
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.rgba(b.glowColor.r, b.glowColor.g, b.glowColor.b, b.glowOpacity)
                shadowBlur: 0.55
                shadowScale: 1.0
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }
        // state layer (hover 8%, press 10%, same as Caelestia)
        Rectangle {
            anchors.fill: parent
            radius: bg.radius
            color: b.fgColor
            opacity: ma.pressed ? 0.10 : ma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 100 } }
        }
        Glyph {
            anchors.centerIn: parent
            name: b.glyph
            size: b.glyphSize
            color: b.fgColor
            filled: !b.toggle || b.checked
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: b.clicked()
        }
    }

    // ---- Small pill button (timer +/- steps, "Clear") -------------------
    component Chip: Item {
        id: c
        required property var palette
        property string label
        property bool tonal: true
        signal clicked()

        implicitWidth: txt.implicitWidth + 20
        implicitHeight: 24
        width: implicitWidth; height: implicitHeight

        property real glowOpacity: cma.containsMouse ? 0.6 : 0
        Behavior on glowOpacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Rectangle {
            id: chipBg
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.palette.secondaryContainer : "transparent"

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.rgba(c.palette.primary.r, c.palette.primary.g, c.palette.primary.b, c.glowOpacity)
                shadowBlur: 0.5
                shadowScale: 1.0
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.palette.onSecondaryContainer : c.palette.primary
            opacity: cma.pressed ? 0.10 : cma.containsMouse ? 0.08 : 0
        }
        Text {
            id: txt
            anchors.centerIn: parent
            text: c.label
            color: c.palette.primary
            font.pixelSize: 11
            font.weight: Font.Medium
        }
        MouseArea {
            id: cma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: c.clicked()
        }
    }

    // ---- Minimalist counter card: circular progress ring + tiny controls
    component CounterCard: Rectangle {
        id: cc
        required property var palette
        property var entry   // { id, label, initial, remaining } or null for an empty slot
        signal decrement()
        signal increment()
        signal remove()

        radius: 18
        color: Qt.rgba(cc.palette.primary.r, cc.palette.primary.g, cc.palette.primary.b, 0.08)
        scale: hoverH.hovered ? 1.035 : 1.0
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        readonly property real frac: (cc.entry && cc.entry.initial > 0) ? cc.entry.remaining / cc.entry.initial : 0

        HoverHandler { id: hoverH }

        // subtle highlight border, brightens on hover — no glow/blur on the card itself
        Rectangle {
            anchors.fill: parent
            radius: cc.radius
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(cc.palette.primary.r, cc.palette.primary.g, cc.palette.primary.b, hoverH.hovered ? 0.38 : 0.12)
            Behavior on border.color { ColorAnimation { duration: 160 } }
        }

        IconBtn {
            palette: cc.palette
            width: 22; height: 22
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 4
            kind: "text"
            glyph: "trash"
            glyphSize: 13
            onClicked: cc.remove()
        }

        Column {
            anchors.centerIn: parent
            spacing: 4
            width: parent.width - 16

            Text {
                width: parent.width
                text: cc.entry ? cc.entry.label : ""
                color: cc.palette.primary
                font.pixelSize: 10
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }

            Item {
                width: 60; height: 60
                anchors.horizontalCenter: parent.horizontalCenter

                Shape {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 4
                    ShapePath {
                        strokeWidth: 5
                        strokeColor: Qt.rgba(cc.palette.primary.r, cc.palette.primary.g, cc.palette.primary.b, 0.20)
                        fillColor: "transparent"
                        PathAngleArc { centerX: 30; centerY: 30; radiusX: 27; radiusY: 27; startAngle: -90; sweepAngle: 360 }
                    }
                    ShapePath {
                        strokeWidth: 5
                        strokeColor: cc.palette.primary
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: 30; centerY: 30; radiusX: 27; radiusY: 27; startAngle: -90; sweepAngle: 360 * cc.frac }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    text: cc.entry ? String(cc.entry.remaining) : ""
                    color: cc.palette.primary
                    font.pixelSize: 16
                    font.bold: true
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                IconBtn {
                    palette: cc.palette
                    width: 26; height: 26
                    kind: "tonal"
                    glyph: "minus"
                    glyphSize: 14
                    onClicked: cc.decrement()
                }
                IconBtn {
                    palette: cc.palette
                    width: 26; height: 26
                    kind: "tonal"
                    glyph: "plus"
                    glyphSize: 14
                    onClicked: cc.increment()
                }
            }
        }
    }

    component ChronoWidget: PanelWindow {
        id: root

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        // FIX: was WlrKeyboardFocus.None, which never routes keyboard
        // input to this surface at all — that silently broke typing into
        // the counters mode's TextInput fields. OnDemand grants keyboard
        // focus only while something inside the surface (a TextInput)
        // has active focus, and releases it otherwise.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "chrono-widget"

        color: "transparent"

        anchors {
            top: true
            left: true
        }

        // ---- persisted bits (survive a `qs -c` config reload) --------------
        PersistentProperties {
            id: mem
            reloadableId: "chronoWidget"

            property real posX: 60
            property real posY: 60
            property int mode: 0        // 0 = stopwatch, 1 = timer, 2 = counters
            property bool pinned: false
            property int timerDurationMs: 5 * 60 * 1000
        }

        // ---- position: bound to the persisted store, dragged by delta --------
        margins.left: mem.posX
        margins.top: mem.posY

        // Drag options (off by default — same behaviour as before unless
        // you turn clampToScreen on).
        property bool clampToScreen: false
        property int snapDistance: 14
        property int edgeGap: 8

        // Absolute positioning, computed fresh each call from whatever
        // (l, t) is passed in — this is what dragging anchors to, so a
        // drag is a pure function of total pointer displacement since
        // press rather than a running sum of per-frame deltas. Any single
        // event's coordinate quirk can't drift the position, because
        // nothing is compounded across events.
        function setPosition(l, t) {
            if (clampToScreen && root.screen && root.screen.width > 0) {
                var minL = edgeGap, maxL = root.screen.width - root.width - edgeGap;
                var minT = edgeGap, maxT = root.screen.height - root.height - edgeGap;

                if (Math.abs(l - minL) < snapDistance) l = minL;
                if (Math.abs(l - maxL) < snapDistance) l = maxL;
                if (Math.abs(t - minT) < snapDistance) t = minT;
                if (Math.abs(t - maxT) < snapDistance) t = maxT;

                l = Math.max(minL, Math.min(maxL, l));
                t = Math.max(minT, Math.min(maxT, t));
            }

            root.margins.left = l;
            root.margins.top = t;
        }

        // Relative move, kept for convenience — just delegates to setPosition.
        function moveBy(dx, dy) {
            setPosition(root.margins.left + dx, root.margins.top + dy);
        }

        function commitPosition() {
            mem.posX = root.margins.left;
            mem.posY = root.margins.top;
        }

        // ---- optional external colour scheme (Caelestia's scheme.json, or none) ----
        readonly property string stateDir:
            Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
        readonly property string schemePath: stateDir + "/caelestia/scheme.json"

        // ---- counters: persisted to a real file on disk, not just
        // PersistentProperties (which only survives a live QML reload, not
        // a full `qs kill` or a reboot). Written any time a counter is
        // added, changed, reset or deleted; read back on startup.
        readonly property string counterStateDir: stateDir + "/chrono-widget"
        readonly property string counterStatePath: counterStateDir + "/counters.json"

        Process {
            id: ensureCounterDir
            command: ["mkdir", "-p", root.counterStateDir]
            running: true
        }

        FileView {
            id: counterStore
            path: root.counterStatePath
            watchChanges: false
            onLoaded: {
                try {
                    var parsed = JSON.parse(text());
                    root.counters = Array.isArray(parsed) ? parsed : [];
                } catch (e) {
                    console.warn("[chrono-widget] invalid counters.json:", e);
                    root.counters = [];
                }
            }
            onLoadFailed: (error) => {
                // No file yet (first run) — start with an empty list.
                root.counters = [];
            }
        }

        QtObject {
            id: pal
            // Raw "colours" map from scheme.json (hex strings, no '#').
            property var sch: ({})

            function c(role, fallback) {
                var v = sch[role];
                if (v === undefined || v === null || v === "") return fallback;
                return v.toString().charAt(0) === "#" ? v : ("#" + v);
            }

            // ---- theme polarity ---------------------------------------------
            // Simple rule: dark card -> light text, light card -> dark text.
            function lum(col) { return 0.299 * col.r + 0.587 * col.g + 0.114 * col.b; }

            // Raw roles straight from the scheme (or the fallback palette).
            property color background: c("background", "#1b1d24")
            property color surface: c("surfaceContainer", c("surface", "#232530"))
            property color surfaceHigh: c("surfaceContainerHigh", c("surfaceVariant", "#2b2e39"))
            property color outline: c("outline", "#8b8d98")
            property color secondary: c("secondary", "#bcc7dc")
            property color secondaryContainer: c("secondaryContainer", "#3d4759")
            property color rawPrimary: c("primary", "#a6c8ff")

            // true when the card/disc surfaces are dark
            readonly property bool dark: lum(surface) < 0.5

            // Text drawn straight on the card / disc / lap box.
            // (all text now uses the accent colour instead — set below)

            // Accent (icons, ring, "Clear"): keep the scheme hue, but make
            // sure it is light enough on dark cards / dark enough on light ones.
            property color primary: dark
                ? (lum(rawPrimary) >= 0.55 ? rawPrimary : Qt.lighter(rawPrimary, 1.0 + (0.55 - lum(rawPrimary)) * 3.5))
                : (lum(rawPrimary) <= 0.4 ? rawPrimary : Qt.darker(rawPrimary, 1.0 + (lum(rawPrimary) - 0.4) * 3.5))

            // Text on coloured buttons: pick by the button's own luminance.
            property color onPrimary: lum(primary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondary: lum(secondary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondaryContainer: lum(secondaryContainer) > 0.5 ? "#101015" : "#f4f4fa"

            // Text = accent colour. Secondary text is the same accent, softened.
            property color onSurface: primary
            property color onSurfaceVariant: Qt.rgba(primary.r, primary.g, primary.b, 0.75)
            property color muted: onSurfaceVariant
        }

        // Watches the scheme file and reloads whenever `caelestia scheme
        // set` (or the dynamic wallpaper-scheme writer) touches it, so
        // every colour in `pal` updates live, in place, with no restart.
        // Reading via onLoaded (rather than binding straight to a `text`
        // property) means we only parse once the read has actually
        // finished, and onLoadFailed gives us a clear signal — and a log
        // line — when the file is missing instead of silently keeping
        // stale colours forever.
        FileView {
            id: schemeFile
            path: root.schemePath
            watchChanges: true
            onFileChanged: reload()
            onLoaded: {
                try {
                    const data = JSON.parse(text());
                    // Accept either `{ colours: {...} }` (Caelestia's
                    // usual shape) or a flat `{ primary: ..., ... }` file.
                    pal.sch = (data && data.colours) ? data.colours : (data || {});
                } catch (e) {
                    // Can happen if we read mid-write; keep the last good
                    // scheme, the next change event will fix it.
                    console.warn("[chrono-widget] could not parse scheme.json:", e);
                }
            }
            onLoadFailed: (error) => {
                console.warn("[chrono-widget] could not read", root.schemePath, error);
            }
        }

        // ---- expand / collapse -----------------------------------------------
        property bool running: false
        property bool manualOpen: false

        // Expansion is controlled only by the UI toggle/pin state.
        // Starting, pausing, or resetting the stopwatch must not close it.
        property bool expanded: manualOpen || mem.pinned

        implicitWidth: expanded ? 340 : 52
        implicitHeight: expanded ? content.implicitHeight + 36 : 52
        Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // ---- stopwatch state --------------------------------------------------
        property real swStartedAt: 0
        property real swAccumMs: 0
        property real swElapsedMs: 0
        property var laps: []

        // ---- timer state --------------------------------------------------
        property real tmEndAt: 0
        property real tmRemainingMs: mem.timerDurationMs
        property bool tmFinished: false

        // ---- persistent counters ---------------------------------------------
        property var counters: []
        property string newCounterLabel: ""
        property int newCounterAmount: 10

        function saveCounters() {
            counterStore.setText(JSON.stringify(root.counters));
        }

        function addCounter(label, amount) {
            label = (label || "").trim();
            amount = Math.max(1, Math.floor(Number(amount) || 0));
            if (!label) label = "Counter " + (root.counters.length + 1);
            var list = root.counters.slice();
            list.push({
                id: Date.now() + Math.random(),
                label: label,
                initial: amount,
                remaining: amount
            });
            root.counters = list;
            saveCounters();
            root.newCounterLabel = "";
            root.newCounterAmount = 10;
        }

        function changeCounter(index, delta) {
            if (index < 0 || index >= root.counters.length) return;
            var list = root.counters.slice();
            list[index].remaining = Math.min(list[index].initial, list[index].remaining + delta);
            root.counters = list;
            saveCounters();
        }

        function resetCounter(index) {
            if (index < 0 || index >= root.counters.length) return;
            var list = root.counters.slice();
            list[index].remaining = list[index].initial;
            root.counters = list;
            saveCounters();
        }

        function deleteCounter(index) {
            if (index < 0 || index >= root.counters.length) return;
            var list = root.counters.slice();
            list.splice(index, 1);
            root.counters = list;
            saveCounters();
        }

        Timer {
            interval: 16
            running: root.running
            repeat: true
            onTriggered: {
                if (mem.mode === 0) {
                    root.swElapsedMs = root.swAccumMs + (Date.now() - root.swStartedAt);
                } else if (mem.mode === 1) {
                    var rem = root.tmEndAt - Date.now();
                    if (rem <= 0) {
                        root.tmRemainingMs = 0;
                        root.running = false;
                        root.tmFinished = true;
                    } else {
                        root.tmRemainingMs = rem;
                    }
                }
            }
        }

        function fmt(ms, withHour) {
            var h = Math.floor(ms / 3600000);
            var m = Math.floor((ms % 3600000) / 60000);
            var s = Math.floor((ms % 60000) / 1000);
            var cs = Math.floor((ms % 1000) / 10);
            function pad(n) { return (n < 10 ? "0" : "") + n; }
            return (withHour ? pad(h) + ":" : "") + pad(m) + ":" + pad(s) + "." + pad(cs);
        }

        function toggleStart() {
            if (mem.mode === 2) return;
            if (mem.mode === 0) {
                if (root.running) {
                    root.swAccumMs = root.swElapsedMs;
                    root.running = false;
                } else {
                    root.swStartedAt = Date.now();
                    root.running = true;
                }
            } else {
                if (root.tmRemainingMs <= 0) return;
                if (root.running) {
                    root.tmRemainingMs = root.tmEndAt - Date.now();
                    root.running = false;
                } else {
                    root.tmFinished = false;
                    root.tmEndAt = Date.now() + root.tmRemainingMs;
                    root.running = true;
                }
            }
        }

        function reset() {
            root.running = false;
            if (mem.mode === 0) {
                root.swAccumMs = 0; root.swElapsedMs = 0; root.laps = [];
            } else if (mem.mode === 1) {
                root.tmFinished = false;
                root.tmRemainingMs = mem.timerDurationMs;
            }
        }

        function lap() {
            if (mem.mode !== 0 || !root.running) return;
            var l = root.laps.slice();
            l.push(root.swElapsedMs);
            root.laps = l;
        }

        function adjustTimer(deltaMs) {
            if (mem.mode !== 1 || root.running) return;
            mem.timerDurationMs = Math.max(0, Math.min(99 * 3600000, mem.timerDurationMs + deltaMs));
            root.tmRemainingMs = mem.timerDurationMs;
        }

        // ================= UI =================
        Rectangle {
            id: card
            anchors.fill: parent
            radius: root.expanded ? 24 : height / 2
            color: Qt.rgba(pal.surface.r, pal.surface.g, pal.surface.b, 0.97)
            border.width: 1
            border.color: Qt.rgba(pal.primary.r, pal.primary.g, pal.primary.b, 0.10)
            Behavior on radius { NumberAnimation { duration: 160 } }

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.rgba(0, 0, 0, 0.45)
                shadowBlur: 0.7
                shadowVerticalOffset: 3
                shadowHorizontalOffset: 0
            }

            // faint top-light / bottom-shade sheen for a touch of depth
            Rectangle {
                anchors.fill: parent
                radius: card.radius
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.05) }
                    GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.0) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.06) }
                }
            }

            // ---------------- collapsed icon ----------------
            MouseArea {
                anchors.fill: parent
                visible: !root.expanded
                enabled: !root.expanded && !mem.pinned
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                property real pressX: 0
                property real pressY: 0
                property real travel: 0   // total pointer travel, to tell a click from a drag
                property real startLeft: 0
                property real startTop: 0

                onPressed: (mouse) => {
                    pressX = mouse.x; pressY = mouse.y; travel = 0;
                    startLeft = root.margins.left;
                    startTop = root.margins.top;
                }
                onPositionChanged: (mouse) => {
                    if (!pressed) return;
                    var dx = mouse.x - pressX, dy = mouse.y - pressY;
                    travel = Math.abs(dx) + Math.abs(dy);
                    // always computed from the fixed press-time anchor, so
                    // the widget tracks total cursor displacement 1:1 with
                    // no per-frame drift.
                    root.setPosition(startLeft + dx, startTop + dy);
                }
                onReleased: {
                    root.commitPosition();
                    if (travel <= 4) root.manualOpen = !root.manualOpen;
                }

                Rectangle {
                    anchors.fill: parent
                    radius: card.radius
                    color: pal.primary
                    opacity: parent.pressed ? 0.10 : parent.containsMouse ? 0.08 : 0
                }
                Glyph {
                    anchors.centerIn: parent
                    name: mem.mode === 0 ? "stopwatch" : (mem.mode === 1 ? "hourglass" : "counter")
                    color: pal.primary
                    size: 24
                }
            }

            // ---------------- expanded panel ----------------
            Column {
                id: content
                visible: root.expanded
                anchors.fill: parent
                anchors.margins: 18
                spacing: 14

                // header — also doubles as the drag handle for the expanded panel
                Item {
                    width: parent.width
                    height: 32

                    MouseArea {
                        id: headerDrag
                        anchors.fill: parent
                        enabled: !mem.pinned
                        z: -1
                        cursorShape: Qt.SizeAllCursor

                        property real pressX: 0
                        property real pressY: 0
                        property real startLeft: 0
                        property real startTop: 0

                        onPressed: (mouse) => {
                            pressX = mouse.x; pressY = mouse.y;
                            startLeft = root.margins.left;
                            startTop = root.margins.top;
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed) return;
                            // computed from the fixed press-time anchor —
                            // see the note on the collapsed-icon handler.
                            root.setPosition(startLeft + (mouse.x - pressX), startTop + (mouse.y - pressY));
                        }
                        onReleased: root.commitPosition()
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Glyph {
                            anchors.verticalCenter: parent.verticalCenter
                            name: mem.mode === 0 ? "stopwatch" : (mem.mode === 1 ? "hourglass" : "counter")
                            color: pal.primary
                            size: 20
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: mem.mode === 0 ? "Stopwatch" : (mem.mode === 1 ? "Timer" : "Counters")
                            color: pal.primary
                            font.pixelSize: 16
                            font.weight: Font.Medium
                            font.letterSpacing: 0.3
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        IconBtn {
                            palette: pal
                            width: 32; height: 32
                            kind: "text"; toggle: true
                            glyph: "pin"; glyphSize: 20
                            checked: mem.pinned
                            onClicked: mem.pinned = !mem.pinned
                        }
                        IconBtn {
                            palette: pal
                            width: 32; height: 32
                            kind: "text"
                            glyph: "swap"; glyphSize: 20
                            visible: !root.running
                            onClicked: mem.mode = mem.mode === 0 ? 1 : (mem.mode === 1 ? 2 : 0)
                        }
                        IconBtn {
                            palette: pal
                            width: 32; height: 32
                            kind: "text"
                            glyph: "chevron"; glyphSize: 20
                            onClicked: { root.manualOpen = false; mem.pinned = false }
                        }
                    }
                }

                // ---- stopwatch / timer / counters -----------------------------
                Item {
                    width: parent.width
                    height: mem.mode === 2 ? 300 : 196

                    Shape {
                        id: ring
                        anchors.centerIn: parent
                        width: 188; height: 188
                        visible: mem.mode !== 2
                        layer.enabled: true
                        layer.samples: 4
                        property real frac: mem.mode === 0
                            ? ((root.swElapsedMs % 60000) / 60000)
                            : (mem.timerDurationMs > 0 ? root.tmRemainingMs / mem.timerDurationMs : 0)
                        ShapePath {
                            strokeWidth: 6
                            strokeColor: Qt.rgba(pal.primary.r, pal.primary.g, pal.primary.b, 0.22)
                            fillColor: "transparent"
                            PathAngleArc {
                                centerX: 94; centerY: 94
                                radiusX: 91; radiusY: 91
                                startAngle: -90; sweepAngle: 360
                            }
                        }
                        ShapePath {
                            strokeWidth: 6
                            strokeColor: pal.primary
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: 94; centerY: 94
                                radiusX: 91; radiusY: 91
                                startAngle: -90
                                sweepAngle: mem.mode === 0 ? 360 * ring.frac : -360 * (1 - ring.frac)
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 168; height: 168; radius: 84
                        color: pal.surfaceHigh
                        visible: mem.mode !== 2
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        visible: mem.mode !== 2
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 134
                            horizontalAlignment: Text.AlignHCenter
                            text: mem.mode === 0 ? root.fmt(root.swElapsedMs, root.swElapsedMs >= 3600000) : root.fmt(root.tmRemainingMs, mem.timerDurationMs >= 3600000)
                            color: pal.primary
                            font.pixelSize: 30
                            font.bold: true
                            font.family: "monospace"
                            fontSizeMode: Text.Fit
                            minimumPixelSize: 16
                        }
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 6
                            visible: mem.mode === 1 && !root.running
                            Column {
                                spacing: 4
                                Chip { palette: pal; width: 46; label: "+1m"; onClicked: root.adjustTimer(60000) }
                                Chip { palette: pal; width: 46; label: "−1m"; onClicked: root.adjustTimer(-60000) }
                            }
                            Column {
                                spacing: 4
                                Chip { palette: pal; width: 46; label: "+10s"; onClicked: root.adjustTimer(10000) }
                                Chip { palette: pal; width: 46; label: "−10s"; onClicked: root.adjustTimer(-10000) }
                            }
                        }
                    }

                    Column {
                        anchors.fill: parent
                        spacing: 8
                        visible: mem.mode === 2

                        Row {
                            width: parent.width
                            height: 38
                            spacing: 6

                            TextInput {
                                id: counterLabelInput
                                width: parent.width - 112
                                height: 38
                                text: root.newCounterLabel
                                color: pal.primary
                                font.pixelSize: 13
                                verticalAlignment: TextInput.AlignVCenter
                                leftPadding: 12
                                rightPadding: 12
                                clip: true
                                selectByMouse: true
                                activeFocusOnPress: true
                                onTextChanged: root.newCounterLabel = text
                                Rectangle {
                                    anchors.fill: parent
                                    z: -1
                                    radius: 19
                                    color: Qt.rgba(pal.primary.r, pal.primary.g, pal.primary.b, 0.10)
                                }
                            }

                            TextInput {
                                id: counterAmountInput
                                width: 48
                                height: 38
                                text: String(root.newCounterAmount)
                                color: pal.primary
                                font.pixelSize: 13
                                horizontalAlignment: TextInput.AlignHCenter
                                verticalAlignment: TextInput.AlignVCenter
                                inputMethodHints: Qt.ImhDigitsOnly
                                validator: IntValidator { bottom: 1; top: 999999 }
                                activeFocusOnPress: true
                                onEditingFinished: root.newCounterAmount = Math.max(1, parseInt(text) || 1)
                                Rectangle {
                                    anchors.fill: parent
                                    z: -1
                                    radius: 19
                                    color: pal.surfaceHigh
                                }
                            }

                            Chip {
                                palette: pal
                                width: 50
                                height: 38
                                label: "Add"
                                onClicked: root.addCounter(counterLabelInput.text, counterAmountInput.text)
                            }
                        }

                        // Paged 2x2 grid of counter cards — up to 4 cards
                        // per page, extra counters scroll to further pages
                        // with one-page-at-a-time snapping.
                        ListView {
                            id: counterPagesView
                            width: parent.width
                            height: 238
                            clip: true
                            orientation: ListView.Horizontal
                            snapMode: ListView.SnapOneItem
                            highlightRangeMode: ListView.StrictlyEnforceRange
                            preferredHighlightBegin: 0
                            preferredHighlightEnd: width
                            boundsBehavior: Flickable.StopAtBounds
                            model: {
                                var pages = [];
                                for (var i = 0; i < root.counters.length; i += 4)
                                    pages.push(root.counters.slice(i, i + 4));
                                if (pages.length === 0) pages.push([]);
                                return pages;
                            }
                            delegate: Item {
                                id: pageItem
                                required property var modelData
                                required property int index
                                width: counterPagesView.width
                                height: counterPagesView.height

                                Grid {
                                    anchors.fill: parent
                                    columns: 2
                                    rows: 2
                                    columnSpacing: 8
                                    rowSpacing: 8

                                    Repeater {
                                        model: 4
                                        delegate: Item {
                                            id: slot
                                            required property int index
                                            width: (pageItem.width - 8) / 2
                                            height: (pageItem.height - 8) / 2
                                            readonly property var cdata: slot.index < pageItem.modelData.length ? pageItem.modelData[slot.index] : null

                                            CounterCard {
                                                anchors.fill: parent
                                                visible: slot.cdata !== null
                                                palette: pal
                                                entry: slot.cdata
                                                onDecrement: root.changeCounter(pageItem.index * 4 + slot.index, -1)
                                                onIncrement: root.changeCounter(pageItem.index * 4 + slot.index, 1)
                                                onRemove: root.deleteCounter(pageItem.index * 4 + slot.index)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // page dots — only shown once counters spill past one page
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: 8
                            spacing: 6
                            visible: counterPagesView.count > 1

                            Repeater {
                                model: counterPagesView.count
                                delegate: Rectangle {
                                    required property int index
                                    width: 6; height: 6; radius: 3
                                    color: pal.primary
                                    opacity: index === counterPagesView.currentIndex ? 0.9 : 0.25
                                }
                            }
                        }
                    }
                }

                // controls — same layout as the MPRIS button row:
                // tonal | filled (stretches, morphs while active) | tonal
                Row {
                    width: parent.width
                    height: 56
                    spacing: 4
                    visible: mem.mode !== 2

                    IconBtn {
                        palette: pal
                        width: 56; height: 56
                        kind: "tonal"
                        glyph: "reset"
                        onClicked: root.reset()
                    }
                    IconBtn {
                        palette: pal
                        width: parent.width - 56 * 2 - 4 * 2; height: 56
                        kind: "filled"
                        checked: root.running
                        glyph: root.running ? "pause" : "play"
                        onClicked: root.toggleStart()
                    }
                    IconBtn {
                        palette: pal
                        width: 56; height: 56
                        kind: "tonal"
                        glyph: "flag"
                        enabled: mem.mode === 0
                        onClicked: root.lap()
                    }
                }

                // laps
                Rectangle {
                    width: parent.width
                    height: 12 + 24 + 4 + 66 + 12
                    radius: 16
                    color: pal.surfaceHigh
                    visible: mem.mode === 0 && root.laps.length > 0

                    Item {
                        anchors.fill: parent
                        anchors.margins: 12

                        Item {
                            id: lapHeader
                            width: parent.width
                            height: 24
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Laps"
                                color: pal.primary
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                            Chip {
                                palette: pal
                                anchors.right: parent.right
                                tonal: false
                                label: "Clear"
                                onClicked: root.laps = []
                            }
                        }

                        ListView {
                            anchors.top: lapHeader.bottom
                            anchors.topMargin: 4
                            width: parent.width
                            height: 66
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.laps.slice().reverse()
                            delegate: Item {
                                width: ListView.view.width
                                height: 22
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "#" + (root.laps.length - index)
                                    color: pal.primary
                                    font.pixelSize: 12
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.fmt(modelData, false)
                                    color: pal.primary
                                    font.pixelSize: 12
                                    font.family: "monospace"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    ChronoWidget {}
}
