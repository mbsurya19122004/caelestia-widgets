// Glass Clock — standalone Quickshell widget
// Run:  qs -c glassclock      (file at ~/.config/quickshell/glassclock/shell.qml)
// Colours follow Caelestia's ~/.local/state/caelestia/scheme.json and update live.
// Drag to move it. Let go near one of 9 spots (corners, edge middles, centre) and it snaps there;
// let go anywhere else and it stays exactly where you dropped it.
// Double-click toggles the background. Position/background are saved to
// $XDG_STATE_HOME/glassclock/pos.json.

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ───────────────────────── Config (tweak freely) ─────────────────────────
    property bool   use24h:     false
    property string fontFamily: "Rubik"   // rounded + sturdy; also nice: "Outfit", "Sora", "Lexend", "Space Grotesk"
    property int    digitSize:  92
    property int    digitWeight: Font.DemiBold   // Normal < Medium < DemiBold < Bold < ExtraBold
    // gap kept between the widget and each screen edge when snapped
    property int    insetLeft:   12   // leaves room for Caelestia's left bar
    property int    insetRight:  12
    property int    insetTop:    12
    property int    insetBottom: 12
    property int    cardW:      440
    property int    cardH:      200
    property bool   glow:       true

    // background card (double-click the widget to toggle at runtime)
    property bool   showBackground: false
    property real   cardAlpha:      0.35   // glass opacity
    property int    cardRadius:     90

    // how close (px) you must drop it to a snap spot for it to snap; bigger = stickier
    property int    snapDistance:   100

    // ───────────────────────── Paths ─────────────────────────
    readonly property string home:      Quickshell.env("HOME")
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
    readonly property string schemePath: stateHome + "/caelestia/scheme.json"
    readonly property string stateDir:   stateHome + "/glassclock"

    // ───────────────────────── Scheme ─────────────────────────
    property var cols: ({})

    function pick(name, fallback) {
        var h = cols[name] || fallback;
        return Qt.color(h.charAt(0) === "#" ? h : "#" + h);
    }
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
    }
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }

    // Built-in dark fallback (used until/unless scheme.json is readable)
    property color cSurface:   pick("surfaceContainer", "1e1c2a")
    property color cPrimary:   pick("primary",          "cdbdff")
    property color cTertiary:  pick("tertiary",         "f0b6e0")
    property color cOnSurface: pick("onSurface",        "e6e0f0")
    property color cOnVariant: pick("onSurfaceVariant", "a9a3b8")
    property color cOutline:   pick("outline",          "8a8499")

    Behavior on cSurface   { ColorAnimation { duration: 450 } }
    Behavior on cPrimary   { ColorAnimation { duration: 450 } }
    Behavior on cTertiary  { ColorAnimation { duration: 450 } }
    Behavior on cOnSurface { ColorAnimation { duration: 450 } }
    Behavior on cOnVariant { ColorAnimation { duration: 450 } }
    Behavior on cOutline   { ColorAnimation { duration: 450 } }

    function applyScheme(text) {
        try {
            var j = JSON.parse(text);
            root.cols = j.colours || j.colors || {};
        } catch (e) {
            console.warn("glassclock: could not parse scheme.json:", e);
        }
    }

    FileView {
        path: root.schemePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applyScheme(text())
    }

    // ───────────────────────── Position persistence ─────────────────────────
    // 9 snap slots:  0 1 2   (top-left, top-centre, top-right)
    //                3 4 5   (middle-left, centre, middle-right)
    //                6 7 8   (bottom-left, bottom-centre, bottom-right)
    property int  slot: 4        // -1 = free placement (uses freeX / freeY)
    property real freeX: 0
    property real freeY: 0
    property bool bgTouched: false   // true once the background was toggled by double-click
    property bool dragging: false
    property real curX: 0   // live position while dragging / snapping
    property real curY: 0

    readonly property real screenW: win.screen ? win.screen.width  : 1920
    readonly property real screenH: win.screen ? win.screen.height : 1080

    function slotX(i) {
        var c = i % 3;
        if (c === 0) return insetLeft;
        if (c === 2) return screenW - cardW - insetRight;
        return Math.round((screenW - cardW) / 2);
    }
    function slotY(i) {
        var r = Math.floor(i / 3);
        if (r === 0) return insetTop;
        if (r === 2) return screenH - cardH - insetBottom;
        return Math.round((screenH - cardH) / 2);
    }
    // nearest snap spot to a top-left position, with its distance in px
    function nearest(x, y) {
        var best = 4, bestD = Infinity;
        for (var i = 0; i < 9; i++) {
            var dx = x - slotX(i), dy = y - slotY(i);
            var d = Math.sqrt(dx * dx + dy * dy);
            if (d < bestD) { bestD = d; best = i; }
        }
        return { i: best, d: bestD };
    }
    readonly property real targetX: slot >= 0 ? slotX(slot) : Math.max(0, Math.min(screenW - cardW, freeX))
    readonly property real targetY: slot >= 0 ? slotY(slot) : Math.max(0, Math.min(screenH - cardH, freeY))

    function savePos() {
        posFile.setText(JSON.stringify({
            slot: slot,
            x: Math.round(freeX),
            y: Math.round(freeY),
            bg: bgTouched ? showBackground : undefined
        }));
    }

    ParallelAnimation {
        id: snapAnim
        NumberAnimation { target: root; property: "curX"; to: root.targetX; duration: 260; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "curY"; to: root.targetY; duration: 260; easing.type: Easing.OutCubic }
    }

    FileView {
        id: posFile
        path: root.stateDir + "/pos.json"
        onLoaded: {
            try {
                var p = JSON.parse(text());
                if (p.slot >= 0 && p.slot <= 8) {
                    root.slot = p.slot;
                } else if (p.x !== undefined && p.y !== undefined) {
                    root.slot = -1; root.freeX = p.x; root.freeY = p.y;
                }
                if (p.bg !== undefined) { root.showBackground = p.bg; root.bgTouched = true; }
            } catch (e) {}
        }
    }

    Process {
        command: ["mkdir", "-p", root.stateDir]
        running: true
        onExited: posFile.reload()
    }

    // ───────────────────────── Clock ─────────────────────────
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    readonly property var now: clock.date
    function pad(n) { return (n < 10 ? "0" : "") + n; }
    readonly property string hoursStr: {
        var h = now.getHours();
        return pad(use24h ? h : (h % 12 || 12));
    }
    readonly property string minutesStr: pad(now.getMinutes())
    readonly property string dateStr: Qt.formatDateTime(now, "ddd, dd MMM yyyy").toUpperCase()

    // ───────────────────────── Window ─────────────────────────
    PanelWindow {
        id: win

        WlrLayershell.namespace: "glassclock"   // for Hyprland layerrules (blur)
        WlrLayershell.layer: WlrLayer.Bottom
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors { top: true; left: true }
        margins {
            left: Math.round((root.dragging || snapAnim.running) ? root.curX : root.targetX)
            top:  Math.round((root.dragging || snapAnim.running) ? root.curY : root.targetY)
        }
        implicitWidth: root.cardW
        implicitHeight: root.cardH

        // ── Glass card ──
        Rectangle {
            id: card
            anchors.fill: parent
            color: "transparent"

            // ── Optional background card ──
            Rectangle {
                id: bg
                anchors.fill: parent
                radius: root.cardRadius
                color: "transparent"
                opacity: root.showBackground ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                border.width: 1
                border.color: root.alpha(root.mix(root.cOutline, root.cPrimary, 0.55), 0.55)

                gradient: Gradient {
                    GradientStop { position: 0.0; color: root.alpha(root.cSurface, root.cardAlpha * 0.9) }
                    GradientStop { position: 1.0; color: root.alpha(root.mix(root.cSurface, root.cPrimary, 0.16), root.cardAlpha) }
                }

                // soft top-edge sheen
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: parent.radius - 1
                    color: "transparent"
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: root.alpha(root.cOnSurface, 0.07) }
                        GradientStop { position: 0.45; color: "transparent" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
            }

            // ── Time ──
            RowLayout {
                id: timeRow
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                spacing: 14
                visible: !root.glow   // when glow is on, MultiEffect draws this

                TextMetrics {
                    id: tm
                    font: hoursText.font
                    text: "00"
                }

                Text {
                    id: hoursText
                    Layout.preferredWidth: tm.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.hoursStr
                    color: root.mix(root.cPrimary, root.cOnSurface, 0.78)
                    font.family: root.fontFamily
                    font.weight: root.digitWeight
                    font.pixelSize: root.digitSize
                }

                // colon
                Item {
                    Layout.preferredWidth: 12
                    Layout.fillHeight: true
                    Column {
                        anchors.centerIn: parent
                        spacing: 30
                        Repeater {
                            model: 2
                            Rectangle {
                                width: 11; height: 11; radius: 6
                                color: root.mix(root.cPrimary, root.cOnSurface, 0.5)
                            }
                        }
                    }
                }

                Text {
                    id: minutesText
                    Layout.preferredWidth: tm.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.minutesStr
                    color: root.mix(root.cPrimary, root.cTertiary, 0.55)
                    font.family: root.fontFamily
                    font.weight: root.digitWeight
                    font.pixelSize: root.digitSize
                }

            }

            // soft glow behind the digits (source is hidden, effect draws source + shadow)
            MultiEffect {
                visible: root.glow
                source: timeRow
                anchors.fill: timeRow
                shadowEnabled: true
                shadowColor: root.cPrimary
                shadowBlur: 0.9
                shadowOpacity: 0.55
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }

            // ── Date ──
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 26
                text: root.dateStr
                color: root.cOnVariant
                font.family: root.fontFamily
                font.weight: Font.Medium
                font.pixelSize: 15
                font.letterSpacing: 5
            }

            // ── Drag to move ──
            MouseArea {
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor
                property real px: 0
                property real py: 0

                onPressed: (m) => {
                    px = m.x; py = m.y;
                    // continue from wherever the window currently is (even mid-snap)
                    root.curX = win.margins.left;
                    root.curY = win.margins.top;
                    snapAnim.stop();
                    root.dragging = true;
                }
                onPositionChanged: (m) => {
                    if (!pressed) return;
                    root.curX = Math.max(0, Math.min(root.screenW - root.cardW, root.curX + m.x - px));
                    root.curY = Math.max(0, Math.min(root.screenH - root.cardH, root.curY + m.y - py));
                }
                onReleased: {
                    var n = root.nearest(root.curX, root.curY);
                    if (n.d <= root.snapDistance) {
                        root.slot = n.i;                       // close enough: snap
                    } else {
                        root.slot = -1;                        // otherwise stay where dropped
                        root.freeX = root.curX;
                        root.freeY = root.curY;
                    }
                    snapAnim.restart();
                    root.dragging = false;
                    root.savePos();
                }
                onDoubleClicked: {
                    root.showBackground = !root.showBackground;
                    root.bgTouched = true;
                    root.savePos();
                }
                onCanceled: {
                    root.dragging = false;
                }
            }
        }
    }
}
