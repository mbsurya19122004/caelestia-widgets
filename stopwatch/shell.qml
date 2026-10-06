// shell.qml — ChronoWidget (stopwatch / timer / counters) for Hyprland.
// Standalone, single-file, plain Quickshell.
//
// WHAT CHANGED IN THIS REVISION
//   - DRAGGING (the real fix): the layer surface is now full-screen and only
//     the card is input-enabled (`mask: Region`). The card is a normal Item
//     that moves inside a fixed window, so pointer coordinates (mapped to the
//     window) never shift under your cursor. Result: 1:1 tracking, no jitter,
//     no per-frame layer-shell reconfigure, no disk writes while dragging.
//   - SMOOTHNESS: the old card was one big `layer.enabled` item with a blur
//     shadow, so the whole widget was re-rendered into a texture every frame
//     while the stopwatch ran. The shadow is now a few cheap static
//     translucent rects behind the card, and the hover glow is a halo rect
//     instead of a per-button MultiEffect.
//   - LAYOUT: one spacing system (20 px card padding, 16 px between sections,
//     8 px between buttons). Counter cards use a fixed inner layout
//     (label row / trash on top, [-] ring [+] below) so nothing overlaps.
//     The expand/collapse is animated on a fixed surface, and content is
//     clipped + faded so it never spills outside the card mid-animation.
//   - BUGS FIXED: counters could go below 0; changing page reset the counter
//     view on every +/- click (now a simple page index); the timer ring drew
//     the *elapsed* arc instead of the remaining one; the timer could not be
//     restarted after finishing; adjusting a paused timer threw away the
//     remaining time; mode-swap button made the header jump when hidden
//     (now just disabled); counter text fields had no placeholder / Enter /
//     Escape handling and the surface kept keyboard focus after typing.
//   - PERSISTENCE: position, mode, pin state and timer length are saved to
//     $XDG_STATE_HOME/chrono-widget/settings.json (debounced, only on
//     release / change), counters to counters.json — survives `qs kill`
//     and reboots.
//   - EXTRAS: timer sends a desktop notification and blinks when done,
//     collapsed icon shows a pulsing dot while running, laps show split +
//     total, double-click a counter ring to reset it, mouse wheel / dots to
//     page counters, Enter adds a counter, Escape leaves a text field.
//
// SETUP
//   1. Put this file at ~/.config/quickshell/chrono/shell.qml
//   2. Run:           qs -c chrono
//   3. Autostart:     exec-once = qs -c chrono        (Hyprland config)
//   4. Debug/restart: qs -c chrono kill ; qs -c chrono -d
//   5. Optional blur (namespace is "chrono-widget"):
//        older Hyprland:  layerrule = blur, chrono-widget
//                         layerrule = ignorezero, chrono-widget
//        newer Hyprland:  layerrule = blur on, match:namespace chrono-widget
//   6. Theme: reads ~/.local/state/caelestia/scheme.json if present (live
//      reload), otherwise uses the built-in dark palette.

