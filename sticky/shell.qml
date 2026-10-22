import QtQuick
import QtQuick.Controls.Basic as QC
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Sticky notes: every note is its own small layer-shell window, so there is no
// input mask to go stale. Dragging moves the window by changing its margins.
//
// Markdown (Obsidian-style): click a note to edit, click away / Esc / Ctrl+E to
// render it. Supported: # headings, **bold**, *italic*, ~~strike~~, ==highlight==,
// `code`, ``` fenced code ```, > quotes, > [!note] callouts, - lists (nested),
// 1. numbered lists, - [ ] clickable tasks, tables, ---, [text](url),
// [[wikilinks]], #tags, bare URLs.
// Editor keys: Ctrl+B bold, Ctrl+I italic, Ctrl+Shift+H highlight,
// Ctrl+Shift+X strike, Ctrl+E toggle preview, Enter continues lists, Tab indents.
ShellRoot {
    id: root

    // ---------- settings ----------
    // true  = notes sit on the desktop, behind your windows
    // false = notes float above your windows
    property bool desktopOnly: true

    property bool placing: false
    readonly property int noteW: 240
    readonly property int noteH: 240

    // new notes cycle through the first `lightCount` swatches only
    readonly property int lightCount: 12

    // NOTE: first six keep their original order so saved notes keep their colour.
    readonly property var swatches: [
        { body: "#fff59d", header: "#f7e66a", dark: false }, // yellow
        { body: "#ffcc80", header: "#f5b85c", dark: false }, // orange
        { body: "#f8bbd0", header: "#ee9fb9", dark: false }, // pink
        { body: "#b9f6ca", header: "#98e6ae", dark: false }, // green
        { body: "#b3e5fc", header: "#92d3f2", dark: false }, // blue
        { body: "#d1c4e9", header: "#bdaedd", dark: false }, // purple
        { body: "#ffab91", header: "#f4906f", dark: false }, // coral
        { body: "#a7ffeb", header: "#7fe8d3", dark: false }, // teal
        { body: "#e6ee9c", header: "#d4de78", dark: false }, // lime
        { body: "#efebe9", header: "#d7ccc8", dark: false }, // stone
        { body: "#e0e0e0", header: "#c7c7c7", dark: false }, // grey
        { body: "#c5cae9", header: "#aab1dc", dark: false }, // indigo
        { body: "#2b2d33", header: "#1f2126", dark: true  }, // charcoal
        { body: "#1e2a44", header: "#16203a", dark: true  }, // midnight
        { body: "#1f3a2e", header: "#16291f", dark: true  }, // forest
        { body: "#3a2342", header: "#2a1830", dark: true  }  // plum
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
        property bool editing: false
        property bool paletteOpen: false

        signal dragged(real dx, real dy)
        signal dragFinished()
        signal edited(string newText)
        signal colorPicked(int index)
        signal deleteRequested()

        readonly property var sw: swatches.length ? swatches[colorIndex % swatches.length] : null
        readonly property bool dark: sw ? sw.dark : false

        readonly property var pal: ({
            text:  dark ? "#ecebe4" : "#3a3320",
            muted: dark ? "#99ecebe4" : "#80000000",
            codeBg: dark ? "#33ffffff" : "#1f000000",
            link:  dark ? "#8ab4ff" : "#1a5fb4",
            tag:   dark ? "#c9a0ff" : "#7a3db8",
            hl:    dark ? "#8a7a1c" : "#ffe45c",
            hlText: dark ? "#ffffff" : "#000000"
        })

        radius: 6
        color: sw ? sw.body : "#fff59d"
        border.width: 1
        border.color: "#40000000"

        // -------------------------------------------------------------
        // Markdown -> Qt rich text
        // -------------------------------------------------------------
        function esc(s) {
            return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        }

        function render(src, p) {
            const calloutIcons = {
                note: "📝", info: "ℹ️", tip: "💡", hint: "💡", important: "❗",
                success: "✅", check: "✅", done: "✅", question: "❓", warning: "⚠️",
                caution: "⚠️", failure: "❌", danger: "🔥", bug: "🐛", example: "📋",
                quote: "💬", abstract: "📄", summary: "📄", todo: "☑️"
            };

            function inline(raw) {
                let s = esc(raw);
                const codes = [];
                s = s.replace(/`([^`]+)`/g, (m, c) => {
                    codes.push(c);
                    return "\u0001" + (codes.length - 1) + "\u0002";
                });

                // [[wikilink]] and [[target|alias]]
                s = s.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g,
                    (m, t, a) => `<a href="wiki:${t}">${a ? a : t}</a>`);
                // [text](url)
                s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, t, u) => `<a href="${u}">${t}</a>`);
                // bare urls
                s = s.replace(/(^|\s)(https?:\/\/[^\s<]+)/g, (m, pre, u) => `${pre}<a href="${u}">${u}</a>`);

                // emphasis
                s = s.replace(/\*\*\*(?!\s)(.+?)\*\*\*/g, "<b><i>$1</i></b>");
                s = s.replace(/\*\*(?!\s)(.+?)\*\*/g, "<b>$1</b>");
                s = s.replace(/(^|[^\w])__(?!\s)(.+?)__(?!\w)/g, "$1<b>$2</b>");
                s = s.replace(/\*(?!\s)([^*]+?)\*/g, "<i>$1</i>");
                s = s.replace(/(^|[^\w])_(?!\s)([^_]+?)_(?!\w)/g, "$1<i>$2</i>");
                s = s.replace(/~~(?!\s)(.+?)~~/g, "<s>$1</s>");
                s = s.replace(/==(?!\s)(.+?)==/g,
                    `<span style="background-color:${p.hl}; color:${p.hlText}">&nbsp;$1&nbsp;</span>`);

                // #tags
                s = s.replace(/(^|\s)#([\w\/-]*[A-Za-z_][\w\/-]*)/g,
                    (m, pre, t) => `${pre}<span style="color:${p.tag}">#${t}</span>`);

                // restore inline code
                s = s.replace(/\u0001(\d+)\u0002/g, (m, n) =>
                    `<span style="font-family:monospace; background-color:${p.codeBg}">&nbsp;${codes[parseInt(n)]}&nbsp;</span>`);
                return s;
            }

            function splitRow(l) {
                l = l.trim();
                if (l.startsWith("|")) l = l.slice(1);
                if (l.endsWith("|")) l = l.slice(0, -1);
                return l.split("|").map(c => c.trim());
            }

            const isTableSep = l => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(l) && l.indexOf("-") >= 0;

            const lines = src.split("\n");
            const out = [];
            let i = 0;
            let lastBlank = false;

            while (i < lines.length) {
                const raw = lines[i];
                let m;

                // fenced code block
                if (/^\s*```/.test(raw)) {
                    const buf = [];
                    i++;
                    while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) { buf.push(lines[i]); i++; }
                    i++;
                    out.push(`<pre style="margin:4px 0; background-color:${p.codeBg}; font-family:monospace; font-size:13px">${esc(buf.join("\n"))}</pre>`);
                    lastBlank = false;
                    continue;
                }

                // blank line (collapse runs)
                if (raw.trim() === "") {
                    if (!lastBlank) out.push('<p style="margin:0; font-size:6px">&nbsp;</p>');
                    lastBlank = true;
                    i++;
                    continue;
                }
                lastBlank = false;

                // horizontal rule
                if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(raw)) {
                    out.push("<hr/>");
                    i++;
                    continue;
                }

                // heading
                m = raw.match(/^(#{1,6})\s+(.*)$/);
                if (m) {
                    const sizes = [0, 22, 19, 17, 16, 15, 15];
                    const lvl = m[1].length;
                    out.push(`<p style="margin:6px 0 2px 0"><span style="font-size:${sizes[lvl]}px; font-weight:bold">${inline(m[2].replace(/\s+#+\s*$/, ""))}</span></p>`);
                    i++;
                    continue;
                }

                // table
                if (raw.indexOf("|") >= 0 && i + 1 < lines.length && isTableSep(lines[i + 1])) {
                    const head = splitRow(raw);
                    let html = '<table border="1" cellspacing="0" cellpadding="3" width="100%"><tr>';
                    for (const h of head) html += `<th>${inline(h)}</th>`;
                    html += "</tr>";
                    i += 2;
                    while (i < lines.length && lines[i].indexOf("|") >= 0 && lines[i].trim() !== "") {
                        html += "<tr>";
                        for (const c of splitRow(lines[i])) html += `<td>${inline(c)}</td>`;
                        html += "</tr>";
                        i++;
                    }
                    html += "</table>";
                    out.push(html);
                    continue;
                }

                // blockquote / callout
                m = raw.match(/^\s*>\s?(.*)$/);
                if (m) {
                    const bar = `<span style="color:${p.tag}">▎</span>&nbsp;`;
                    const co = m[1].match(/^\[!(\w+)\][+-]?\s*(.*)$/);
                    if (co) {
                        const kind = co[1].toLowerCase();
                        const icon = calloutIcons[kind] || "📌";
                        const title = co[2] ? co[2] : kind.charAt(0).toUpperCase() + kind.slice(1);
                        out.push(`<p style="margin:2px 0 2px 4px">${bar}${icon}&nbsp;<b>${inline(title)}</b></p>`);
                    } else {
                        out.push(`<p style="margin:0 0 2px 4px; color:${p.muted}">${bar}${inline(m[1])}</p>`);
                    }
                    i++;
                    continue;
                }

                // list / task
                m = raw.match(/^(\s*)([-*+]|\d+[.)])\s+(?:\[([ xX])\]\s+)?(.*)$/);
                if (m) {
                    const depth = Math.floor(m[1].replace(/\t/g, "    ").length / 2);
                    const ml = 4 + depth * 16;
                    let marker, body = inline(m[4]);
                    if (m[3] !== undefined) {
                        const done = m[3] !== " ";
                        marker = `<a href="task:${i}">${done ? "☑" : "☐"}</a>`;
                        if (done) body = `<s><span style="color:${p.muted}">${body}</span></s>`;
                    } else if (/^\d/.test(m[2])) {
                        marker = esc(m[2]);
                    } else {
                        marker = depth % 2 ? "◦" : "•";
                    }
                    out.push(`<p style="margin:0 0 2px ${ml}px">${marker}&nbsp;${body}</p>`);
                    i++;
                    continue;
                }

                // plain paragraph line
                out.push(`<p style="margin:0 0 2px 0">${inline(raw)}</p>`);
                i++;
            }
            return out.join("");
        }

        function toggleTask(idx) {
            const ls = ta.text.split("\n");
            if (idx < 0 || idx >= ls.length) return;
            ls[idx] = ls[idx].replace(/^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])/,
                (m, a, b, c) => a + (b === " " ? "x" : " ") + c);
            ta.text = ls.join("\n");
        }

        function startEditing() {
            paletteOpen = false;
            editing = true;
            Qt.callLater(() => ta.forceActiveFocus());
        }

        function stopEditing() {
            if (ta.text.length > 0) editing = false;
        }

        function wrapSelection(mark) {
            const s = ta.selectionStart;
            const e = ta.selectionEnd;
            if (s === e) {
                const pos = ta.cursorPosition;
                ta.insert(pos, mark + mark);
                ta.cursorPosition = pos + mark.length;
            } else {
                ta.insert(e, mark);
                ta.insert(s, mark);
                ta.select(s + mark.length, e + mark.length);
            }
        }

        // Obsidian-style list continuation on Enter. Returns true if handled.
        function continueList() {
            const t = ta.text;
            const pos = ta.cursorPosition;
            const ls = t.lastIndexOf("\n", pos - 1) + 1;
            let le = t.indexOf("\n", pos);
            if (le < 0) le = t.length;
            const line = t.substring(ls, le);
            const m = line.match(/^(\s*)([-*+]|(\d+)([.)]))(\s+\[[ xX]\])?\s+(.*)$/);
            const empty = line.match(/^(\s*)([-*+]|\d+[.)])(\s+\[[ xX]\])?\s*$/);
            if (empty) {                       // empty item -> end the list
                ta.remove(ls, le);
                ta.cursorPosition = ls;
                return true;
            }
            if (!m) return false;
            let marker = m[3] !== undefined ? (parseInt(m[3]) + 1) + m[4] : m[2];
            const task = m[5] ? " [ ]" : "";
            const ins = "\n" + m[1] + marker + task + " ";
            ta.insert(pos, ins);
            ta.cursorPosition = pos + ins.length;
            return true;
        }

        // ---------------------------------------------------------------
        Rectangle {
            id: header
            width: parent.width
            height: 28
            radius: note.radius
            color: note.sw ? note.sw.header : "#f7e66a"

            Rectangle { // square off the bottom corners
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.radius
                color: parent.color
            }

            MouseArea {
                property real px: 0
                property real py: 0
                anchors.fill: parent
                anchors.rightMargin: 92
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

                // edit / preview toggle
                MouseArea {
                    width: 20; height: 20
                    cursorShape: Qt.PointingHandCursor
                    onClicked: note.editing ? note.stopEditing() : note.startEditing()
                    Text {
                        anchors.centerIn: parent
                        text: note.editing ? "👁" : "✎"
                        font.pixelSize: 14
                        color: note.pal.muted
                    }
                }

                // colour picker toggle (shows current colour)
                MouseArea {
                    width: 20; height: 20
                    cursorShape: Qt.PointingHandCursor
                    onClicked: note.paletteOpen = !note.paletteOpen
                    Rectangle {
                        anchors.centerIn: parent
                        width: 14; height: 14; radius: 7
                        color: note.sw ? note.sw.body : "#ffffff"
                        border.width: 1
                        border.color: note.dark ? "#99ffffff" : "#66000000"
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
                        color: parent.containsMouse ? "#e5484d" : note.pal.muted
                    }
                }
            }
        }

        // ---------------- editor (raw markdown) ----------------
        QC.ScrollView {
            id: editorView
            visible: note.editing
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
                color: note.pal.text
                selectionColor: note.dark ? "#5a6fa8" : "#80a8d8"
                font.pixelSize: 15
                placeholderText: "Write something… (markdown)"
                placeholderTextColor: note.pal.muted
                background: null

                onTextChanged: if (note.ready) note.edited(text)
                onActiveFocusChanged: if (!activeFocus && note.ready) note.stopEditing()

                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    const shift = event.modifiers & Qt.ShiftModifier;

                    if (event.key === Qt.Key_Escape) {
                        note.stopEditing();
                        event.accepted = true;
                    } else if (ctrl && event.key === Qt.Key_E) {
                        note.stopEditing();
                        event.accepted = true;
                    } else if (ctrl && !shift && event.key === Qt.Key_B) {
                        note.wrapSelection("**");
                        event.accepted = true;
                    } else if (ctrl && !shift && event.key === Qt.Key_I) {
                        note.wrapSelection("*");
                        event.accepted = true;
                    } else if (ctrl && shift && event.key === Qt.Key_H) {
                        note.wrapSelection("==");
                        event.accepted = true;
                    } else if (ctrl && shift && event.key === Qt.Key_X) {
                        note.wrapSelection("~~");
                        event.accepted = true;
                    } else if (!ctrl && !shift && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                        if (note.continueList()) event.accepted = true;
                    } else if (!ctrl && !shift && event.key === Qt.Key_Tab) {
                        const pos = ta.cursorPosition;
                        ta.insert(pos, "  ");
                        ta.cursorPosition = pos + 2;
                        event.accepted = true;
                    }
                }
            }
        }

        // ---------------- rendered view ----------------
        Flickable {
            id: flick
            visible: !note.editing
            anchors {
                top: header.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                margins: 8
            }
            clip: true
            contentWidth: width
            contentHeight: Math.max(view.implicitHeight + 4, height)
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

            // click anywhere that isn't a link -> edit
            MouseArea {
                width: flick.width
                height: flick.contentHeight
                cursorShape: Qt.IBeamCursor
                onClicked: note.startEditing()
            }

            Text {
                id: view
                width: flick.width - 2
                x: 2
                z: 1
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.pixelSize: 15
                color: note.pal.text
                linkColor: note.pal.link
                text: note.editing ? "" : note.render(ta.text, note.pal)

                onLinkActivated: link => {
                    if (link.startsWith("task:")) note.toggleTask(parseInt(link.slice(5)));
                    else if (/^(https?:|mailto:)/.test(link)) Qt.openUrlExternally(link);
                    // wiki: links are styled but not navigable (notes have no titles)
                }
            }
        }

        // ---------------- colour palette popup ----------------
        Rectangle {
            id: palette
            visible: note.paletteOpen
            z: 10
            anchors {
                top: header.bottom
                topMargin: 4
                horizontalCenter: parent.horizontalCenter
            }
            width: parent.width - 16
            height: swatchGrid.height + 16
            radius: 8
            color: note.dark ? "#f2202228" : "#f2ffffff"
            border.width: 1
            border.color: "#55000000"

            Grid {
                id: swatchGrid
                anchors.centerIn: parent
                columns: 8
                spacing: 6

                Repeater {
                    model: note.swatches
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: 20; height: 20; radius: 10
                        color: modelData.body
                        border.width: index === note.colorIndex ? 2 : 1
                        border.color: index === note.colorIndex ? "#4c8dff" : "#99808080"

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                note.paletteOpen = false;
                                note.colorPicked(parent.index);
                            }
                        }
                    }
                }
            }
        }

        Component.onCompleted: {
            ta.text = initialText;
            editing = autoFocus || initialText === "";
            ready = true;
            if (autoFocus) Qt.callLater(() => ta.forceActiveFocus());
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
                onColorPicked: idx => {
                    noteModel.setProperty(noteWin.index, "ci", idx);
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
                        ci: noteModel.count % root.lightCount,
                        fresh: true
                    });
                    root.placing = false;
                    root.save();
                }

                Rectangle {
                    id: ghost
                    width: root.noteW; height: root.noteH; radius: 6
                    color: root.swatches[noteModel.count % root.lightCount].body
                    opacity: 0.6
                    border.width: 2
                    border.color: "#66000000"
                }
            }
        }
    }
}
