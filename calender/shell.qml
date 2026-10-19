// Calendar for Quickshell, themed live from the Caelestia scheme.
// Install:  ~/.config/quickshell/calendar/shell.qml
// Run:      qs -c calendar
// Toggle:   qs -c calendar ipc call calendar toggle

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ── settings ────────────────────────────────────────────────────────
    property int weekStart: 1                    // 0 = Sunday, 1 = Monday
    property bool use24h: true
    property int marginTop: 64                   // default spot (top right) until you drag it
    property int marginSide: 24
    property bool startVisible: Quickshell.env("CALENDAR_HIDDEN") !== "1"

    readonly property string sans: "Rubik"
    readonly property string mono: "CaskaydiaCove NF"
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property bool hasIcons: Qt.fontFamilies ? Qt.fontFamilies().indexOf(iconFont) >= 0 : true

    // ── paths ───────────────────────────────────────────────────────────
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
    readonly property string dataDir: stateHome + "/caelestia-calendar"
    readonly property string schemePath: stateHome + "/caelestia/scheme.json"

    // ── state ───────────────────────────────────────────────────────────
    property var now: new Date()
    property int viewYear: 2000
    property int viewMonth: 0
    property string selected: ""
    property real panelT: panelOpen ? 1 : 0
    Behavior on panelT {
        NumberAnimation {
            duration: root.panelOpen ? 240 : 220
            // open decelerates in; close eases out at both ends so the card doesn't drop or stop abruptly
            easing.type: root.panelOpen ? Easing.OutCubic : Easing.InOutCubic
        }
    }
    property bool panelOpen: false               // day panel (events + input) only shows after clicking a date
    property var events: ({})                    // { "YYYY-MM-DD": [{ id, text, tags[], time }] }
    property var fired: ({})
    property var queue: []
    property real posX: -1                       // -1 = default spot
    property real posY: 64
    property bool locked: false

    readonly property real screenW: win.screen ? win.screen.width : 1920
    readonly property real screenH: win.screen ? win.screen.height : 1080
    readonly property real effX: Math.max(0, Math.min(screenW - card.width, posX >= 0 ? posX : screenW - card.width - marginSide))
    // window is sized for the fully-open card and never resizes while animating
    // depends only on non-animated sizes, so the window never resizes mid-animation
    readonly property real fullH: col.implicitHeight + 48 + panelCol.implicitHeight + 12
    readonly property real effY: Math.max(0, Math.min(screenH - fullH, posY))

    readonly property string todayKey: keyOf(now)
    readonly property int gridOffset: (new Date(viewYear, viewMonth, 1).getDay() - weekStart + 7) % 7
    readonly property var selList: entriesFor(selected)

    Component.onCompleted: {
        goToday()
        focusCard()
    }

    // ── helpers ─────────────────────────────────────────────────────────
    function pad(n) { return n < 10 ? "0" + n : "" + n }

    function keyOf(d) {
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    }

    function dateFromKey(k) {
        if (!k) return new Date()
        var p = k.split("-")
        return new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2]))
    }

    function entriesFor(k) { return events[k] || [] }

    function tagColor(tag) {
        var h = 0
        for (var i = 0; i < tag.length; i++) h = (h * 31 + tag.charCodeAt(i)) >>> 0
        var a = theme.accents
        return a[h % a.length]
    }

    function fmtTime(t) {
        if (!t || use24h) return t || ""
        var p = t.split(":")
        var h = parseInt(p[0])
        var s = h >= 12 ? "pm" : "am"
        h = h % 12
        if (h === 0) h = 12
        return h + ":" + p[1] + s
    }

    // "Submit report #uni @18:30"  ->  text, tags, time
    function parseEntry(raw) {
        var tags = []
        var time = ""
        var text = raw.replace(/(^|\s)#([^\s#@]+)/g, function (m, sp, t) {
            t = t.toLowerCase()
            if (tags.indexOf(t) < 0) tags.push(t)
            return sp
        })
        text = text.replace(/(^|\s)@(\d{1,2})(?::(\d{2}))?\s?(am|pm)?(?=\s|$)/i, function (m, sp, h, mi, ap) {
            var hh = parseInt(h)
            var mm = mi ? parseInt(mi) : 0
            if (ap) {
                ap = ap.toLowerCase()
                if (ap === "pm" && hh < 12) hh += 12
                if (ap === "am" && hh === 12) hh = 0
            }
            if (hh > 23 || mm > 59) return m
            time = pad(hh) + ":" + pad(mm)
            return sp
        })
        text = text.replace(/\s+/g, " ").trim()
        return { text: text, tags: tags, time: time }
    }

    function save() {
        if (store.path !== "") store.setText(JSON.stringify(events, null, 2))
    }

    function savePos() {
        if (posStore.path !== "")
            posStore.setText(JSON.stringify({ x: Math.round(effX), y: Math.round(effY), locked: locked }, null, 2))
    }

    function addEntry(key, e) {
        var ev = JSON.parse(JSON.stringify(events))
        e.id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
        if (!ev[key]) ev[key] = []
        ev[key].push(e)
        ev[key].sort(function (a, b) { return (a.time || "").localeCompare(b.time || "") })
        events = ev
        save()
    }

    function removeEntry(key, id) {
        var ev = JSON.parse(JSON.stringify(events))
        if (!ev[key]) return
        ev[key] = ev[key].filter(function (e) { return e.id !== id })
        if (ev[key].length === 0) delete ev[key]
        events = ev
        save()
    }

    function submit(raw) {
        var e = parseEntry(raw)
        if (!e.text && e.tags.length === 0) return false
        addEntry(selected, e)
        return true
    }

    function shiftMonth(n) {
        var d = new Date(viewYear, viewMonth + n, 1)
        viewYear = d.getFullYear()
        viewMonth = d.getMonth()
        tip.shown = false
        if (tip.target) tipDelay.restart()
    }

    function goToday() {
        var n = new Date()
        now = n
        viewYear = n.getFullYear()
        viewMonth = n.getMonth()
        selected = keyOf(n)
        panelOpen = false
    }

    function focusCard() {
        if (panelOpen) input.forceActiveFocus()
        else card.forceActiveFocus()
    }

    function pick(d, key) {
        // clicking the already-open date again closes the panel
        panelOpen = !(panelOpen && selected === key)
        selected = key
        if (d.getMonth() !== viewMonth || d.getFullYear() !== viewYear) {
            viewYear = d.getFullYear()
            viewMonth = d.getMonth()
        }
        Qt.callLater(focusCard)
    }

    function hoverIn(cell) {
        tip.target = cell
        tipDelay.restart()
    }

    function hoverOut(cell) {
        if (tip.target !== cell) return
        tip.target = null
        tipDelay.stop()
        tip.shown = false
    }

    // reminders: entries with a time fire a desktop notification
    function checkReminders() {
        var n = new Date()
        var list = events[keyOf(n)] || []
        var hm = pad(n.getHours()) + ":" + pad(n.getMinutes())
        for (var i = 0; i < list.length; i++) {
            var e = list[i]
            if (e.time === hm && !fired[e.id]) {
                fired[e.id] = true
                notify(e)
            }
        }
    }

    function notify(e) {
        var tags = (e.tags || []).map(function (t) { return "#" + t }).join("  ")
        var body = fmtTime(e.time) + (tags ? "   " + tags : "")
        queue.push(["notify-send", "-a", "Calendar", "-i", "appointment-soon", e.text || "Reminder", body])
        pump()
    }

    function pump() {
        if (notifier.running || queue.length === 0) return
        notifier.command = queue.shift()
        notifier.running = true
    }

    // ── theme: follows ~/.local/state/caelestia/scheme.json ─────────────
    QtObject {
        id: theme

        property color surface: "#141318"
        property color surfaceContainer: "#201f25"
        property color surfaceContainerHigh: "#2b292f"
        property color m3onSurface: "#e6e0e9"
        property color m3onSurfaceVariant: "#cac4d0"
        property color outlineVariant: "#49454f"
        property color primary: "#cfbcff"
        property color m3onPrimary: "#381e72"
        property color primaryContainer: "#4f378a"
        property color m3onPrimaryContainer: "#eaddff"
        property color secondary: "#ccc2dc"
        property color tertiary: "#efb8c8"
        property color error: "#f2b8b5"
        property color extra1: "#a6e3a1"
        property color extra2: "#94e2d5"
        property color extra3: "#f9e2af"

        readonly property var accents: [primary, secondary, tertiary, extra1, extra2, extra3]

        Behavior on surface { ColorAnimation { duration: 300 } }
        Behavior on surfaceContainer { ColorAnimation { duration: 300 } }
        Behavior on surfaceContainerHigh { ColorAnimation { duration: 300 } }
        Behavior on m3onSurface { ColorAnimation { duration: 300 } }
        Behavior on m3onSurfaceVariant { ColorAnimation { duration: 300 } }
        Behavior on outlineVariant { ColorAnimation { duration: 300 } }
        Behavior on primary { ColorAnimation { duration: 300 } }
        Behavior on m3onPrimary { ColorAnimation { duration: 300 } }
        Behavior on primaryContainer { ColorAnimation { duration: 300 } }
        Behavior on m3onPrimaryContainer { ColorAnimation { duration: 300 } }
        Behavior on secondary { ColorAnimation { duration: 300 } }
        Behavior on tertiary { ColorAnimation { duration: 300 } }
        Behavior on error { ColorAnimation { duration: 300 } }

        function apply(raw) {
            var j
            try { j = JSON.parse(raw) } catch (e) { return }
            var s = (j && (j.colours || j.colors)) || {}

            function get(name, fallback) {
                var snake = name.replace(/[A-Z]/g, function (m) { return "_" + m.toLowerCase() })
                var v = s[name] !== undefined ? s[name] : s[snake]
                if (!v) return fallback
                v = String(v)
                return v.charAt(0) === "#" ? v : "#" + v
            }

            surface = get("surface", surface)
            surfaceContainer = get("surfaceContainer", surfaceContainer)
            surfaceContainerHigh = get("surfaceContainerHigh", surfaceContainerHigh)
            m3onSurface = get("onSurface", m3onSurface)
            m3onSurfaceVariant = get("onSurfaceVariant", m3onSurfaceVariant)
            outlineVariant = get("outlineVariant", outlineVariant)
            primary = get("primary", primary)
            m3onPrimary = get("onPrimary", m3onPrimary)
            primaryContainer = get("primaryContainer", primaryContainer)
            m3onPrimaryContainer = get("onPrimaryContainer", m3onPrimaryContainer)
            secondary = get("secondary", secondary)
            tertiary = get("tertiary", tertiary)
            error = get("error", error)
            extra1 = get("term2", extra1)
            extra2 = get("term6", extra2)
            extra3 = get("term3", extra3)
        }
    }

    FileView {
        id: schemeFile
        path: root.schemePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: theme.apply(text())
    }

    // ── storage ─────────────────────────────────────────────────────────
    FileView {
        id: store
        printErrors: false
        onLoaded: {
            try { root.events = JSON.parse(text()) || {} } catch (e) { root.events = {} }
        }
    }

    FileView {
        id: posStore
        printErrors: false
        onLoaded: {
            try {
                var d = JSON.parse(text())
                if (typeof d.x === "number") root.posX = d.x
                if (typeof d.y === "number") root.posY = d.y
                root.locked = !!d.locked
            } catch (e) {}
        }
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", root.dataDir]
        running: true
        onExited: {
            posStore.path = root.dataDir + "/layout.json"
            store.path = root.dataDir + "/events.json"
        }
    }

    Process {
        id: notifier
        onRunningChanged: if (!running) root.pump()
    }

    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.now = new Date()
            root.checkReminders()
        }
    }

    Timer { id: tipDelay; interval: 220; onTriggered: root.showTip() }
    Timer { id: wheelCool; interval: 140 }

    function showTip() {
        var c = tip.target
        if (!c || c.list.length === 0) { tip.shown = false; return }
        var p = c.mapToItem(overlay, 0, 0)
        tip.key = c.key
        tip.cx = p.x + c.width / 2
        tip.cellTop = p.y
        tip.cellBottom = p.y + c.height
        tip.shown = true
    }

    IpcHandler {
        target: "calendar"
        function toggle(): void { win.visible = !win.visible }
        function show(): void { win.visible = true }
        function hide(): void { win.visible = false }
    }

    // ── small reusable pieces ───────────────────────────────────────────
    component Chip: Rectangle {
        id: chip
        required property string modelData
        property color accent: "white"
        property string family: "sans"
        implicitWidth: chipLabel.implicitWidth + 14
        implicitHeight: 20
        radius: 10
        color: Qt.alpha(accent, 0.16)

        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: "#" + chip.modelData
            color: chip.accent
            font.family: chip.family
            font.pixelSize: 11
        }
    }

    component IconBtn: Rectangle {
        id: btn
        property string glyph: ""
        property string fallback: ""
        property bool icons: true
        property string iconFont: "Material Symbols Rounded"
        property color fg: "white"
        property color hoverColor: "gray"
        property color fill: Qt.alpha(hoverColor, 0)
        property int size: 32
        property int glyphSize: 20
        signal clicked()

        width: size
        height: size
        radius: size / 2
        color: area.containsMouse ? hoverColor : fill
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
            anchors.centerIn: parent
            text: btn.icons ? btn.glyph : btn.fallback
            color: btn.fg
            font.family: btn.icons ? btn.iconFont : "sans"
            font.pixelSize: btn.icons ? btn.glyphSize : btn.glyphSize - 4
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // ── window ──────────────────────────────────────────────────────────
    PanelWindow {
        id: win
        visible: root.startVisible
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; left: true }
        margins { top: root.effY; left: root.effX }
        implicitWidth: card.width
        implicitHeight: root.fullH
        mask: Region { item: card }                // clicks outside the card pass through

        WlrLayershell.namespace: "caelestia-calendar"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        onVisibleChanged: {
            if (!visible) return
            root.goToday()
            enter.restart()
            root.focusCard()
        }

        ParallelAnimation {
            id: enter
            NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 160; easing.type: Easing.OutCubic }
        }

        Rectangle {
            id: card
            width: 352
            height: 24 + col.implicitHeight + panel.height + 24
            radius: 28
            color: theme.surface
            border.width: 1
            border.color: Qt.alpha(theme.outlineVariant, 0.45)
            focus: true

            Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) {
                    win.visible = false
                    event.accepted = true
                } else if (event.key === Qt.Key_PageUp) {
                    root.shiftMonth(-1)
                    event.accepted = true
                } else if (event.key === Qt.Key_PageDown) {
                    root.shiftMonth(1)
                    event.accepted = true
                }
            }

            // swallow clicks inside the card
            MouseArea {
                anchors.fill: parent
                onClicked: root.focusCard()
            }

            ColumnLayout {
                id: col
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 24 }
                spacing: 12

                // header
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40

                    // drag by the empty part of the header
                    MouseArea {
                        anchors.fill: parent
                        enabled: !root.locked
                        cursorShape: Qt.SizeAllCursor
                        property real px: 0
                        property real py: 0
                        onPressed: function (m) { px = m.x; py = m.y }
                        onPositionChanged: function (m) {
                            if (!pressed) return
                            root.posX = Math.max(0, Math.min(root.screenW - card.width, root.effX + m.x - px))
                            root.posY = Math.max(0, Math.min(root.screenH - root.fullH, root.effY + m.y - py))
                        }
                        onReleased: root.savePos()
                    }

                RowLayout {
                    anchors.fill: parent
                    spacing: 4

                    MouseArea {
                        Layout.preferredWidth: titleRow.implicitWidth
                        Layout.fillHeight: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.goToday()

                        Row {
                            id: titleRow
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            Text {
                                text: Qt.formatDate(new Date(root.viewYear, root.viewMonth, 1), "MMMM")
                                color: theme.m3onSurface
                                font.family: root.sans
                                font.pixelSize: 22
                                font.weight: Font.Medium
                            }
                            Text {
                                text: root.viewYear
                                color: theme.m3onSurfaceVariant
                                opacity: 0.7
                                font.family: root.sans
                                font.pixelSize: 22
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    IconBtn {
                        glyph: root.locked ? "lock" : "lock_open"; fallback: root.locked ? "🔒" : "🔓"
                        icons: root.hasIcons; iconFont: root.iconFont
                        fg: root.locked ? theme.primary : theme.m3onSurfaceVariant
                        hoverColor: theme.surfaceContainerHigh
                        glyphSize: 18
                        onClicked: { root.locked = !root.locked; root.savePos() }
                    }
                    IconBtn {
                        glyph: "chevron_left"; fallback: "‹"
                        icons: root.hasIcons; iconFont: root.iconFont
                        fg: theme.m3onSurfaceVariant; hoverColor: theme.surfaceContainerHigh
                        onClicked: root.shiftMonth(-1)
                    }
                    IconBtn {
                        glyph: "chevron_right"; fallback: "›"
                        icons: root.hasIcons; iconFont: root.iconFont
                        fg: theme.m3onSurfaceVariant; hoverColor: theme.surfaceContainerHigh
                        onClicked: root.shiftMonth(1)
                    }
                }
                }

                // weekday labels
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 4

                    Repeater {
                        model: 7
                        delegate: Text {
                            required property int index
                            width: 40
                            horizontalAlignment: Text.AlignHCenter
                            text: Qt.locale().dayName((root.weekStart + index) % 7, Locale.ShortFormat).slice(0, 2)
                            color: theme.m3onSurfaceVariant
                            opacity: 0.6
                            font.family: root.sans
                            font.pixelSize: 12
                        }
                    }
                }

                // month grid
                Grid {
                    id: grid
                    Layout.alignment: Qt.AlignHCenter
                    columns: 7
                    spacing: 4

                    WheelHandler {
                        onWheel: function (event) {
                            if (wheelCool.running) return
                            root.shiftMonth(event.angleDelta.y > 0 ? -1 : 1)
                            wheelCool.start()
                        }
                    }

                    Repeater {
                        model: 42
                        delegate: Item {
                            id: cell
                            required property int index

                            readonly property var d: new Date(root.viewYear, root.viewMonth, 1 - root.gridOffset + index)
                            readonly property string key: root.keyOf(d)
                            readonly property bool inMonth: d.getMonth() === root.viewMonth
                            readonly property bool isToday: key === root.todayKey
                            readonly property bool isSel: root.panelOpen && key === root.selected
                            readonly property var list: root.entriesFor(key)

                            width: 40
                            height: 40

                            function dotColor(i) {
                                if (isToday) return theme.m3onPrimary
                                var e = list[i]
                                return e.tags && e.tags.length > 0 ? root.tagColor(e.tags[0]) : theme.primary
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: cell.isToday ? theme.primary
                                     : cell.isSel ? theme.primaryContainer
                                     : area.containsMouse ? theme.surfaceContainerHigh
                                     : Qt.alpha(theme.surfaceContainerHigh, 0)
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            Text {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: cell.list.length > 0 ? -3 : 0
                                Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 120 } }
                                text: cell.d.getDate()
                                color: cell.isToday ? theme.m3onPrimary
                                     : cell.isSel ? theme.m3onPrimaryContainer
                                     : theme.m3onSurface
                                opacity: cell.inMonth || cell.isToday || cell.isSel ? 1 : 0.32
                                font.family: root.sans
                                font.pixelSize: 14
                                font.weight: cell.isToday ? Font.Medium : Font.Normal
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 6
                                spacing: 3
                                opacity: cell.inMonth ? 1 : 0.4

                                Repeater {
                                    model: Math.min(3, cell.list.length)
                                    delegate: Rectangle {
                                        required property int index
                                        width: 4
                                        height: 4
                                        radius: 2
                                        color: cell.dotColor(index)
                                    }
                                }
                            }

                            MouseArea {
                                id: area
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.pick(cell.d, cell.key)
                                onEntered: root.hoverIn(cell)
                                onExited: root.hoverOut(cell)
                            }
                        }
                    }
                }

            }

            // day panel: height/opacity animated by root.panelT, so only this part moves
            Item {
                id: panel
                x: 24
                y: 24 + col.implicitHeight                  // sits directly under the calendar block
                width: card.width - 48
                height: Math.round(root.panelT * (panelCol.implicitHeight + 12))
                clip: true
                opacity: root.panelT * root.panelT          // content fades before the box finishes shrinking
                enabled: root.panelOpen

                ColumnLayout {
                    id: panelCol
                    y: 12
                    width: parent.width
                    spacing: 12

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Qt.alpha(theme.outlineVariant, 0.4)
                    }

                    // selected day
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: Qt.formatDate(root.dateFromKey(root.selected), "dddd, d MMMM")
                            color: theme.m3onSurface
                            font.family: root.sans
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: root.selList.length > 0
                            text: root.selList.length + (root.selList.length === 1 ? " item" : " items")
                            color: theme.m3onSurfaceVariant
                            opacity: 0.7
                            font.family: root.sans
                            font.pixelSize: 12
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 112

                        Text {
                            anchors.centerIn: parent
                            visible: root.selList.length === 0
                            text: "Nothing planned"
                            color: theme.m3onSurfaceVariant
                            opacity: 0.5
                            font.family: root.sans
                            font.pixelSize: 13
                        }

                        Flickable {
                            id: flick
                            anchors.fill: parent
                            contentHeight: listCol.implicitHeight
                            contentWidth: width
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: listCol
                                width: flick.width
                                spacing: 8

                                Repeater {
                                    model: root.selList
                                    delegate: Item {
                                        id: row
                                        required property var modelData

                                        width: listCol.width
                                        height: rowCol.implicitHeight

                                        HoverHandler { id: rowHover }

                                        ColumnLayout {
                                            id: rowCol
                                            width: parent.width - 30
                                            spacing: 4

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 10
                                                visible: !!row.modelData.time || !!row.modelData.text

                                                Text {
                                                    visible: !!row.modelData.time
                                                    text: root.fmtTime(row.modelData.time)
                                                    color: theme.primary
                                                    font.family: root.mono
                                                    font.pixelSize: 12
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: !!row.modelData.text
                                                    text: row.modelData.text
                                                    color: theme.m3onSurface
                                                    wrapMode: Text.Wrap
                                                    maximumLineCount: 2
                                                    elide: Text.ElideRight
                                                    font.family: root.sans
                                                    font.pixelSize: 14
                                                }
                                            }

                                            Flow {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: childrenRect.height
                                                visible: row.modelData.tags.length > 0
                                                spacing: 4

                                                Repeater {
                                                    model: row.modelData.tags
                                                    delegate: Chip {
                                                        accent: root.tagColor(modelData)
                                                        family: root.sans
                                                    }
                                                }
                                            }
                                        }

                                        IconBtn {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            size: 24
                                            glyphSize: 16
                                            glyph: "close"; fallback: "✕"
                                            icons: root.hasIcons; iconFont: root.iconFont
                                            fg: theme.m3onSurfaceVariant
                                            hoverColor: theme.surfaceContainerHigh
                                            opacity: rowHover.hovered ? 1 : 0
                                            enabled: rowHover.hovered
                                            Behavior on opacity { NumberAnimation { duration: 100 } }
                                            onClicked: root.removeEntry(root.selected, row.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // input:  text  #tag  @18:30
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        radius: 22
                        color: theme.surfaceContainer
                        border.width: 1
                        border.color: input.activeFocus ? Qt.alpha(theme.primary, 0.7) : Qt.alpha(theme.primary, 0)
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        TextInput {
                            id: input
                            anchors.left: parent.left
                            anchors.leftMargin: 18
                            anchors.right: addBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            clip: true
                            selectByMouse: true
                            color: theme.m3onSurface
                            selectionColor: theme.primary
                            selectedTextColor: theme.m3onPrimary
                            font.family: root.sans
                            font.pixelSize: 14

                            onAccepted: { if (root.submit(text)) text = "" }

                            Keys.onEscapePressed: function (event) {
                                if (text.length > 0) {
                                    text = ""
                                    event.accepted = true
                                } else {
                                    event.accepted = false
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: input.text.length === 0
                                text: "Add a note   #tag   @18:30"
                                color: theme.m3onSurfaceVariant
                                opacity: 0.55
                                font.family: root.sans
                                font.pixelSize: 14
                            }
                        }

                        IconBtn {
                            id: addBtn
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: "add"; fallback: "+"
                            icons: root.hasIcons; iconFont: root.iconFont
                            fill: theme.primary
                            hoverColor: Qt.lighter(theme.primary, 1.12)
                            fg: theme.m3onPrimary
                            onClicked: { if (root.submit(input.text)) input.text = "" }
                        }
                    }
                }
            }

            // hover tooltip (lives above everything inside the card)
            Item {
                id: overlay
                anchors.fill: parent
                z: 50

                Rectangle {
                    id: tip

                    property Item target: null
                    property string key: ""
                    property bool shown: false
                    property real cx: 0
                    property real cellTop: 0
                    property real cellBottom: 0
                    readonly property var list: root.entriesFor(key)

                    width: 232
                    height: tipCol.implicitHeight + 28
                    x: Math.max(6, Math.min(overlay.width - width - 6, cx - width / 2))
                    y: cellTop - height - 8 >= 6 ? cellTop - height - 8 : cellBottom + 8
                    radius: 16
                    color: theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Qt.alpha(theme.outlineVariant, 0.6)
                    opacity: shown ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    ColumnLayout {
                        id: tipCol
                        x: 14
                        y: 14
                        width: parent.width - 28
                        spacing: 8

                        Text {
                            text: Qt.formatDate(root.dateFromKey(tip.key), "ddd, d MMM")
                            color: theme.m3onSurfaceVariant
                            font.family: root.sans
                            font.pixelSize: 12
                        }

                        Repeater {
                            model: tip.list
                            delegate: ColumnLayout {
                                id: te
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 4

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    visible: !!te.modelData.time || !!te.modelData.text

                                    Text {
                                        visible: !!te.modelData.time
                                        text: root.fmtTime(te.modelData.time)
                                        color: theme.primary
                                        font.family: root.mono
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        visible: !!te.modelData.text
                                        text: te.modelData.text
                                        color: theme.m3onSurface
                                        wrapMode: Text.Wrap
                                        font.family: root.sans
                                        font.pixelSize: 13
                                    }
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: childrenRect.height
                                    visible: te.modelData.tags.length > 0
                                    spacing: 4

                                    Repeater {
                                        model: te.modelData.tags
                                        delegate: Chip {
                                            accent: root.tagColor(modelData)
                                            family: root.sans
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
}
