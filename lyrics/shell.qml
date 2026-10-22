// ~/.config/quickshell/lyrics/shell.qml
//
// Transparent, draggable, time-synced Spotify lyrics for Caelestia / Hyprland.
// Run with:  qs -c lyrics
//
// - Lyrics come from LRCLIB (https://lrclib.net), no API key needed.
// - Continuous word-to-word glow wave. The glow is a travelling bell curve that
//   slides across neighbouring words (they overlap), instead of switching on per word.
//   LRCLIB mostly has line-level timing, so word timing is estimated inside each line;
//   if a track ships "enhanced LRC" (<mm:ss.xx> word tags) those real timings are used.
// - Colors follow ~/.local/state/caelestia/scheme.json (live-reloaded).
// - Position, lock, font, alignment and glow settings persist in ./state.json.
// - Hover the widget: "Aa" opens the style panel, the padlock pins/unpins position.
//
// Style panel:
//   * Search box: type to filter installed fonts. Enter applies the best match.
//     Any font name can be typed and applied with the "Use ..." chip, even if it is
//     not in the list.
//   * Size, weight, italic, alignment, glow strength, wave softness, reset.
//
// IPC (optional):
//   qs -c lyrics ipc call lyrics toggleLock
//   qs -c lyrics ipc call lyrics reset
//   qs -c lyrics ipc call lyrics snap 0..8      (0 top-left … 4 centre … 8 bottom-right)
//   qs -c lyrics ipc call lyrics togglePicker
//   qs -c lyrics ipc call lyrics setFont "JetBrains Mono"
//   qs -c lyrics ipc call lyrics setFontSize 30
//   qs -c lyrics ipc call lyrics setWeight 700
//   qs -c lyrics ipc call lyrics setAlign left|center|right
//   qs -c lyrics ipc call lyrics setGlow 80        (percent, 0..100)
//   qs -c lyrics ipc call lyrics setWave 1.5       (softness multiplier, 0.5..3)
//   qs -c lyrics ipc call lyrics listFonts

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Effects

