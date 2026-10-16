import QtQuick
import QtQuick.Controls.Basic as QC
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Sticky notes: every note is its own small layer-shell window, so there is no
// input mask to go stale. Dragging moves the window by changing its margins.
ShellRoot {
    id: root

    // ---------- settings ----------
    // true  = notes sit on the desktop, behind your windows
    // false = notes float above your windows
    property bool desktopOnly: true

    property bool placing: false
    readonly property int noteW: 220
    readonly property int noteH: 220

    readonly property var swatches: [
        { body: "#fff59d", header: "#f7e66a" }, // yellow
        { body: "#ffcc80", header: "#f5b85c" }, // orange
        { body: "#f8bbd0", header: "#ee9fb9" }, // pink
        { body: "#b9f6ca", header: "#98e6ae" }, // green
        { body: "#b3e5fc", header: "#92d3f2" }, // blue
        { body: "#d1c4e9", header: "#bdaedd" }  // purple
    ]

    // =====================================================================
    // Visuals of one note (inline component). Emits signals, owns no state.
    // =====================================================================
    component StickyNote: Rectangle {
        id: note

        property var swatches: []
        property int colorIndex: 0
        property string initialText: ""
        property bool autoFocus: false
        property bool ready: false

        signal dragged(real dx, real dy)
        signal dragFinished()
        signal edited(string newText)
        signal cycleColor()
        signal deleteRequested()

        radius: 6
        color: swatches.length ? swatches[colorIndex % swatches.length].body : "#fff59d"
        border.width: 1
        border.color: "#40000000"

        Rectangle {
            id: header
            width: parent.width
            height: 28
            radius: note.radius
            color: note.swatches.length
                ? note.swatches[note.colorIndex % note.swatches.length].header : "#f7e66a"

            Rectangle { // square off the bottom corners
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.radius
                color: parent.color
            }

            MouseArea {
                property real px: 0
                property real py: 0
                anchors.fill: parent
                anchors.rightMargin: 56
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                onPressed: m => { px = m.x; py = m.y; }
                onPositionChanged: m => { if (pressed) note.dragged(m.x - px, m.y - py); }
                onReleased: note.dragFinished()
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                // shows the NEXT colour; click to cycle
                MouseArea {
                    width: 20; height: 20
                    cursorShape: Qt.PointingHandCursor
                    onClicked: note.cycleColor()
                    Rectangle {
                        anchors.centerIn: parent
                        width: 14; height: 14; radius: 7
                        color: note.swatches.length
                            ? note.swatches[(note.colorIndex + 1) % note.swatches.length].body
                            : "#ffffff"
                        border.width: 1
                        border.color: "#66000000"
                    }
                }

                MouseArea {
                    width: 20; height: 20
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: note.deleteRequested()
                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        font.pixelSize: 14
                        color: parent.containsMouse ? "#b3261e" : "#80000000"
                    }
                }
            }
        }

        QC.ScrollView {
            anchors {
                top: header.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                margins: 8
            }
            clip: true

            QC.TextArea {
                id: ta
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                padding: 2
                color: "#3a3320"
                font.pixelSize: 15
                placeholderText: "Write something…"
                placeholderTextColor: "#80000000"
                background: null

                onTextChanged: if (note.ready) note.edited(text)
            }
        }

        Component.onCompleted: {
            ta.text = initialText;
            ready = true;
            if (autoFocus) ta.forceActiveFocus();
        }
    }

    // =====================================================================
    // Data + persistence (notes.json next to this file)
    // =====================================================================
    ListModel { id: noteModel }

    FileView {
        id: store
        path: Quickshell.shellPath("notes.json")
        printErrors: false

        onLoaded: {
            try {
                const saved = JSON.parse(store.text());
                for (const n of saved) {
                    noteModel.append({
                        x: n.x ?? 40,
                        y: n.y ?? 40,
                        text: n.text ?? "",
                        ci: n.ci ?? 0,
                        fresh: false
                    });
                }
            } catch (e) {
                console.warn("sticky-notes: could not parse notes.json:", e);
            }
        }
    }

    function save() {
        const out = [];
        for (let i = 0; i < noteModel.count; i++) {
            const n = noteModel.get(i);
            out.push({ x: n.x, y: n.y, text: n.text, ci: n.ci });
        }
        store.setText(JSON.stringify(out, null, 2));
    }

    Timer {
        id: saveTimer
        interval: 600
        onTriggered: root.save()
    }

    // Hyprland keybind:  bind = SUPER, N, exec, qs -c sticky-notes ipc call sticky add
    IpcHandler {
        target: "sticky"
        function add(): void { root.placing = true; }
    }

    // =====================================================================
    // One window per note
    // =====================================================================
    Instantiator {
        model: noteModel

        delegate: PanelWindow {
            id: noteWin

            required property int index
            required property var model

            // live position (margins from the top-left corner of the screen)
            property int posX: model.x
            property int posY: model.y

            anchors { top: true; left: true }
            margins { left: noteWin.posX; top: noteWin.posY }
            implicitWidth: root.noteW
            implicitHeight: root.noteH
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            WlrLayershell.namespace: "sticky-note"
            WlrLayershell.layer: root.desktopOnly ? WlrLayer.Bottom : WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            StickyNote {
                anchors.fill: parent

                swatches: root.swatches
                colorIndex: noteWin.model.ci
                initialText: noteWin.model.text
                autoFocus: noteWin.model.fresh

                onDragged: (dx, dy) => {
                    const sw = noteWin.screen ? noteWin.screen.width : 100000;
                    const sh = noteWin.screen ? noteWin.screen.height : 100000;
                    noteWin.posX = Math.round(Math.max(0, Math.min(noteWin.posX + dx, sw - root.noteW)));
                    noteWin.posY = Math.round(Math.max(0, Math.min(noteWin.posY + dy, sh - root.noteH)));
                }
                onDragFinished: {
                    noteModel.setProperty(noteWin.index, "x", noteWin.posX);
                    noteModel.setProperty(noteWin.index, "y", noteWin.posY);
                    root.save();
                }
                onEdited: newText => {
                    noteModel.setProperty(noteWin.index, "text", newText);
                    saveTimer.restart();
                }
                onCycleColor: {
                    noteModel.setProperty(noteWin.index, "ci",
                        (noteWin.model.ci + 1) % root.swatches.length);
                    root.save();
                }
                onDeleteRequested: {
                    const i = noteWin.index;
                    Qt.callLater(() => { noteModel.remove(i); root.save(); });
                }

                Component.onCompleted: {
                    if (noteWin.model.fresh) noteModel.setProperty(noteWin.index, "fresh", false);
                }
            }
        }
    }

    // =====================================================================
    // Small "+" button window (bottom-right)
    // =====================================================================
    PanelWindow {
        anchors { bottom: true; right: true }
        margins { bottom: 24; right: 24 }
        implicitWidth: 44
        implicitHeight: 44
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "sticky-notes-add"
        WlrLayershell.layer: root.desktopOnly ? WlrLayer.Bottom : WlrLayer.Top

        Rectangle {
            anchors.fill: parent
            radius: 22
            color: addMouse.containsMouse ? "#f7e66a" : "#fff59d"
            border.width: 1
            border.color: "#66000000"
            opacity: root.placing ? 0.4 : 0.9

            Text {
                anchors.centerIn: parent
                text: "+"
                font.pixelSize: 26
                color: "#3a3320"
            }
            MouseArea {
                id: addMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.placing = !root.placing
            }
        }
    }

    // =====================================================================
    // Placing overlay: only exists while placing. Click to drop a note,
    // right-click or Esc to cancel.
    // =====================================================================
    PanelWindow {
        id: placeWin
        visible: root.placing

        anchors { top: true; bottom: true; left: true; right: true }
        color: "#22000000"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "sticky-notes-placing"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Item {
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.placing = false

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.CrossCursor

                onPositionChanged: m => {
                    ghost.x = m.x - root.noteW / 2;
                    ghost.y = m.y - 14;
                }

                onClicked: m => {
                    if (m.button === Qt.RightButton) {
                        root.placing = false;
                        return;
                    }
                    noteModel.append({
                        x: Math.round(Math.max(0, Math.min(m.x - root.noteW / 2, placeWin.width - root.noteW))),
                        y: Math.round(Math.max(0, Math.min(m.y - 14, placeWin.height - root.noteH))),
                        text: "",
                        ci: noteModel.count % root.swatches.length,
                        fresh: true
                    });
                    root.placing = false;
                    root.save();
                }

                Rectangle {
                    id: ghost
                    width: root.noteW; height: root.noteH; radius: 6
                    color: root.swatches[noteModel.count % root.swatches.length].body
                    opacity: 0.6
                    border.width: 2
                    border.color: "#66000000"
                }
            }
        }
    }
}