import QtQuick
import QtQuick.Shapes
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

    // ---- Icon button: Caelestia-style Filled / Tonal / Text -------------
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
        scale: pressed ? 0.94 : 1.0
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        // hover amount 0..1 drives the halo (cheap glow, no shader effect)
        property real hover: (ma.containsMouse && b.enabled) ? 1 : 0
        Behavior on hover { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        readonly property real haloScale: kind === "text" ? 0 : (kind === "filled" ? 1.0 : 0.6)
        Rectangle {
            anchors.fill: bg
            anchors.margins: -4
            radius: bg.radius + 4
            color: b.bgColor
            opacity: b.hover * b.haloScale * 0.14
        }
        Rectangle {
            anchors.fill: bg
            anchors.margins: -2
            radius: bg.radius + 2
            color: b.bgColor
            opacity: b.hover * b.haloScale * 0.22
        }

        Rectangle {
            id: bg
            anchors.fill: parent
            color: b.bgColor
            radius: Math.min(b.height / 2, b.pressed ? 12 : (b.checked ? 16 : b.height / 2))
            Behavior on radius { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        // state layer (hover 8%, press 10%)
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

    // ---- Small pill button (timer steps, "Clear") -----------------------
    component Chip: Item {
        id: c
        required property var palette
        property string label
        property bool tonal: true
        signal clicked()

        implicitWidth: txt.implicitWidth + 24
        implicitHeight: 24
        width: implicitWidth; height: implicitHeight
        scale: cma.pressed ? 0.95 : 1.0
        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.palette.secondaryContainer : "transparent"
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.palette.onSecondaryContainer : c.palette.primary
            opacity: cma.pressed ? 0.12 : cma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 100 } }
        }
        Text {
            id: txt
            anchors.centerIn: parent
            text: c.label
            color: c.tonal ? c.palette.onSecondaryContainer : c.palette.primary
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

    // ---- Pill text field with placeholder + focus ring -------------------
    component Field: Rectangle {
        id: f
        required property var palette
        property string placeholder: ""
        property bool digits: false
        property int align: TextInput.AlignLeft
        property alias text: input.text
        signal accepted()
        signal escaped()

        function clear() { input.text = ""; }
        function focusInput() { input.forceActiveFocus(); }

        implicitHeight: 40
        radius: height / 2
        color: Qt.rgba(f.palette.primary.r, f.palette.primary.g, f.palette.primary.b, 0.10)
        border.width: 1.5
        border.color: input.activeFocus
            ? Qt.rgba(f.palette.primary.r, f.palette.primary.g, f.palette.primary.b, 0.70)
            : Qt.rgba(f.palette.primary.r, f.palette.primary.g, f.palette.primary.b, 0.0)
        Behavior on border.color { ColorAnimation { duration: 140 } }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onPressed: input.forceActiveFocus()
        }

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            verticalAlignment: TextInput.AlignVCenter
            horizontalAlignment: f.align
            color: f.palette.primary
            selectionColor: f.palette.primary
            selectedTextColor: f.palette.onPrimary
            font.pixelSize: 13
            clip: true
            selectByMouse: true
            maximumLength: f.digits ? 6 : 24
            inputMethodHints: f.digits ? Qt.ImhDigitsOnly : Qt.ImhNone
            validator: RegularExpressionValidator {
                regularExpression: f.digits ? /^[0-9]*$/ : /^.*$/
            }
            onAccepted: f.accepted()
            Keys.onEscapePressed: f.escaped()

            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: f.align
                visible: input.text.length === 0
                text: f.placeholder
                color: Qt.rgba(f.palette.primary.r, f.palette.primary.g, f.palette.primary.b, 0.45)
                font.pixelSize: 13
                elide: Text.ElideRight
            }
        }
    }

    // ---- Counter card: [-]  (progress ring)  [+], label + delete on top --
    component CounterCard: Rectangle {
        id: cc
        required property var palette
        property var entry   // { id, label, initial, remaining } or null
        signal decrement()
        signal increment()
        signal remove()
        signal reset()

        readonly property real frac: (entry && entry.initial > 0) ? entry.remaining / entry.initial : 0
        readonly property bool depleted: entry ? entry.remaining <= 0 : false

        radius: 18
        color: Qt.rgba(palette.primary.r, palette.primary.g, palette.primary.b, hoverH.hovered ? 0.13 : 0.08)
        border.width: 1
        border.color: Qt.rgba(palette.primary.r, palette.primary.g, palette.primary.b, hoverH.hovered ? 0.30 : 0.10)
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        HoverHandler { id: hoverH }

        // top row: label (left) + delete (right) — label stops before the button
        IconBtn {
            id: trashBtn
            palette: cc.palette
            width: 24; height: 24
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 6
            anchors.rightMargin: 6
            kind: "text"
            glyph: "trash"
            glyphSize: 14
            onClicked: cc.remove()
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: trashBtn.left
            anchors.rightMargin: 4
            anchors.verticalCenter: trashBtn.verticalCenter
            text: cc.entry ? cc.entry.label : ""
            color: cc.palette.primary
            font.pixelSize: 11
            font.weight: Font.Medium
            elide: Text.ElideRight
        }

        // bottom row: [-] ring [+]
        Item {
            id: ring
            width: 54; height: 54
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12

            property real sweep: cc.frac * 360
            Behavior on sweep { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            Shape {
                anchors.fill: parent
                layer.enabled: true
                layer.samples: 4
                ShapePath {
                    strokeWidth: 5
                    strokeColor: Qt.rgba(cc.palette.primary.r, cc.palette.primary.g, cc.palette.primary.b, 0.20)
                    fillColor: "transparent"
                    PathAngleArc { centerX: 27; centerY: 27; radiusX: 24.5; radiusY: 24.5; startAngle: -90; sweepAngle: 360 }
                }
                ShapePath {
                    strokeWidth: 5
                    strokeColor: ring.sweep > 0.5 ? cc.palette.primary : "transparent"
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 27; centerY: 27; radiusX: 24.5; radiusY: 24.5; startAngle: -90; sweepAngle: ring.sweep }
                }
            }
            Text {
                anchors.centerIn: parent
                width: 36; height: 24
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: cc.entry ? String(cc.entry.remaining) : ""
                color: cc.palette.primary
                opacity: cc.depleted ? 0.5 : 1
                font.pixelSize: 16
                font.bold: true
                fontSizeMode: Text.Fit
                minimumPixelSize: 8
            }
            MouseArea {
                anchors.fill: parent
                onDoubleClicked: cc.reset()
            }
        }
        IconBtn {
            palette: cc.palette
            width: 28; height: 28
            anchors.right: ring.left
            anchors.rightMargin: 6
            anchors.verticalCenter: ring.verticalCenter
            kind: "tonal"
            glyph: "minus"
            glyphSize: 14
            enabled: !cc.depleted
            onClicked: cc.decrement()
        }
        IconBtn {
            palette: cc.palette
            width: 28; height: 28
            anchors.left: ring.right
            anchors.leftMargin: 6
            anchors.verticalCenter: ring.verticalCenter
            kind: "tonal"
            glyph: "plus"
            glyphSize: 14
            enabled: cc.entry ? cc.entry.remaining < cc.entry.initial : false
            onClicked: cc.increment()
        }
    }

    component ChronoWidget: PanelWindow {
        id: root

        // Bottom (not Background): Hyprland does not hand keyboard focus to
        // Background-layer surfaces, so typing in the counter fields needs
        // Bottom or above. Bottom still sits below normal windows.
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "chrono-widget"

        // Full-screen, transparent, click-through everywhere except the card.
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        mask: Region { item: frame }

        // ---- settings (plain in-memory object; saved to disk on demand) ----
        QtObject {
            id: mem
            property real posX: 60
            property real posY: 60
            property int mode: 0            // 0 = stopwatch, 1 = timer, 2 = counters
            property bool pinned: false
            property int timerDurationMs: 5 * 60 * 1000
        }

        // ---- paths -----------------------------------------------------------
        readonly property string stateDir:
            Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
        readonly property string schemePath: stateDir + "/caelestia/scheme.json"
        readonly property string dataDir: stateDir + "/chrono-widget"
        readonly property string countersPath: dataDir + "/counters.json"
        readonly property string settingsPath: dataDir + "/settings.json"

        Process {
            command: ["mkdir", "-p", root.dataDir]
            running: true
        }

        FileView {
            id: settingsStore
            path: root.settingsPath
            watchChanges: false
            onLoaded: {
                try {
                    var s = JSON.parse(text());
                    if (typeof s.x === "number") mem.posX = s.x;
                    if (typeof s.y === "number") mem.posY = s.y;
                    if (typeof s.mode === "number" && s.mode >= 0 && s.mode <= 2) mem.mode = Math.floor(s.mode);
                    if (typeof s.pinned === "boolean") mem.pinned = s.pinned;
                    if (typeof s.timerMs === "number" && s.timerMs >= 0) mem.timerDurationMs = s.timerMs;
                    root.tmRemainingMs = mem.timerDurationMs;
                } catch (e) {
                    console.warn("[chrono-widget] invalid settings.json:", e);
                }
            }
            onLoadFailed: (error) => { /* first run: keep defaults */ }
        }

        FileView {
            id: counterStore
            path: root.countersPath
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
            onLoadFailed: (error) => { root.counters = []; }
        }

        function saveSettings() {
            settingsStore.setText(JSON.stringify({
                x: mem.posX, y: mem.posY, mode: mem.mode,
                pinned: mem.pinned, timerMs: mem.timerDurationMs
            }));
        }
        Timer { id: saveTimer; interval: 400; onTriggered: root.saveSettings() }
        function scheduleSave() { saveTimer.restart(); }

        // ---- theme -------------------------------------------------------------
        QtObject {
            id: pal
            property var sch: ({})

            function c(role, fallback) {
                var v = sch[role];
                if (v === undefined || v === null || v === "") return fallback;
                return v.toString().charAt(0) === "#" ? v : ("#" + v);
            }
            function lum(col) { return 0.299 * col.r + 0.587 * col.g + 0.114 * col.b; }

            property color background: c("background", "#1b1d24")
            property color surface: c("surfaceContainer", c("surface", "#232530"))
            property color surfaceHigh: c("surfaceContainerHigh", c("surfaceVariant", "#2b2e39"))
            property color outline: c("outline", "#8b8d98")
            property color secondary: c("secondary", "#bcc7dc")
            property color secondaryContainer: c("secondaryContainer", "#3d4759")
            property color rawPrimary: c("primary", "#a6c8ff")
            property color error: c("error", "#ffb4ab")

            readonly property bool dark: lum(surface) < 0.5

            // keep the scheme hue, but guarantee contrast against the card
            property color primary: dark
                ? (lum(rawPrimary) >= 0.55 ? rawPrimary : Qt.lighter(rawPrimary, 1.0 + (0.55 - lum(rawPrimary)) * 3.5))
                : (lum(rawPrimary) <= 0.4 ? rawPrimary : Qt.darker(rawPrimary, 1.0 + (lum(rawPrimary) - 0.4) * 3.5))

            property color onPrimary: lum(primary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondary: lum(secondary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondaryContainer: lum(secondaryContainer) > 0.5 ? "#101015" : "#f4f4fa"
            property color onSurface: primary
            property color onSurfaceVariant: Qt.rgba(primary.r, primary.g, primary.b, 0.75)
            property color muted: Qt.rgba(primary.r, primary.g, primary.b, 0.60)
        }

        FileView {
            id: schemeFile
            path: root.schemePath
            watchChanges: true
            onFileChanged: reload()
            onLoaded: {
                try {
                    const data = JSON.parse(text());
                    pal.sch = (data && data.colours) ? data.colours : (data || {});
                } catch (e) {
                    console.warn("[chrono-widget] could not parse scheme.json:", e);
                }
            }
            onLoadFailed: (error) => {
                console.warn("[chrono-widget] could not read", root.schemePath, error);
            }
        }

        // ---- expand / collapse -------------------------------------------------
        property bool running: false
        property bool manualOpen: false
        property bool expanded: manualOpen || mem.pinned

        // ---- stopwatch state ---------------------------------------------------
        property real swStartedAt: 0
        property real swAccumMs: 0
        property real swElapsedMs: 0
        property var laps: []
        readonly property var lapItems: {
            var out = [];
            for (var i = laps.length - 1; i >= 0; i--)
                out.push({ n: i + 1, total: laps[i], delta: laps[i] - (i > 0 ? laps[i - 1] : 0) });
            return out;
        }

        // ---- timer state -------------------------------------------------------
        property real tmEndAt: 0
        property real tmRemainingMs: mem.timerDurationMs
        property bool tmFinished: false
        property real blink: 1
        SequentialAnimation on blink {
            running: root.tmFinished && mem.mode === 1
            loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 550; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 550; easing.type: Easing.InOutSine }
        }

        // ---- counters ----------------------------------------------------------
        property var counters: []
        property int counterPage: 0
        readonly property int pageCount: Math.max(1, Math.ceil(counters.length / 4))
        onCountersChanged: {
            var pages = Math.max(1, Math.ceil(counters.length / 4));
            counterPage = Math.max(0, Math.min(counterPage, pages - 1));
        }

        function saveCounters() { counterStore.setText(JSON.stringify(root.counters)); }

        function addCounter(label, amount) {
            label = (label || "").trim();
            amount = Math.max(1, Math.floor(Number(amount) || 0));
            if (!label) label = "Counter " + (root.counters.length + 1);
            var list = root.counters.slice();
            list.push({ id: Date.now() + Math.random(), label: label, initial: amount, remaining: amount });
            root.counters = list;
            root.counterPage = Math.ceil(list.length / 4) - 1;   // jump to the new card
            saveCounters();
        }

        function changeCounter(index, delta) {
            if (index < 0 || index >= root.counters.length) return;
            var list = root.counters.slice();
            var o = list[index];
            list[index] = {
                id: o.id, label: o.label, initial: o.initial,
                remaining: Math.max(0, Math.min(o.initial, o.remaining + delta))
            };
            root.counters = list;
            saveCounters();
        }

        function resetCounter(index) {
            if (index < 0 || index >= root.counters.length) return;
            var list = root.counters.slice();
            var o = list[index];
            list[index] = { id: o.id, label: o.label, initial: o.initial, remaining: o.initial };
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

        function submitCounter() {
            var amt = parseInt(amountField.text);
            if (!(amt > 0)) amt = 10;
            addCounter(labelField.text, amt);
            labelField.clear();
            labelField.focusInput();
        }

        // ---- clock -------------------------------------------------------------
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
                        Quickshell.execDetached(["notify-send", "-a", "Chrono", "Timer finished",
                                                 root.fmt(mem.timerDurationMs, mem.timerDurationMs >= 3600000).split(".")[0]]);
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
                    root.swAccumMs += Date.now() - root.swStartedAt;
                    root.swElapsedMs = root.swAccumMs;
                    root.running = false;
                } else {
                    root.swStartedAt = Date.now();
                    root.running = true;
                }
            } else {
                if (root.running) {
                    root.tmRemainingMs = Math.max(0, root.tmEndAt - Date.now());
                    root.running = false;
                } else {
                    if (mem.timerDurationMs <= 0) return;
                    if (root.tmRemainingMs <= 0) root.tmRemainingMs = mem.timerDurationMs;  // restart after finish
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

        // Changes the timer length; keeps whatever progress a paused timer has.
        function adjustTimer(deltaMs) {
            if (mem.mode !== 1 || root.running) return;
            var oldDur = mem.timerDurationMs;
            var newDur = Math.max(0, Math.min(99 * 3600000, oldDur + deltaMs));
            var applied = newDur - oldDur;
            mem.timerDurationMs = newDur;
            root.tmRemainingMs = Math.max(0, Math.min(newDur, root.tmRemainingMs + applied));
            root.tmFinished = false;
            scheduleSave();
        }

        function cycleMode() {
            if (root.running) return;
            mem.mode = (mem.mode + 1) % 3;
            card.forceActiveFocus();
            scheduleSave();
        }

        // Absolute position with edge snapping, in window coordinates.
        function setPosition(l, t) {
            var gap = frame.gap, snap = frame.snap;
            var maxL = root.width - frame.width - gap;
            var maxT = root.height - frame.height - gap;
            if (Math.abs(l - gap) < snap) l = gap;
            if (Math.abs(l - maxL) < snap) l = maxL;
            if (Math.abs(t - gap) < snap) t = gap;
            if (Math.abs(t - maxT) < snap) t = maxT;
            mem.posX = Math.max(gap, Math.min(maxL, l));
            mem.posY = Math.max(gap, Math.min(maxT, t));
        }

        // ============================ UI ====================================
        Item {
            id: frame
            readonly property int gap: 8      // min distance to screen edges
            readonly property int snap: 14    // edge snap distance
            readonly property int pad: 20     // card inner padding

            width: root.expanded ? 340 : 56
            height: root.expanded ? content.implicitHeight + pad * 2 : 56
            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

            // Displayed position is clamped to the screen, so expanding near an
            // edge slides the card inwards (and back again when collapsed)
            // without touching the saved position.
            x: root.width > 0 ? Math.max(gap, Math.min(mem.posX, root.width - width - gap)) : mem.posX
            y: root.height > 0 ? Math.max(gap, Math.min(mem.posY, root.height - height - gap)) : mem.posY

            // soft static shadow: a few translucent rects, no shader / texture
            Repeater {
                model: 5
                delegate: Rectangle {
                    required property int index
                    anchors.fill: parent
                    anchors.margins: -(index + 1) * 3
                    anchors.topMargin: -(index + 1) * 3 + 5
                    anchors.bottomMargin: -(index + 1) * 3 - 5
                    radius: card.radius + (index + 1) * 3
                    color: Qt.rgba(0, 0, 0, 0.055)
                }
            }

            Rectangle {
                id: card
                anchors.fill: parent
                radius: root.expanded ? 26 : height / 2
                color: Qt.rgba(pal.surface.r, pal.surface.g, pal.surface.b, 0.97)
                border.width: 1
                border.color: Qt.rgba(pal.primary.r, pal.primary.g, pal.primary.b, 0.10)
                Behavior on radius { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

                // clicking empty card space drops keyboard focus from text fields
                MouseArea {
                    anchors.fill: parent
                    onPressed: card.forceActiveFocus()
                }

                // faint top-light / bottom-shade sheen
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
                Item {
                    anchors.fill: parent
                    opacity: root.expanded ? 0 : 1
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: 140 } }

                    Rectangle {
                        anchors.fill: parent
                        radius: card.radius
                        color: pal.primary
                        opacity: collapsedArea.pressed ? 0.10 : collapsedArea.containsMouse ? 0.08 : 0
                        Behavior on opacity { NumberAnimation { duration: 100 } }
                    }
                    Glyph {
                        anchors.centerIn: parent
                        name: mem.mode === 0 ? "stopwatch" : (mem.mode === 1 ? "hourglass" : "counter")
                        color: pal.primary
                        size: 24
                    }
                    // running indicator
                    Rectangle {
                        x: 38; y: 9
                        width: 9; height: 9; radius: 5
                        color: root.tmFinished ? pal.error : pal.primary
                        border.width: 2
                        border.color: pal.surface
                        visible: root.running || root.tmFinished
                        opacity: root.tmFinished ? root.blink : 1
                        SequentialAnimation on opacity {
                            running: root.running
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }

                    MouseArea {
                        id: collapsedArea
                        anchors.fill: parent
                        enabled: !root.expanded
                        hoverEnabled: true
                        cursorShape: (pressed && travel > 4) ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                        property real pressSX: 0
                        property real pressSY: 0
                        property real startX: 0
                        property real startY: 0
                        property real travel: 0

                        onPressed: (mouse) => {
                            var p = mapToItem(null, mouse.x, mouse.y);   // window coords: stable while dragging
                            pressSX = p.x; pressSY = p.y;
                            startX = frame.x; startY = frame.y;
                            travel = 0;
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed) return;
                            var p = mapToItem(null, mouse.x, mouse.y);
                            var dx = p.x - pressSX, dy = p.y - pressSY;
                            travel = Math.max(travel, Math.abs(dx) + Math.abs(dy));
                            if (travel > 4) root.setPosition(startX + dx, startY + dy);
                        }
                        onReleased: {
                            if (travel > 4) root.scheduleSave();
                            else root.manualOpen = true;
                        }
                    }
                }

                // ---------------- expanded panel ----------------
                Item {
                    id: panel
                    anchors.fill: parent
                    clip: true
                    opacity: root.expanded ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity {
                        SequentialAnimation {
                            PauseAnimation { duration: root.expanded ? 90 : 0 }
                            NumberAnimation { duration: root.expanded ? 160 : 80 }
                        }
                    }

                    Column {
                        id: content
                        x: frame.pad
                        y: frame.pad
                        width: 300
                        spacing: 16

                        // ---- header (also the drag handle) ----
                        Item {
                            width: parent.width
                            height: 36

                            MouseArea {
                                id: headerDrag
                                anchors.fill: parent
                                enabled: !mem.pinned
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                                property real pressSX: 0
                                property real pressSY: 0
                                property real startX: 0
                                property real startY: 0

                                onPressed: (mouse) => {
                                    card.forceActiveFocus();
                                    var p = mapToItem(null, mouse.x, mouse.y);
                                    pressSX = p.x; pressSY = p.y;
                                    startX = frame.x; startY = frame.y;
                                }
                                onPositionChanged: (mouse) => {
                                    if (!pressed) return;
                                    var p = mapToItem(null, mouse.x, mouse.y);
                                    root.setPosition(startX + (p.x - pressSX), startY + (p.y - pressSY));
                                }
                                onReleased: root.scheduleSave()
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10
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
                                    onClicked: { mem.pinned = !mem.pinned; root.scheduleSave(); }
                                }
                                IconBtn {
                                    palette: pal
                                    width: 32; height: 32
                                    kind: "text"
                                    glyph: "swap"; glyphSize: 20
                                    enabled: !root.running
                                    onClicked: root.cycleMode()
                                }
                                IconBtn {
                                    palette: pal
                                    width: 32; height: 32
                                    kind: "text"
                                    glyph: "chevron"; glyphSize: 20
                                    onClicked: {
                                        card.forceActiveFocus();
                                        root.manualOpen = false;
                                        mem.pinned = false;
                                        root.scheduleSave();
                                    }
                                }
                            }
                        }

                        // ---- body: stopwatch / timer / counters ----
                        Item {
                            id: body
                            width: parent.width
                            height: mem.mode === 2 ? 282 : 196

                            // --- ring + disc (stopwatch / timer) ---
                            Item {
                                id: dial
                                anchors.centerIn: parent
                                width: 188; height: 188
                                visible: mem.mode !== 2

                                Shape {
                                    id: ring
                                    anchors.fill: parent
                                    layer.enabled: true
                                    layer.samples: 4
                                    // stopwatch: sweeps once per minute; timer: shows time remaining
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
                                        strokeColor: ring.frac * 360 > 0.5
                                            ? (root.tmFinished && mem.mode === 1 ? pal.error : pal.primary)
                                            : "transparent"
                                        fillColor: "transparent"
                                        capStyle: ShapePath.RoundCap
                                        PathAngleArc {
                                            centerX: 94; centerY: 94
                                            radiusX: 91; radiusY: 91
                                            startAngle: -90
                                            sweepAngle: 360 * ring.frac
                                        }
                                    }
                                }

                                Rectangle {
                                    id: disc
                                    anchors.centerIn: parent
                                    width: 168; height: 168; radius: 84
                                    color: pal.surfaceHigh

                                    readonly property bool editing: mem.mode === 1 && !root.running

                                    Text {
                                        id: timeText
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.verticalCenterOffset: disc.editing ? -22 : 0
                                        Behavior on anchors.verticalCenterOffset {
                                            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                                        }
                                        width: 122; height: 38
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        text: mem.mode === 0
                                            ? root.fmt(root.swElapsedMs, root.swElapsedMs >= 3600000)
                                            : root.fmt(root.tmRemainingMs, mem.timerDurationMs >= 3600000)
                                        color: (root.tmFinished && mem.mode === 1) ? pal.error : pal.primary
                                        opacity: (root.tmFinished && mem.mode === 1) ? root.blink : 1
                                        font.pixelSize: 30
                                        font.bold: true
                                        font.family: "monospace"
                                        fontSizeMode: Text.Fit
                                        minimumPixelSize: 14
                                    }

                                    // timer step chips: 2x2, fade out while running
                                    Grid {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: 100
                                        columns: 2
                                        spacing: 4
                                        opacity: disc.editing ? 1 : 0
                                        visible: opacity > 0.01 && mem.mode === 1
                                        Behavior on opacity { NumberAnimation { duration: 160 } }

                                        Chip { palette: pal; width: 44; height: 22; label: "+1m"; onClicked: root.adjustTimer(60000) }
                                        Chip { palette: pal; width: 44; height: 22; label: "+10s"; onClicked: root.adjustTimer(10000) }
                                        Chip { palette: pal; width: 44; height: 22; label: "−1m"; onClicked: root.adjustTimer(-60000) }
                                        Chip { palette: pal; width: 44; height: 22; label: "−10s"; onClicked: root.adjustTimer(-10000) }
                                    }
                                }
                            }

                            // --- counters ---
                            Column {
                                anchors.fill: parent
                                spacing: 10
                                visible: mem.mode === 2

                                // add row: label | amount | add
                                Row {
                                    width: parent.width
                                    height: 40
                                    spacing: 8

                                    Field {
                                        id: labelField
                                        palette: pal
                                        width: parent.width - 56 - 40 - 16
                                        height: 40
                                        placeholder: "Counter name"
                                        onAccepted: root.submitCounter()
                                        onEscaped: card.forceActiveFocus()
                                    }
                                    Field {
                                        id: amountField
                                        palette: pal
                                        width: 56
                                        height: 40
                                        digits: true
                                        align: TextInput.AlignHCenter
                                        placeholder: "10"
                                        text: "10"
                                        onAccepted: root.submitCounter()
                                        onEscaped: card.forceActiveFocus()
                                    }
                                    IconBtn {
                                        palette: pal
                                        width: 40; height: 40
                                        kind: "filled"
                                        glyph: "plus"
                                        glyphSize: 20
                                        onClicked: root.submitCounter()
                                    }
                                }

                                // 2x2 page of counter cards
                                Item {
                                    id: gridArea
                                    width: parent.width
                                    height: 214

                                    WheelHandler {
                                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                        onWheel: (event) => {
                                            if (event.angleDelta.y < 0)
                                                root.counterPage = Math.min(root.pageCount - 1, root.counterPage + 1);
                                            else if (event.angleDelta.y > 0)
                                                root.counterPage = Math.max(0, root.counterPage - 1);
                                        }
                                    }

                                    Grid {
                                        anchors.fill: parent
                                        columns: 2
                                        spacing: 8

                                        Repeater {
                                            model: 4
                                            delegate: Item {
                                                id: slot
                                                required property int index
                                                width: (gridArea.width - 8) / 2
                                                height: (gridArea.height - 8) / 2

                                                readonly property int globalIndex: root.counterPage * 4 + slot.index
                                                readonly property var entry: root.counters[slot.globalIndex] || null

                                                Rectangle {
                                                    anchors.fill: parent
                                                    radius: 18
                                                    visible: slot.entry === null
                                                    color: Qt.rgba(pal.primary.r, pal.primary.g, pal.primary.b, 0.035)
                                                }
                                                CounterCard {
                                                    anchors.fill: parent
                                                    visible: slot.entry !== null
                                                    palette: pal
                                                    entry: slot.entry
                                                    onDecrement: root.changeCounter(slot.globalIndex, -1)
                                                    onIncrement: root.changeCounter(slot.globalIndex, 1)
                                                    onReset: root.resetCounter(slot.globalIndex)
                                                    onRemove: root.deleteCounter(slot.globalIndex)
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: root.counters.length === 0
                                        horizontalAlignment: Text.AlignHCenter
                                        lineHeight: 1.3
                                        text: "No counters yet\nName it, set a number, press +"
                                        color: pal.muted
                                        font.pixelSize: 12
                                    }
                                }

                                // page dots (space is always reserved so nothing jumps)
                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    height: 8
                                    spacing: 6
                                    opacity: root.pageCount > 1 ? 1 : 0

                                    Repeater {
                                        model: root.pageCount
                                        delegate: Rectangle {
                                            required property int index
                                            readonly property bool current: index === root.counterPage
                                            width: current ? 16 : 6
                                            height: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            radius: 3
                                            color: pal.primary
                                            opacity: current ? 0.9 : 0.25
                                            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                            Behavior on opacity { NumberAnimation { duration: 160 } }
                                            MouseArea {
                                                anchors.fill: parent
                                                anchors.margins: -5
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.counterPage = index
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- controls: tonal | filled (stretches) | tonal ----
                        Row {
                            width: parent.width
                            height: 56
                            spacing: 8
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
                                width: parent.width - 56 * 2 - 8 * 2; height: 56
                                kind: "filled"
                                checked: root.running
                                glyph: root.running ? "pause" : "play"
                                enabled: mem.mode === 0 || mem.timerDurationMs > 0
                                onClicked: root.toggleStart()
                            }
                            IconBtn {
                                palette: pal
                                width: 56; height: 56
                                kind: "tonal"
                                glyph: "flag"
                                enabled: mem.mode === 0 && root.running
                                onClicked: root.lap()
                            }
                        }

                        // ---- laps ----
                        Rectangle {
                            width: parent.width
                            height: 12 + 24 + 4 + 66 + 12
                            radius: 18
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
                                        anchors.left: parent.left
                                        anchors.leftMargin: 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Laps"
                                        color: pal.primary
                                        font.pixelSize: 12
                                        font.weight: Font.Medium
                                    }
                                    Chip {
                                        palette: pal
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
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
                                    model: root.lapItems
                                    delegate: Item {
                                        required property var modelData
                                        width: ListView.view.width
                                        height: 22
                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "#" + modelData.n
                                            color: pal.primary
                                            font.pixelSize: 12
                                        }
                                        Text {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "+" + root.fmt(modelData.delta, false)
                                            color: pal.muted
                                            font.pixelSize: 11
                                            font.family: "monospace"
                                        }
                                        Text {
                                            anchors.right: parent.right
                                            anchors.rightMargin: 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.fmt(modelData.total, false)
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
        }
    }

    ChronoWidget {}
}