ShellRoot {
    id: root

    // ───────────────────────── Configuration ─────────────────────────
    readonly property string monitor: ""            // "" = first screen, or e.g. "DP-1"
    readonly property int widgetW: 560
    readonly property int widgetH: 300
    readonly property real lead: 0.12               // seconds: highlight a touch early
    readonly property int glowBlur: 48              // glow radius (px-ish)
    readonly property real trailSeconds: 1.1        // how long a sung word's glow takes to relax
    readonly property string lrclib: "https://lrclib.net"
    readonly property string schemePath: Quickshell.env("HOME") + "/.local/state/caelestia/scheme.json"

    // Persisted, user-editable settings
    readonly property string fontFamily: saved.fontFamily
    readonly property int fontSize: saved.fontSize
    readonly property int fontWeight: saved.fontWeight
    readonly property bool fontItalic: saved.fontItalic
    readonly property int align: saved.align
    readonly property real glowStrength: saved.glowStrength   // 0..1 peak glow opacity
    readonly property real waveSpread: saved.waveSpread       // 0.5..3 softness of the travelling wave

    // ───────────────────────── Theme (from Caelestia) ─────────────────────────
    property color cPrimary: "#d0bcff"
    property color cText: "#e6e0e9"
    property color cShadow: "#141218"
    property color cAccent: "#efb8c8"       // second wave colour (scheme tertiary)
    Behavior on cAccent { ColorAnimation { duration: 500 } }
    Behavior on cPrimary { ColorAnimation { duration: 500 } }
    Behavior on cText { ColorAnimation { duration: 500 } }
    Behavior on cShadow { ColorAnimation { duration: 500 } }

    function hex(v, fallback) {
        if (typeof v !== "string" || v.length === 0) return fallback;
        return v.charAt(0) === "#" ? v : "#" + v;
    }

    function pick(c, names, fallback) {
        for (let i = 0; i < names.length; i++)
            if (c[names[i]]) return hex(c[names[i]], fallback);
        return fallback;
    }

    // Second wave colour, taken straight from the Caelestia scheme with no tweaking, so it always
    // belongs to the theme. Mode: 0 = tertiary (Material's designed companion to primary),
    // 1 = secondary, 2 = off (single-colour wave). Falls back to primary if the key is missing.
    property var schemeColours: ({})
    readonly property var accentNames: ["Tertiary", "Secondary", "Off"]

    function updateAccent() {
        const c = schemeColours || {};
        const key = saved.accentMode === 1 ? "secondary" : "tertiary";
        cAccent = (saved.accentMode === 2 || !c[key]) ? cPrimary : hex(c[key], cPrimary);
    }

    function cycleAccent() {
        saved.accentMode = (saved.accentMode + 1) % 3;
        store.writeAdapter();
        updateAccent();
    }

    function applyScheme(raw) {
        try {
            const c = JSON.parse(raw).colours || {};
            cPrimary = pick(c, ["primary"], cPrimary);
            cText = pick(c, ["onSurface", "on_surface", "onBackground"], cText);
            cShadow = pick(c, ["surface", "background"], cShadow);
            schemeColours = c;
            updateAccent();
        } catch (e) {
            console.warn("lyrics: could not parse Caelestia scheme:", e);
        }
    }

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
    }

    function originFor(a) {
        return a === Text.AlignLeft ? Item.Left : a === Text.AlignRight ? Item.Right : Item.Center;
    }

    // ───────────────────────── Word layout ─────────────────────────
    // Words are positioned here (measure → wrap → align) rather than read back from a Text
    // item, so positions can never go stale or collapse to (0,0).
    TextMetrics { id: tm }
    FontMetrics { id: fm }

    function layoutLine(words, width, fam, px, wt, it, al) {
        const f = Qt.font({ family: fam, pixelSize: px, weight: wt, italic: it });
        fm.font = f;
        tm.font = f;
        tm.text = " ";
        const sp = tm.advanceWidth;
        const rowH = Math.ceil(fm.height * 1.05);
        const W = Math.max(60, width);

        const rows = [[]];
        const widths = [];
        let cur = 0;
        for (let i = 0; i < words.length; i++) {
            tm.text = words[i].s;
            const ww = tm.advanceWidth;
            let row = rows[rows.length - 1];
            if (row.length > 0 && cur + sp + ww > W) {
                rows.push([]);
                row = rows[rows.length - 1];
                cur = 0;
            }
            if (row.length > 0) cur += sp;
            row.push({ i: i, x: cur, w: ww });
            cur += ww;
            widths[rows.length - 1] = cur;
        }

        const pos = new Array(words.length);
        for (let r = 0; r < rows.length; r++) {
            const rw = widths[r] || 0;
            const off = al === Text.AlignLeft ? 0 : (al === Text.AlignRight ? W - rw : (W - rw) / 2);
            for (const e of rows[r]) pos[e.i] = { x: off + e.x, y: r * rowH };
        }
        return { pos: pos, height: rows.length * rowH };
    }

    FileView {
        path: root.schemePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applyScheme(text())
    }

    // ───────────────────────── Small reusable button ─────────────────────────
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property bool on: false
        property color accent: "#d0bcff"
        property color ink: "#ffffff"
        signal clicked()

        implicitWidth: chipText.implicitWidth + 22
        implicitHeight: 26
        radius: 13
        color: Qt.rgba(accent.r, accent.g, accent.b, on ? 0.38 : (chipArea.containsMouse ? 0.24 : 0.12))
        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            color: chip.ink
            font.pixelSize: 13
            font.weight: Font.Medium
        }

        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: chip.clicked()
        }
    }

    // ───────────────────────── Persistent state ─────────────────────────
    property bool storeReady: false

    FileView {
        id: store
        path: Quickshell.shellPath("state.json")
        printErrors: false
        onLoaded: { root.storeReady = true; root.place(); }
        onLoadFailed: error => {
            root.storeReady = true;
            root.place();
            if (error === FileViewError.FileNotFound) writeAdapter();
        }
        adapter: JsonAdapter {
            id: saved
            property real posX: -1
            property real posY: -1
            property bool locked: false
            property string fontFamily: "Rubik"
            property int fontSize: 26
            property int fontWeight: 600
            property bool fontItalic: false
            property int align: Text.AlignHCenter
            property real glowStrength: 0.95
            property real waveSpread: 1.0
            property int accentMode: 0
            property int snap: -1     // 0..8 = snapped to one of the 9 anchors, -1 = free position
        }
    }

    function persist() {
        saved.posX = widget.x;
        saved.posY = widget.y;
        store.writeAdapter();
    }

    function toggleLock() {
        saved.locked = !saved.locked;
        persist();
    }

    // ── Style controls ──
    property bool pickerOpen: false
    property var fontList: []
    property string fontQuery: ""
    readonly property var weightValues: [300, 400, 500, 600, 700, 800]
    readonly property var weightNames: ({
        "300": "Light", "400": "Regular", "500": "Medium",
        "600": "SemiBold", "700": "Bold", "800": "ExtraBold"
    })
    readonly property string weightLabel: weightNames[String(fontWeight)] || String(fontWeight)

    readonly property var shownFonts: {
        const q = fontQuery.trim().toLowerCase();
        return q === "" ? fontList : fontList.filter(f => f.toLowerCase().includes(q));
    }
    readonly property bool queryIsNew: {
        const q = fontQuery.trim().toLowerCase();
        return q !== "" && !fontList.some(f => f.toLowerCase() === q);
    }

    function setFont(name) {
        if (!name) return;
        saved.fontFamily = name;
        store.writeAdapter();
    }

    // Enter in the search box: exact match > first match > whatever was typed.
    function applySearch() {
        const q = fontQuery.trim();
        if (q === "") return;
        const exact = fontList.find(f => f.toLowerCase() === q.toLowerCase());
        setFont(exact || (shownFonts.length > 0 ? shownFonts[0] : q));
    }

    function setSize(px) {
        saved.fontSize = Math.max(14, Math.min(64, Math.round(px)));
        store.writeAdapter();
    }

    function setWeight(w) {
        saved.fontWeight = Math.max(100, Math.min(900, Math.round(w)));
        store.writeAdapter();
    }

    function cycleWeight() {
        const i = weightValues.indexOf(saved.fontWeight);
        setWeight(weightValues[(i + 1) % weightValues.length]);
    }

    function toggleItalic() {
        saved.fontItalic = !saved.fontItalic;
        store.writeAdapter();
    }

    function setAlign(a) {
        saved.align = a;
        store.writeAdapter();
    }

    function setAlignName(n) {
        const k = String(n).toLowerCase();
        setAlign(k === "left" ? Text.AlignLeft : k === "right" ? Text.AlignRight : Text.AlignHCenter);
    }

    function setGlow(v) {
        saved.glowStrength = Math.max(0, Math.min(1, v));
        store.writeAdapter();
    }

    function setWave(v) {
        saved.waveSpread = Math.max(0.5, Math.min(3, v));
        store.writeAdapter();
    }

    function resetStyle() {
        saved.fontFamily = "Rubik";
        saved.fontSize = 26;
        saved.fontWeight = 600;
        saved.fontItalic = false;
        saved.align = Text.AlignHCenter;
        saved.glowStrength = 0.95;
        saved.waveSpread = 1.0;
        saved.accentMode = 0;
        store.writeAdapter();
        updateAccent();
    }

    function installedFonts() {
        const seen = {};
        for (const f of Qt.fontFamilies()) if (f && f.charAt(0) !== ".") seen[f] = true;
        return Object.keys(seen).sort((a, b) => a.localeCompare(b));
    }

    function togglePicker() {
        if (pickerOpen) { pickerOpen = false; return; }
        fontList = installedFonts();
        fontQuery = "";
        pickerOpen = true;
        Qt.callLater(() => {
            const i = fontList.indexOf(fontFamily);
            if (i >= 0) fontView.positionViewAtIndex(i, ListView.Center);
        });
    }

    onPickerOpenChanged: {
        if (pickerOpen) Qt.callLater(() => search.forceActiveFocus());
        else { fontQuery = ""; search.text = ""; }
    }

    // ── Placement ──
    property bool placed: false

    function clampPos() {
        widget.x = Math.max(0, Math.min(win.width - widget.width, widget.x));
        widget.y = Math.max(0, Math.min(win.height - widget.height, widget.y));
    }

    // ── Snapping: 9 anchors, index = row*3 + col ──
    //   0 top-left     1 top-centre     2 top-right
    //   3 middle-left  4 centre         5 middle-right
    //   6 bottom-left  7 bottom-centre  8 bottom-right
    readonly property int snapMargin: 48
    readonly property int snapReach: 110        // px: how close a drop has to be to snap
    property bool snapAnimating: false
    Timer { id: snapTimer; interval: 280; onTriggered: root.snapAnimating = false }

    function anchorPos(i) {
        const col = i % 3, row = Math.floor(i / 3), m = snapMargin;
        const x = col === 0 ? m : (col === 1 ? (win.width - widget.width) / 2 : win.width - widget.width - m);
        const y = row === 0 ? m : (row === 1 ? (win.height - widget.height) / 2 : win.height - widget.height - m);
        return { x: Math.max(0, x), y: Math.max(0, y) };
    }

    function nearestAnchor(reach) {
        let best = -1, bd = reach;
        for (let i = 0; i < 9; i++) {
            const a = anchorPos(i);
            const d = Math.hypot(a.x - widget.x, a.y - widget.y);
            if (d < bd) { bd = d; best = i; }
        }
        return best;
    }

    // While dragging: which anchor would the widget snap to if dropped right now.
    readonly property int nearSnap: dragH.active ? nearestAnchor(snapReach) : -1

    function snapTo(i) {
        const a = anchorPos(i);
        snapAnimating = true;
        snapTimer.restart();
        saved.snap = i;
        widget.x = a.x;
        widget.y = a.y;
        saved.posX = a.x;
        saved.posY = a.y;
        store.writeAdapter();
    }

    function place() {
        if (!storeReady || !win || win.width <= 0 || win.height <= 0) return;
        const snapped = saved.snap >= 0 && saved.snap < 9;
        if (!placed) {
            placed = true;
            if (snapped) {
                const a = anchorPos(saved.snap);
                widget.x = a.x;
                widget.y = a.y;
            } else if (saved.posX >= 0 && saved.posY >= 0) {
                widget.x = saved.posX;
                widget.y = saved.posY;
            } else {
                const a = anchorPos(5);
                widget.x = a.x;
                widget.y = a.y;
            }
        } else if (snapped && !dragH.active) {
            // Window/screen size changed: stay glued to the chosen anchor.
            const a = anchorPos(saved.snap);
            widget.x = a.x;
            widget.y = a.y;
        }
        clampPos();
    }

    function resetPosition() { snapTo(5); }

    IpcHandler {
        target: "lyrics"
        function toggleLock(): void { root.toggleLock(); }
        function reset(): void { root.resetPosition(); }
        function snap(index: int): void { if (index >= 0 && index < 9) root.snapTo(index); }
        function togglePicker(): void { root.togglePicker(); }
        function setFont(name: string): void { root.setFont(name); }
        function setFontSize(px: int): void { root.setSize(px); }
        function setWeight(weight: int): void { root.setWeight(weight); }
        function setAlign(name: string): void { root.setAlignName(name); }
        function setGlow(percent: int): void { root.setGlow(percent / 100); }
        function setWave(mult: real): void { root.setWave(mult); }
        function listFonts(): string { return root.installedFonts().join("\n"); }
    }

    // ───────────────────────── Spotify detection ─────────────────────────
    readonly property var player: {
        const list = Mpris.players.values;
        let best = null;
        for (const p of list) {
            const id = ((p.dbusName || "") + " " + (p.identity || "") + " " + (p.desktopEntry || "")).toLowerCase();
            if (!id.includes("spotify")) continue;
            if (!best || (p.isPlaying && !best.isPlaying)) best = p;
        }
        return best;
    }

    readonly property bool isAd: player
        ? (player.trackTitle === "Advertisement" || player.trackTitle === "Spotify")
        : false
    readonly property bool wantShow: player !== null && player.isPlaying && !isAd

    // Debounced so brief Playing→Paused blips (track changes) don't flicker.
    property bool shown: false
    onWantShowChanged: {
        if (wantShow) { hideTimer.stop(); shown = true; resync(); }
        else hideTimer.restart();
    }
    onShownChanged: if (!shown) pickerOpen = false
    Timer { id: hideTimer; interval: 1200; onTriggered: root.shown = false }

    // ───────────────────────── Playback clock ─────────────────────────
    property real syncPos: 0
    property double syncAt: 0
    property var lines: []          // [{ t, text, words: [{ s, c, t0, t1 }] }]
    property int activeIndex: -1
    property real playhead: 0       // seconds; drives the word wave on the active line
    property string status: "idle"  // idle | loading | ok | none

    // Mouse-wheel browsing: scroll the lyrics freely; after a few idle seconds they glide back
    // to the line that's currently playing.
    property bool browsing: false
    property int browseIndex: 0
    readonly property int viewIndex: browsing ? browseIndex : activeIndex
    Timer { id: browseTimer; interval: 6000; onTriggered: root.browsing = false }

    function browseBy(steps) {
        if (lines.length === 0) return;
        if (!browsing) { browseIndex = Math.max(0, activeIndex); browsing = true; }
        browseIndex = Math.max(0, Math.min(lines.length - 1, browseIndex + steps));
        browseTimer.restart();
    }

    function clock() {
        return (player && player.isPlaying) ? syncPos + (Date.now() - syncAt) / 1000 : syncPos;
    }

    function resync() {
        if (!player) return;
        syncPos = player.position;
        syncAt = Date.now();
        tick();
    }

    // Click-to-seek: jump Spotify to a lyric line (its timestamp minus the highlight lead).
    function seekTo(t) {
        const p = player;
        if (!p || !p.canSeek) return;
        const target = Math.max(0, t - lead);
        browsing = false;
        browseTimer.stop();
        p.position = target;
        syncPos = target;
        syncAt = Date.now();
        tick();
    }

    function indexAt(t) {
        let lo = 0, hi = lines.length - 1, r = -1;
        while (lo <= hi) {
            const m = (lo + hi) >> 1;
            if (lines[m].t <= t) { r = m; lo = m + 1; } else hi = m - 1;
        }
        return r;
    }

    // One linear animation carries `playhead` from "now" to the end of the active line
    // (plus the glow trail). It runs in the render loop, so no JS is polled per frame.
    function driveWave(idx, now, playing) {
        phAnim.stop();
        playhead = now;
        if (idx < 0 || !playing) return;
        const w = lines[idx].words;
        const endT = (w.length > 0 ? w[w.length - 1].t1 : lines[idx].t) + trailSeconds * 1.6;
        if (endT > now) {
            phAnim.from = now;
            phAnim.to = endT;
            phAnim.duration = Math.max(1, (endT - now) * 1000);
            phAnim.restart();
        }
    }

    // Sets the active line, keeps the wave in sync, arms a timer for the next boundary.
    function tick() {
        const n = lines.length;
        if (n === 0) { activeIndex = -1; boundary.stop(); phAnim.stop(); return; }
        const playing = !!player && player.isPlaying;
        const t = clock() + lead;
        const idx = indexAt(t);
        const changed = idx !== activeIndex;
        if (changed) activeIndex = idx;
        if (changed || !playing || Math.abs(playhead - t) > 0.1) driveWave(idx, t, playing);
        if (playing && idx + 1 < n) {
            boundary.interval = Math.max(20, Math.min(30000, (lines[idx + 1].t - t) * 1000));
            boundary.restart();
        } else {
            boundary.stop();
        }
    }

    NumberAnimation {
        id: phAnim
        target: root
        property: "playhead"
        easing.type: Easing.Linear
    }

    Timer { id: boundary; repeat: false; onTriggered: root.tick() }

    // Spotify never pushes position updates; poke the property once a second to catch seeks/drift.
    Timer {
        interval: 1000
        repeat: true
        running: root.shown && root.player !== null && root.player.isPlaying
        onTriggered: root.player.positionChanged()
    }

    Connections {
        target: root.player
        ignoreUnknownSignals: true
        function onPositionChanged() { root.resync(); }
        function onIsPlayingChanged() { root.resync(); }
    }

    // ───────────────────────── Lyrics fetching & parsing ─────────────────────────
    property int fetchSeq: 0
    property var cache: ({})

    readonly property string trackKey: player
        ? [player.trackTitle, player.trackArtist, player.trackAlbum, Math.round(player.length)].join("|")
        : ""
    onTrackKeyChanged: fetchDebounce.restart()
    Timer { id: fetchDebounce; interval: 250; onTriggered: root.loadTrack() }

    function splitWords(text) {
        const out = [];
        const re = /\S+/g;
        let m;
        while ((m = re.exec(text)) !== null) out.push({ s: m[0], c: m.index, t0: 0, t1: 0 });
        return out;
    }

    // Estimated word timing: the line is "sung" over a plausible duration, split by word length.
    function timePlain(L, gap) {
        const words = splitWords(L.text);
        let sing;
        if (L.text === "♪") {
            sing = Math.min(gap * 0.92, 8);
        } else {
            let chars = 0;
            for (const w of words) chars += w.s.length;
            sing = Math.min(gap * 0.92, Math.max(0.8, chars * 0.075 + words.length * 0.04));
        }
        let tot = 0;
        for (const w of words) tot += w.s.length + 1;
        let acc = 0;
        for (const w of words) {
            w.t0 = L.t + sing * acc / tot;
            acc += w.s.length + 1;
            w.t1 = L.t + sing * acc / tot;
        }
        return words;
    }

    // Real word timing from enhanced LRC (<mm:ss.xx> tags); handles syllable-level tags too.
    function timeSegs(L, nextT) {
        const segs = L.segs;
        let joined = "";
        const ct0 = [], ct1 = [];
        for (let i = 0; i < segs.length; i++) {
            const s = segs[i];
            let end = (i + 1 < segs.length)
                ? segs[i + 1].t
                : Math.min(nextT, s.t + Math.max(0.4, s.text.trim().length * 0.075));
            end = Math.max(end, s.t + 0.05);
            const n = s.text.length;
            for (let k = 0; k < n; k++) {
                ct0.push(s.t + (end - s.t) * k / n);
                ct1.push(s.t + (end - s.t) * (k + 1) / n);
            }
            joined += s.text;
        }
        const lead = joined.length - joined.replace(/^\s+/, "").length;
        L.text = joined.trim();
        const words = [];
        const re = /\S+/g;
        let m;
        while ((m = re.exec(joined)) !== null) {
            const a = m.index, b = m.index + m[0].length - 1;
            words.push({ s: m[0], c: a - lead, t0: ct0[a], t1: ct1[b] });
        }
        return words;
    }

    function parseLrc(text) {
        const out = [];
        const tag = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/g;
        const wtag = /<(\d+):(\d+(?:\.\d+)?)>/;
        for (const raw of text.split(/\r?\n/)) {
            const times = [];
            let m, last = 0;
            tag.lastIndex = 0;
            while ((m = tag.exec(raw)) !== null) {
                times.push(parseInt(m[1]) * 60 + parseFloat(m[2].replace(":", ".")));
                last = tag.lastIndex;
            }
            if (times.length === 0) continue;

            const rest = raw.slice(last);
            let segs = null;
            if (wtag.test(rest)) {
                segs = [];
                const re = /<(\d+):(\d+(?:\.\d+)?)>([^<]*)/g;
                let mm;
                while ((mm = re.exec(rest)) !== null)
                    segs.push({ t: parseInt(mm[1]) * 60 + parseFloat(mm[2]), text: mm[3] });
            }
            const txt = rest.replace(/<\d+:\d+(?:\.\d+)?>/g, "").replace(/\s+/g, " ").trim();
            for (const t of times) out.push({ t: t, text: txt, segs: segs, words: [] });
        }
        out.sort((a, b) => a.t - b.t);

        for (let i = 0; i < out.length; i++) {
            const L = out[i];
            const nextT = i + 1 < out.length ? out[i + 1].t : L.t + 6;
            const gap = Math.max(0.3, nextT - L.t);
            let words = [];
            if (L.segs && L.segs.length > 0) words = timeSegs(L, nextT);
            if (words.length === 0) {
                L.text = L.text || "♪";
                words = timePlain(L, gap);
            }
            L.words = words;
            delete L.segs;
        }
        return out;
    }

    function httpGet(url, cb) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            let data = null;
            if (xhr.status === 200) {
                try { data = JSON.parse(xhr.responseText); } catch (e) { data = null; }
            }
            cb(xhr.status, data);
        };
        xhr.open("GET", url);
        xhr.send();
    }

    function cleanTitle(t) {
        return t.replace(/\s*[\(\[].*?[\)\]]/g, "").replace(/\s+-\s+.*$/, "").trim();
    }

    function firstArtist(a) {
        return a.split(/,|;|&|\sfeat\.?\s/i)[0].trim();
    }

    function applyLines(parsed) {
        browsing = false;
        lines = parsed;
        activeIndex = -1;
        status = parsed.length > 0 ? "ok" : "none";
        fadeIn.restart();
        resync();
    }

    function finish(seq, key, lrc) {
        if (seq !== fetchSeq) return;
        const parsed = lrc ? parseLrc(lrc) : [];
        if (Object.keys(cache).length > 40) cache = ({});
        cache[key] = parsed;
        applyLines(parsed);
    }

    function loadTrack() {
        const p = player;
        const seq = ++fetchSeq;
        lines = [];
        activeIndex = -1;
        boundary.stop();
        phAnim.stop();
        status = "idle";
        if (!p || !p.trackTitle || isAd) return;

        const key = trackKey;
        if (cache[key] !== undefined) { applyLines(cache[key]); return; }

        status = "loading";
        const title = p.trackTitle;
        const artist = p.trackArtist || "";
        const album = p.trackAlbum || "";
        const dur = Math.round(p.length);
        const enc = encodeURIComponent;

        let q = "track_name=" + enc(title) + "&artist_name=" + enc(artist);
        if (album) q += "&album_name=" + enc(album);
        if (dur > 0) q += "&duration=" + dur;

        httpGet(lrclib + "/api/get?" + q, (st, data) => {
            if (seq !== fetchSeq) return;
            if (st === 200 && data && data.syncedLyrics) { finish(seq, key, data.syncedLyrics); return; }
            if (st === 200 && data && data.instrumental) { finish(seq, key, ""); return; }

            // Fallback: fuzzy search with a cleaned title, pick the closest duration.
            const sq = "track_name=" + enc(cleanTitle(title)) + "&artist_name=" + enc(firstArtist(artist));
            httpGet(lrclib + "/api/search?" + sq, (st2, arr) => {
                if (seq !== fetchSeq) return;
                let best = null, bestDiff = 1e9;
                if (Array.isArray(arr)) {
                    for (const r of arr) {
                        if (!r.syncedLyrics) continue;
                        const d = (dur > 0 && r.duration) ? Math.abs(r.duration - dur) : 5;
                        if (d < bestDiff) { best = r; bestDiff = d; }
                    }
                }
                finish(seq, key, best && bestDiff <= 6 ? best.syncedLyrics : "");
            });
        });
    }

    // ───────────────────────── Window ─────────────────────────
    PanelWindow {
        id: win
        screen: Quickshell.screens.find(s => s.name === root.monitor) ?? Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "lyrics-widget"
        // Keyboard is only requested while the style panel is open (for the font search box).
        WlrLayershell.keyboardFocus: root.pickerOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        visible: root.shown || widget.opacity > 0.01

        // Only the widget's box receives input; the rest of the desktop stays click-through.
        // The widget plus the (separate) style panel receive input; the rest stays click-through.
        // The panel region collapses to nothing while the panel is closed.
        mask: Region {
            item: widget
            Region {
                x: widget.x + picker.x
                y: widget.y + picker.y
                width: picker.visible ? picker.width : 0
                height: picker.visible ? picker.height : 0
            }
        }

        onWidthChanged: root.place()
        onHeightChanged: root.place()

        // Snap guides, visible only while dragging (purely visual; they never take input).
        Rectangle {
            readonly property var a: root.nearSnap >= 0 ? root.anchorPos(root.nearSnap) : ({ x: 0, y: 0 })
            visible: root.nearSnap >= 0
            x: a.x
            y: a.y
            width: widget.width
            height: widget.height
            radius: 18
            color: Qt.rgba(root.cPrimary.r, root.cPrimary.g, root.cPrimary.b, 0.06)
            border.width: 2
            border.color: Qt.rgba(root.cPrimary.r, root.cPrimary.g, root.cPrimary.b, 0.55)
        }

        Repeater {
            model: 9
            delegate: Rectangle {
                required property int index
                readonly property var a: root.anchorPos(index)
                readonly property bool near: root.nearSnap === index
                visible: dragH.active
                width: near ? 18 : 10
                height: width
                radius: width / 2
                x: a.x + widget.width / 2 - width / 2
                y: a.y + widget.height / 2 - height / 2
                color: near ? root.cPrimary : Qt.rgba(root.cText.r, root.cText.g, root.cText.b, 0.35)
                Behavior on width { NumberAnimation { duration: 120 } }
            }
        }

        Item {
            id: widget
            width: root.widgetW
            height: root.widgetH
            opacity: root.shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 550; easing.type: Easing.OutCubic } }
            Behavior on x { enabled: root.snapAnimating; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: root.snapAnimating; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

            // Controls (lock / style panel) are visible only while hovering or picking.
            property real chrome: (hover.hovered || root.pickerOpen) ? 1 : 0
            Behavior on chrome { NumberAnimation { duration: 180 } }

            HoverHandler {
                id: hover
                cursorShape: (lockArea.containsMouse || fontArea.containsMouse) ? Qt.PointingHandCursor
                           : (saved.locked || root.pickerOpen) ? Qt.ArrowCursor : Qt.SizeAllCursor
            }

            DragHandler {
                id: dragH
                target: widget
                enabled: !saved.locked && !root.pickerOpen
                xAxis.minimum: 0
                xAxis.maximum: Math.max(0, win.width - widget.width)
                yAxis.minimum: 0
                yAxis.maximum: Math.max(0, win.height - widget.height)
                onActiveChanged: {
                    if (active) return;
                    const i = root.nearestAnchor(root.snapReach);
                    if (i >= 0) root.snapTo(i);
                    else { saved.snap = -1; root.persist(); }
                }
            }

            // ── Lyrics ──
            Item {
                id: lyricsLayer
                anchors.fill: parent

                // One soft shadow pass over the whole block keeps text readable on any wallpaper.
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: root.cShadow
                    shadowOpacity: 0.55
                    shadowBlur: 0.8
                    shadowVerticalOffset: 2
                    autoPaddingEnabled: true
                }

                NumberAnimation {
                    id: fadeIn
                    target: lyricsLayer
                    property: "opacity"
                    from: 0; to: 1
                    duration: 450
                    easing.type: Easing.OutCubic
                }

                // Scroll wheel / touchpad: browse the lyrics without touching playback.
                // A button-less MouseArea sitting above the list is the most reliable way to catch
                // wheel events here (the list itself is non-interactive), and it lets clicks and
                // drags pass straight through to the lines and the drag handler.
                MouseArea {
                    id: wheelCatcher
                    anchors.fill: parent
                    z: 10
                    acceptedButtons: Qt.NoButton
                    property real acc: 0
                    onWheel: wheel => {
                        const d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y * 3;
                        acc += d;
                        const s = Math.trunc(acc / 120);
                        if (s !== 0) { acc -= s * 120; root.browseBy(-s); }
                        wheel.accepted = true;
                    }
                }

                ListView {
                    id: list
                    anchors.fill: parent
                    model: root.lines
                    interactive: false
                    clip: true
                    cacheBuffer: 0
                    currentIndex: Math.max(0, root.viewIndex)
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    preferredHighlightBegin: height / 2 - (currentItem ? currentItem.height / 2 : 24)
                    preferredHighlightEnd: height / 2 + (currentItem ? currentItem.height / 2 : 24)
                    highlightMoveDuration: 650
                    highlightMoveVelocity: -1

                    delegate: Item {
                        id: line
                        required property int index
                        required property var modelData

                        readonly property real dist: index - root.activeIndex
                        // Past lines are "fully sung", future lines "not yet"; only the active line follows the playhead.
                        readonly property real ph: dist < 0 ? 1e9 : (dist > 0 ? -1e9 : root.playhead)

                        property real glowAmt: dist === 0 ? 1 : 0
                        // Fades with distance from whatever is centred (the playing line, or the
                        // line you've scrolled to).
                        property real prox: Math.max(0, 1 - Math.abs(index - root.viewIndex) * 0.27)
                        Behavior on glowAmt { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
                        Behavior on prox { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }

                        width: ListView.view.width
                        height: lay.height + 20
                        opacity: prox * (0.4 + 0.6 * glowAmt)
                        scale: 0.9 + 0.1 * glowAmt
                        transformOrigin: root.originFor(root.align)

                        // ── The wave ──
                        // Colour fill: a logistic ramp centred just after the word starts. Its width
                        // scales with the word length, so short words don't snap and long words
                        // don't drag, and neighbouring ramps always overlap.
                        function fillOf(w) {
                            const dur = Math.max(0.12, w.t1 - w.t0);
                            const k = (0.07 + dur * 0.4) * root.waveSpread;
                            const x = (ph - (w.t0 + dur * 0.35)) / k;
                            return 1 / (1 + Math.exp(-Math.max(-30, Math.min(30, x))));
                        }

                        // Wave front: a tighter bell on the word being sung right now (0..1). It tints the
                        // word with the second colour, so the wave is a clearly visible travelling
                        // highlight (accent) that leaves primary behind it.
                        function frontOf(w) {
                            const dur = Math.max(0.12, w.t1 - w.t0);
                            const x = ph - (w.t0 + w.t1) / 2;
                            const s = (0.09 + dur * 0.45) * root.waveSpread;
                            return Math.exp(-(x * x) / (2 * s * s)) * glowAmt;
                        }

                        // Glow: a bell curve centred on the word's midpoint. It swells before the word
                        // (wide rise, so the previous word is still glowing when this one begins) and
                        // settles to a soft afterglow after it. Both halves are Gaussians, so the
                        // curve has no kink at the peak and the glow slides from word to word.
                        function glowOf(w) {
                            const dur = Math.max(0.12, w.t1 - w.t0);
                            const x = ph - (w.t0 + w.t1) / 2;
                            let g;
                            if (x < 0) {
                                const s = (0.14 + dur * 0.8) * root.waveSpread;
                                g = Math.exp(-(x * x) / (2 * s * s));
                            } else {
                                const s = root.trailSeconds * 0.55 * root.waveSpread;
                                g = 0.3 + 0.7 * Math.exp(-(x * x) / (2 * s * s));
                            }
                            return g * glowAmt;
                        }

                        // Wrapped + aligned word positions for this line (re-evaluated when the
                        // font, size, weight, alignment or widget width change).
                        // Computed imperatively (not as a binding): the measuring objects are shared and
                        // get modified while measuring, which would otherwise create a binding loop.
                        property var lay: ({ pos: [], height: 32 })
                        function relayout() {
                            lay = root.layoutLine(modelData.words, width - 40,
                                root.fontFamily, root.fontSize, root.fontWeight, root.fontItalic, root.align);
                        }
                        Component.onCompleted: relayout()
                        onWidthChanged: relayout()

                        Connections {
                            target: root
                            function onFontFamilyChanged() { line.relayout(); }
                            function onFontSizeChanged() { line.relayout(); }
                            function onFontWeightChanged() { line.relayout(); }
                            function onFontItalicChanged() { line.relayout(); }
                            function onAlignChanged() { line.relayout(); }
                        }

                        // Click a line to jump to that point in the song. TapHandler (unlike a
                        // MouseArea) lets dragging the widget still work.
                        TapHandler {
                            enabled: !root.pickerOpen && line.modelData.t !== undefined
                            onTapped: root.seekTo(line.modelData.t)
                        }

                        // Every line is drawn word by word (inactive lines simply get no glow or colour).
                        Item {
                            id: overlay
                            anchors.fill: parent

                            // Glow: all words blurred in a single pass, each at its own opacity → smooth wave.
                            Item {
                                anchors.fill: parent
                                visible: line.glowAmt > 0.01
                                layer.enabled: visible
                                layer.effect: MultiEffect {
                                    blurEnabled: true
                                    blur: 1.0
                                    blurMax: root.glowBlur
                                    autoPaddingEnabled: true
                                }

                                Repeater {
                                    model: line.modelData.words
                                    delegate: Text {
                                        required property var modelData
                                        required property int index
                                        readonly property var p: line.lay.pos[index] || ({ x: 0, y: 0 })
                                        x: 20 + p.x
                                        y: 10 + p.y
                                        text: modelData.s
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fontSize
                                        font.weight: root.fontWeight
                                        font.italic: root.fontItalic
                                        renderType: Text.QtRendering
                                        color: root.mix(root.cPrimary, root.cAccent, line.frontOf(modelData))
                                        opacity: line.glowOf(modelData) * root.glowStrength
                                    }
                                }
                            }

                            // Crisp words: colour sweeps from text colour to primary as the wave passes.
                            Repeater {
                                model: line.modelData.words
                                delegate: Text {
                                    required property var modelData
                                    required property int index
                                    readonly property var p: line.lay.pos[index] || ({ x: 0, y: 0 })
                                    x: 20 + p.x
                                    y: 10 + p.y
                                    text: modelData.s
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    font.weight: root.fontWeight
                                    font.italic: root.fontItalic
                                    renderType: Text.QtRendering
                                    color: root.mix(root.mix(root.cText, root.cPrimary, line.fillOf(modelData) * line.glowAmt),
                                                    root.cAccent, line.frontOf(modelData))
                                }
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.status === "none"
                    opacity: 0.5
                    text: "♪  no synced lyrics"
                    color: root.cText
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(root.fontSize * 0.65)
                    font.weight: root.fontWeight
                    font.italic: root.fontItalic
                }
            }

            // ── Style panel (transient) ──
            Rectangle {
                id: picker
                // Sits beside the lyrics (never on top of them) so changes preview live.
                width: 380
                height: Math.min(460, win.height - 24)
                readonly property bool onLeft: widget.x >= width + 12
                                               || widget.x + widget.width + 12 + width > win.width
                x: onLeft ? -width - 12 : widget.width + 12
                y: Math.max(12, Math.min(win.height - 12 - height, widget.y)) - widget.y
                radius: 18
                color: Qt.rgba(root.cShadow.r, root.cShadow.g, root.cShadow.b, 0.92)
                opacity: root.pickerOpen ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Column {
                    id: controls
                    anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 12; leftMargin: 14; rightMargin: 14 }
                    spacing: 6

                    // Row 1: size, weight, italic, alignment
                    Flow {
                        width: parent.width
                        spacing: 6

                        Chip { label: "−"; accent: root.cPrimary; ink: root.cText; onClicked: root.setSize(root.fontSize - 2) }
                        Item {
                            width: 30
                            height: 26
                            Text {
                                anchors.centerIn: parent
                                text: root.fontSize
                                color: root.cText
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }
                        }
                        Chip { label: "+"; accent: root.cPrimary; ink: root.cText; onClicked: root.setSize(root.fontSize + 2) }
                        Chip { label: root.weightLabel; accent: root.cPrimary; ink: root.cText; onClicked: root.cycleWeight() }
                        Chip { label: "Italic"; on: root.fontItalic; accent: root.cPrimary; ink: root.cText; onClicked: root.toggleItalic() }
                        Chip { label: "Left"; on: root.align === Text.AlignLeft; accent: root.cPrimary; ink: root.cText; onClicked: root.setAlign(Text.AlignLeft) }
                        Chip { label: "Center"; on: root.align === Text.AlignHCenter; accent: root.cPrimary; ink: root.cText; onClicked: root.setAlign(Text.AlignHCenter) }
                        Chip { label: "Right"; on: root.align === Text.AlignRight; accent: root.cPrimary; ink: root.cText; onClicked: root.setAlign(Text.AlignRight) }
                    }

                    // Row 2: glow strength, wave softness, reset
                    Flow {
                        width: parent.width
                        spacing: 6

                        Chip { label: "Glow −"; accent: root.cPrimary; ink: root.cText; onClicked: root.setGlow(root.glowStrength - 0.1) }
                        Item {
                            width: 38
                            height: 26
                            Text {
                                anchors.centerIn: parent
                                text: Math.round(root.glowStrength * 100) + "%"
                                color: root.cText
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                        }
                        Chip { label: "+"; accent: root.cPrimary; ink: root.cText; onClicked: root.setGlow(root.glowStrength + 0.1) }
                        Chip { label: "Wave −"; accent: root.cPrimary; ink: root.cText; onClicked: root.setWave(root.waveSpread - 0.25) }
                        Item {
                            width: 34
                            height: 26
                            Text {
                                anchors.centerIn: parent
                                text: root.waveSpread.toFixed(2).replace(/0$/, "") + "×"
                                color: root.cText
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                        }
                        Chip { label: "+"; accent: root.cPrimary; ink: root.cText; onClicked: root.setWave(root.waveSpread + 0.25) }
                        Chip { label: "Accent: " + root.accentNames[saved.accentMode]; accent: root.cPrimary; ink: root.cText; onClicked: root.cycleAccent() }
                        Chip { label: "Reset"; accent: root.cPrimary; ink: root.cText; onClicked: root.resetStyle() }
                    }

                    // Snap position: 3x3 grid matching the 9 screen anchors
                    Row {
                        spacing: 10

                        Text {
                            height: snapGrid.height
                            verticalAlignment: Text.AlignVCenter
                            text: "Snap to"
                            color: root.cText
                            opacity: 0.7
                            font.pixelSize: 13
                        }

                        Grid {
                            id: snapGrid
                            columns: 3
                            spacing: 4

                            Repeater {
                                model: 9
                                delegate: Rectangle {
                                    required property int index
                                    width: 34
                                    height: 18
                                    radius: 6
                                    color: Qt.rgba(root.cPrimary.r, root.cPrimary.g, root.cPrimary.b,
                                                   saved.snap === index ? 0.55 : (cellArea.containsMouse ? 0.26 : 0.12))
                                    Behavior on color { ColorAnimation { duration: 120 } }

                                    MouseArea {
                                        id: cellArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.snapTo(index)
                                    }
                                }
                            }
                        }
                    }

                    // Row 3: font search / any font name
                    Row {
                        width: parent.width
                        spacing: 6

                        Rectangle {
                            id: searchBox
                            width: parent.width - (useChip.visible ? useChip.width + 6 : 0)
                            height: 28
                            radius: 14
                            color: Qt.rgba(root.cPrimary.r, root.cPrimary.g, root.cPrimary.b, 0.14)

                            TextInput {
                                id: search
                                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                verticalAlignment: TextInput.AlignVCenter
                                color: root.cText
                                selectionColor: root.cPrimary
                                selectedTextColor: root.cShadow
                                font.pixelSize: 14
                                clip: true
                                selectByMouse: true
                                onTextChanged: root.fontQuery = text
                                onAccepted: root.applySearch()
                                Keys.onEscapePressed: root.pickerOpen = false
                            }

                            Text {
                                anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 12 }
                                visible: search.text.length === 0
                                text: "Search or type any font name…"
                                color: root.cText
                                opacity: 0.5
                                font.pixelSize: 14
                            }
                        }

                        Chip {
                            id: useChip
                            visible: root.queryIsNew
                            height: 28
                            radius: 14
                            label: "Use “" + (root.fontQuery.trim().length > 14 ? root.fontQuery.trim().slice(0, 14) + "…" : root.fontQuery.trim()) + "”"
                            accent: root.cPrimary
                            ink: root.cText
                            onClicked: root.setFont(root.fontQuery.trim())
                        }
                    }
                }

                ListView {
                    id: fontView
                    anchors {
                        top: controls.bottom
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        topMargin: 8
                        leftMargin: 14
                        rightMargin: 14
                        bottomMargin: 12
                    }
                    clip: true
                    model: root.shownFonts
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Item {
                        id: row
                        required property string modelData
                        readonly property bool current: modelData === root.fontFamily

                        width: ListView.view.width
                        height: 34

                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            color: Qt.rgba(root.cPrimary.r, root.cPrimary.g, root.cPrimary.b,
                                           row.current ? 0.22 : (rowArea.containsMouse ? 0.12 : 0))
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        Text {
                            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 12 }
                            width: parent.width - 24
                            text: row.modelData
                            elide: Text.ElideRight
                            color: row.current ? root.cPrimary : root.cText
                            font.family: row.modelData
                            font.pixelSize: 18
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.setFont(row.modelData)
                        }
                    }
                }
            }

            // ── Hover-only controls: style panel + lock / unlock ──
            Item {
                id: lockBtn
                width: 26
                height: 26
                anchors { top: parent.top; right: parent.right; margins: 6 }
                opacity: widget.chrome * (lockArea.containsMouse ? 1 : 0.7)
                visible: opacity > 0.01

                readonly property color ink: saved.locked ? root.cPrimary : root.cText

                Rectangle {
                    width: 10
                    height: 12
                    radius: 5
                    color: "transparent"
                    border.width: 2
                    border.color: lockBtn.ink
                    x: (parent.width - width) / 2 + (saved.locked ? 0 : 3)
                    y: saved.locked ? 3 : -1
                    Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                    Behavior on y { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                }

                Rectangle {
                    width: 16
                    height: 11
                    radius: 3
                    color: lockBtn.ink
                    x: (parent.width - width) / 2
                    y: 12
                }

                MouseArea {
                    id: lockArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.toggleLock()
                }
            }

            Item {
                id: fontBtn
                width: 26
                height: 26
                anchors { top: parent.top; right: lockBtn.left; topMargin: 6; rightMargin: 2 }
                opacity: widget.chrome * (fontArea.containsMouse ? 1 : 0.7)
                visible: opacity > 0.01

                Text {
                    anchors.centerIn: parent
                    text: "Aa"
                    color: root.pickerOpen ? root.cPrimary : root.cText
                    font.pixelSize: 14
                    font.weight: Font.Bold
                }

                MouseArea {
                    id: fontArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.togglePicker()
                }
            }
        }
    }
}
