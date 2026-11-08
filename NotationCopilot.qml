// Notation Copilot -- MuseScore 4 plugin, chat-sidebar edition.
// Author: AiHud (https://copilot.aihud.net, hi@aihud.net)
// Copyright (C) 2026 AiHud. Licensed under the GNU GPL v3 or later:
// https://copilot.aihud.net/LICENSE  Source: https://copilot.aihud.net/source
//
// DOCKING: MuseScore Studio 4.7.5 cannot dock plugins. The legacy loader maps
// pluginType "dock" to the same floating dialog as "dialog" (verified empirically
// 2026-10-22), and PluginAPI.dockArea is a deprecated no-op. Real docked panels were
// only added to MuseScore's master branch in Oct 2026 (muse_framework ExtensionPanel,
// pluginType "dock"); this file already declares pluginType "dock", so on such a
// build it should dock automatically. On 4.7.x the window instead re-positions itself
// as a full-height sidebar flush with the right edge of the MuseScore window and
// stays open across requests (it is non-modal).
//
// Flow per message: export the OPEN score to MusicXML -> hosted mode: POST it to
// <serverUrl>/v1/edit with the AiHud key (XMLHttpRequest); local mode: run copilot.py via a
// launcher script (QProcess.startWithArgs, non-blocking, polled) -> show reply / clarifying
// question with option buttons -> apply the returned edit list IN PLACE to the open score
// inside one startCmd()/endCmd(), so a single Ctrl+Z undoes the whole request. Every request
// re-exports the score, so follow-ups build on it, including any manual edits.
//
// Install: copy into ~/Documents/MuseScore4/Plugins/NotationCopilot/, restart MuseScore,
// Home > Plugins > Notation Copilot > Enable. Run: Plugins > Composing/arranging tools > Notation Copilot.
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.15
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    id: root
    version: "0.8.3"
    title: "Bach AI"
    description: "Ask in plain language (any language) and the AI edits the open score: write melodies, scales, exercises and countermelodies, copy or clear bars, add dynamics and chord symbols, voice sections, write pads and bass lines. One Ctrl+Z undoes each request."
    categoryCode: "composing-arranging-tools"
    pluginType: "dock"
    requiresScore: true
    width: 400; height: 760

    // ---- Nzumari connection ----
    property string mode: "local"
    property string serverUrl: "https://nzumari.vivaceke.co.ke"
    property string apiKey: ""                 // scoped Nzumari device token
    property string pairingDeviceCode: ""
    property string bachConversationId: ""
    property string python: "python"
    property string copilot: "C:/Users/user/Documents/MuseScore4/Plugins/VivaceCopilot/copilot.py"
    property string workDir: ""
    property int sidebarWidth: 400

    // Conversation state for the request in flight.
    property string instruction: ""      // original request text
    property var history: []             // [{question, answer}] for the request in flight
    property string pendingQuestion: ""
    property string pendingKind: ""      // "clarify" | "confirm" | ""
    property bool busy: false
    property var job: ({})
    property int elapsed: 0
    // First-open example prompts: shown until the first request is sent, again after "New chat" or a score
    // switch (click fills the box, never sends). Each names bars: a bar-less request gets a "which bars?" question.
    property int sentCount: 0
    readonly property var examples: ["Add a simple piano accompaniment to bars 1-8",
                                     "Transpose the flute part up a major second in bars 1-8",
                                     "Add chord symbols to the melody in bars 1-8",
                                     "Double the melody in the strings in bars 1-8"]
    readonly property bool showExamples: sentCount === 0 && !busy && !needActivation && apiKey !== ""
    // 402 error=activate: show the "enter your 6-digit code / resend the email" box above the input.
    property bool needActivation: false
    property bool actBusy: false
    property string planLine: ""         // 0.8.1: "Pro · 143 edits left" from the server's `account` block
    property string manageUrl: ""        // signed account page (plan, usage, cancel)
    property string lastBlocked: ""      // request that hit the 402; put back in the box after activation

    readonly property color cBg: "#f7f8fa"
    readonly property color cUser: "#0b6bcb"
    readonly property color cBot: "#ffffff"
    readonly property color cBorder: "#d9dde3"
    readonly property color cText: "#1f2328"
    readonly property color cMuted: "#656d76"
    readonly property color cBorderLight: "#e9ecf0"
    readonly property color cInputBg: "#fafbfc"

    QProcess { id: proc }
    FileIO { id: fio }
    ListModel { id: chat }

    // ---------- sidebar placement (MS 4.7 has no docking for plugins) ----------
    Timer {
        id: placeTimer; interval: 300; repeat: true; property int tries: 0
        onTriggered: { tries++; if (placeSidebar() || tries > 10) stop() }
    }
    function placeSidebar() {
        var w = root.Window.window
        if (!w) return false
        var p = w.transientParent
        var x0, y0, ww, hh
        if (p && p.width > 0) { x0 = p.x; y0 = p.y; ww = p.width; hh = p.height }
        else { x0 = w.screen.virtualX; y0 = w.screen.virtualY
               ww = w.screen.desktopAvailableWidth; hh = w.screen.desktopAvailableHeight }
        var top = 108   // keep the menu bar + toolbars of the main window visible
        w.width = sidebarWidth
        w.height = Math.max(400, hh - top)
        w.x = x0 + ww - sidebarWidth
        w.y = y0 + top
        root.width = w.width; root.height = w.height   // content follows the window
        console.log("copilot sidebar placed at " + w.x + "," + w.y + " " + w.width + "x" + w.height
                    + (p ? " (main window " + ww + "x" + hh + ")" : " (screen)"))
        return true
    }

    // Switching to another (e.g. new) score shows the example prompts again.
    property string lastScoreName: ""
    onScoreStateChanged: {
        var n = curScore ? String(curScore.scoreName) : ""
        if (n !== lastScoreName) { if (lastScoreName !== "" && !busy) sentCount = 0; lastScoreName = n }
    }

    onRun: {
        lastScoreName = curScore ? String(curScore.scoreName) : ""
        if (mode === "hosted" && apiKey === "") loadKey()
        sayHello()
        if (mode === "hosted" && apiKey === "") askForKey()
        else say("bot", "Hi! Ask me for anything in the open score, in your own words, e.g. \"write a simple 4-bar melody in bars 1-4\", "
            + "\"repeat bars 1-4 in bars 5-8\", \"add chord symbols Am G Am E7 to bars 1-4\" or "
            + "\"voice the alto 1 melody in bars 9-16 for the saxes\". I only touch what you ask for.", "", "")
        placeTimer.start()
    }

    // One "plugin opened" ping per window open (and once more when a key is pasted): plugin version +
    // MuseScore version, with the key in the Authorization header (never in the URL) so the server can
    // count opens per account. No score content. Fire and forget: the reply and any error are ignored.
    function msVersion() {
        try {
            if (typeof mscoreMajorVersion !== "undefined")
                return mscoreMajorVersion + "." + mscoreMinorVersion + "." + mscoreUpdateVersion
        } catch (e) { }
        return ""
    }
    function sayHello() {
        if (mode !== "hosted") return
        try {
            var x = new XMLHttpRequest()
            x.open("POST", serverUrl.replace(/\/+$/, "") + "/v1/hello")
            x.setRequestHeader("Content-Type", "application/json")
            if (apiKey) x.setRequestHeader("Authorization", "Bearer " + apiKey)
            x.send(JSON.stringify({ v: root.version, ms: msVersion() }))
        } catch (e) { }
    }

    // ---------- AiHud key (hosted mode) ----------
    // Either set apiKey above, or paste the key into the chat once; it is saved to copilot-key.txt.
    // Saved next to this .qml: MuseScore 4.7 blocks plugin writes outside its allowed dirs (e.g. ~).
    // file:// URL -> local path on any OS: file:///C:/Users/x/Dokumente/a%20b.qml -> C:/Users/x/Dokumente/a b.qml,
    // file:///home/x/a.qml -> /home/x/a.qml, file://server/share/a -> //server/share/a (Windows network folder).
    function urlToPath(u) {
        var s = String(u)
        if (/^file:\/\/\//i.test(s)) s = s.substring(7)          // "/C:/..." or "/home/..."
        else if (/^file:\/\//i.test(s)) s = "//" + s.substring(7) // UNC
        else if (/^file:/i.test(s)) s = s.substring(5)
        try { s = decodeURIComponent(s) } catch (e) { }
        if (/^\/[A-Za-z]:/.test(s)) s = s.substring(1)              // Windows drive letter
        return s
    }
    // This plugin's folder (Documents/MuseScore4/Plugins/NotationCopilot), with a trailing "/".
    function pluginDir() { var d = urlToPath(Qt.resolvedUrl(".")); return /\/$/.test(d) ? d : d + "/" }
    // Where the hosted-mode export goes: the plugin folder; if that is not writable (probe with FileIO,
    // which fails silently -- writeScore would pop MuseScore's "retry?" dialog), the system temp folder.
    function exportPath() {
        var cands = [pluginDir()]
        try { var t = String(fio.tempPath() || "").replace(/\\/g, "/"); if (t !== "") cands.push(/\/$/.test(t) ? t : t + "/") } catch (e) { }
        for (var i = 0; i < cands.length; i++) {
            fio.source = cands[i] + "copilot-export.musicxml"
            if (fio.write("")) return fio.source
        }
        return cands[0] + "copilot-export.musicxml"
    }
    function keyPath() { return pluginDir() + "copilot-key.txt" }
    function loadKey() {
        fio.source = keyPath()
        if (fio.exists()) { var k = String(fio.read()).trim(); if (/^nc_live_[A-Za-z0-9_-]{8,}$/.test(k)) apiKey = k }
    }
    function askForKey() {
        say("bot", "Welcome to Bach AI! To start, paste your Dahl API key (set it in your env file) "
            + "here and press Enter.\n\nNo key yet? Get a free one (100-edit trial, then 10 a month) at " + serverUrl, "", "")
    }

    // ---------- UI ----------
    Rectangle {
        anchors.fill: parent; color: cBg

        Rectangle {   // header
            id: header; anchors { left: parent.left; right: parent.right; top: parent.top }
            height: planLine !== "" ? 54 : 40; color: "#ffffff"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: cBorder }
            Text { id: titleText; anchors { left: parent.left; leftMargin: 12; verticalCenter: planLine !== "" ? undefined : parent.verticalCenter
                                                   top: planLine !== "" ? parent.top : undefined; topMargin: 10 }
                   text: "BACH AI"; font.bold: true; font.pixelSize: 12; font.letterSpacing: 1; color: cText }
            Text {   // plan + edits left (server `account` block); click = account page
                id: planText; visible: planLine !== ""; text: planLine; font.pixelSize: 11; color: cMuted
                font.underline: manageUrl !== "" && planMouse.containsMouse
                anchors { left: parent.left; leftMargin: 12; top: titleText.bottom; topMargin: 3 }
                MouseArea { id: planMouse; anchors.fill: parent; hoverEnabled: true
                            cursorShape: manageUrl !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (manageUrl !== "") Qt.openUrlExternally(manageUrl) }
            }
            Row {
                anchors { right: parent.right; rightMargin: 8; top: parent.top; topMargin: 4 } spacing: 4
                Button { text: apiKey === "" ? "Connect" : "Connected"; flat: true; font.pixelSize: 11
                         enabled: !busy && apiKey === ""; onClicked: beginPairing() }
                Button { text: "New chat"; flat: true; font.pixelSize: 11; enabled: !busy
                         onClicked: { chat.clear(); resetRequest(); bachConversationId = ""; sentCount = 0
                                      say("bot", "New Bach conversation. Tell me what to change in the open score.", "", "") } }
                Button { text: "Close"; flat: true; font.pixelSize: 11; onClicked: root.quit() }
            }
        }

        ListView {
            id: list
            anchors { left: parent.left; right: parent.right; top: header.bottom
                      bottom: showExamples ? examplesBox.top : (needActivation ? actBox.top : composer.top); margins: 10 }
            clip: true; spacing: 10; model: chat
            ScrollBar.vertical: ScrollBar {}
            onCountChanged: Qt.callLater(function() { list.positionViewAtEnd() })
            delegate: Item {
                id: row
                width: list.width
                height: bubble.height + (who.visible ? who.height + 10 : 0)
                property bool mine: model.role === "user"
                property var opts: model.opts === "" ? [] : model.opts.split("\n")
                property string msgTime: Qt.formatTime(new Date(), "hh:mm")

                Text { id: who; visible: model.role !== "status"; text: mine ? "You" : "Copilot"
                       font.pixelSize: 10; font.bold: true; color: cMuted
                       anchors.right: mine ? parent.right : undefined; anchors.left: mine ? undefined : parent.left
                       anchors.top: parent.top; anchors.topMargin: mine ? 0 : 2 }

                Text { id: timeStamp; visible: model.role !== "status"; text: msgTime
                       font.pixelSize: 9; font.bold: true; color: cMuted
                       opacity: 0.6
                       anchors.right: mine ? parent.right : undefined; anchors.left: mine ? undefined : parent.left
                       anchors.top: who.bottom; anchors.topMargin: 2 }

                Rectangle {
                    id: bubble
                    y: who.visible ? timeStamp.bottom + 4 : 0
                    width: Math.min(list.width - (mine ? 52 : 12), Math.max(body.implicitWidth, 60) + 24)
                    height: col.height + 18
                    anchors.right: mine ? parent.right : undefined
                    anchors.left: mine ? undefined : parent.left
                    anchors.leftMargin: mine ? 0 : 12
                    radius: 10
                    color: mine ? cUser : (model.role === "status" ? "transparent"
                           : (model.role === "error" ? "#fff1f0" : (model.kind !== "" ? "#fffbf0" : cBot)))
                    border.color: mine ? "transparent" : (model.role === "error" ? "#f5c2c0" : (model.kind !== "" ? "#f0d58c" : cBorderLight))
                    border.width: mine ? 0 : 1

                    Column {
                        id: col; x: 12; y: 9; width: bubble.width - 24; spacing: 6
                        Text { id: body; width: Math.min(implicitWidth, list.width - 72 - (mine ? 52 : 0))
                               text: model.text; wrapMode: Text.Wrap; textFormat: Text.PlainText
                               font.pixelSize: 13; font.italic: model.role === "status"
                               color: mine ? "#ffffff" : (model.role === "status" ? cMuted : cText) }
                        Text { visible: model.detail !== ""; width: body.width; text: model.detail
                               wrapMode: Text.Wrap; font.pixelSize: 10; font.family: "Consolas, 'Courier New', monospace"; color: cMuted
                               opacity: 0.8 }
                        Repeater {
                            model: row.opts
                            delegate: Button {
                                width: col.width; enabled: row.isLive() && !busy
                                contentItem: Text { text: modelData; wrapMode: Text.Wrap; font.pixelSize: 12
                                                    color: parent.enabled ? cUser : cMuted }
                                onClicked: pickOption(modelData)
                            }
                        }
                        Button {   // 402: open the buy-credits page in the browser
                            visible: model.url !== ""; text: "Upgrade / buy edits"; highlighted: true
                            onClicked: Qt.openUrlExternally(model.url)
                        }
                        Row {
                            spacing: 8; visible: model.kind !== "" && row.isLive()
                            Button { text: "Apply anyway"; highlighted: true; enabled: !busy
                                     onClicked: forceApply() }
                            Button { text: "Cancel"; flat: true; enabled: !busy
                                     onClicked: { resetRequest(); say("status", "Request cancelled.", "", "") } }
                        }
                    }
                }
                function isLive() { return model.live && pendingKind !== "" }
            }
        }

        Column {   // first-open example prompts
            id: examplesBox
            visible: showExamples
            anchors { left: parent.left; right: parent.right; bottom: composer.top
                      leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
            spacing: 8
            Text { text: "Try one of these:"; font.pixelSize: 12; font.bold: true; color: cMuted }
            Row {
                spacing: 8
                Repeater {
                    model: examples
                    delegate: Button {
                        width: (examplesBox.width - 24) / 3
                        height: 44
                        contentItem: Text { text: modelData; wrapMode: Text.Wrap; font.pixelSize: 11; color: cUser }
                        background: Rectangle {
                            color: parent.pressed ? "#eef2f6" : cInputBg
                            radius: 10
                            border.color: cBorderLight
                            border.width: 1
                        }
                        onClicked: useExample(modelData)
                    }
                }
            }
        }

        Rectangle {   // activation: 6-digit code from the email, or resend the email (402 error=activate)
            id: actBox
            visible: needActivation
            anchors { left: parent.left; right: parent.right; bottom: composer.top
                      leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
            height: actCol.height + 16; radius: 8; color: "#fffbeb"; border.color: "#fde68a"
            Column {
                id: actCol; x: 8; y: 8; width: parent.width - 16; spacing: 6
                Text { width: parent.width; wrapMode: Text.Wrap; font.pixelSize: 12; font.bold: true; color: cText
                       text: "Activate your free edits: type the 6-digit code from the email we sent you." }
                Row {
                    spacing: 6
                    TextField {
                        id: codeInput; width: 120; placeholderText: "123456"; enabled: !actBusy
                        maximumLength: 7; inputMethodHints: Qt.ImhDigitsOnly; font.pixelSize: 15
                        onAccepted: submitCode()
                    }
                    Button { text: "Activate"; highlighted: true; onClicked: submitCode()
                             enabled: !actBusy && codeInput.text.replace(/\D/g, "").length === 6 }
                }
                Button { text: "Resend activation email"; flat: true; enabled: !actBusy; onClicked: resendActivation() }
            }
        }

        Rectangle {   // composer
            id: composer
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
            height: input.height + 46; radius: 10; color: cInputBg
            border.color: input.activeFocus ? cUser : cBorderLight
            border.width: 1

            Rectangle {
                anchors { fill: input; margins: -6 }
                radius: 10
                color: "#ffffff"
                border.color: input.activeFocus ? cUser : cBorderLight
                border.width: 1
            }

            TextArea {
                id: input
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                height: Math.min(Math.max(contentHeight + 12, 40), 120)
                wrapMode: TextEdit.Wrap; font.pixelSize: 13; enabled: !busy
                background: null
                placeholderText: pendingKind === "clarify" ? "Answer the question, or click an option above"
                                                           : "Ask Copilot to change the score (Enter to send)"
                Keys.onPressed: function(e) {
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                        e.accepted = true; send()
                    }
                }
            }

            Text { anchors { left: parent.left; leftMargin: 10; bottom: parent.bottom; bottomMargin: 10 }
                   font.pixelSize: 11; color: cMuted
                   text: busy ? "Working" + ".".repeat(1 + elapsed % 3) + "  " + elapsed + "s"
                              : "Edits apply to the open score (Ctrl+Z undoes)" }

            Button {
                anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 8 }
                text: pendingKind === "clarify" ? "Answer" : "Send"; highlighted: true
                enabled: !busy && input.text.trim() !== ""
                onClicked: send()
            }
        }
    }

    // ---------- conversation logic ----------
    function updatePlan(a) {
        var name = a.plan_name || ""
        if (a.edits_left !== undefined && a.edits_left !== null && a.limit)
            planLine = name + " \u00b7 " + a.edits_left + " of " + a.limit + " edits left"
        else
            planLine = name
        manageUrl = (a.manage_url && /^https:\/\//.test(a.manage_url)) ? a.manage_url : ""
    }

    function say(role, text, kind, opts, detail, url) {
        for (var i = 0; i < chat.count; i++) chat.setProperty(i, "live", false)
        chat.append({ role: role, text: text, kind: kind || "", opts: opts || "",
                      detail: detail || "", live: (kind || "") !== "", url: url || "" })
    }
    // Example chip: fill the box (user may change the bar numbers), focus it, cursor at the end. Never sends.
    function useExample(t) {
        input.text = t
        input.forceActiveFocus()
        input.cursorPosition = input.text.length
    }
    function resetRequest() { instruction = ""; history = []; pendingQuestion = ""; pendingKind = "" }
    function addAnswer(a) { var h = history.slice(); h.push({ question: pendingQuestion, answer: a }); history = h }
    function historyArgs() {
        var s = ""
        for (var i = 0; i < history.length; i++)
            s += " --question " + shq(history[i].question) + " --answer " + shq(history[i].answer)
        return s
    }
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function send() {
        var t = input.text.trim()
        if (t === "" || busy) return
        input.text = ""
        if (/^nc_live_[A-Za-z0-9_-]{8,}$/.test(t)) {      // the user pasted their key
            apiKey = t
            fio.source = keyPath()
            var saved = fio.write(t)
            sayHello()
            say("user", t.substring(0, 12) + "...", "", "")
            say("bot", "Key " + (saved ? "saved" : "set for this session") + ". Now tell me what to change in this score, "
                + "e.g. \"write a sustained string pad under bars 9-16\".", "", "")
            return
        }
        say("user", t, "", "")
        if (mode === "hosted" && apiKey === "") { askForKey(); return }
        if (needActivation && /^\d{3} ?\d{3}$/.test(t)) { codeInput.text = t; submitCode(); return }
        sentCount++
        if (pendingKind === "clarify") {
            addAnswer(t)
            runCopilot(false)
        } else {
            resetRequest(); instruction = t; runCopilot(false)
        }
    }
    function pickOption(o) {
        if (/e\.g\./.test(o)) {           // template option: let the user fill it in
            var m = /"([^"]+)"/.exec(o)
            input.text = m ? m[1] : ""; input.forceActiveFocus(); input.cursorPosition = input.text.length
            return
        }
        say("user", o, "", "")
        addAnswer(o)
        runCopilot(false)
    }
    function forceApply() {
        say("user", "Apply anyway", "", "")
        if (pendingKind === "clarify")
            addAnswer("No more detail; use your best judgement.")
        runCopilot(true)
    }

    function runCopilot(force) {
        if (!curScore) { say("error", "Open a score first.", "", ""); return }
        var target = curScore.scoreName
        if (mode === "hosted") {
            // One fixed file (plugin folder, else system temp; see exportPath), overwritten each
            // request and deleted after upload. No hard-coded Unix paths, no shell commands.
            var src = exportPath()
            // always export the OPEN score: follow-ups see earlier edits and manual changes
            if (!writeScore(curScore, src, "musicxml")) {
                say("error", "Could not export the score. I tried to save a temporary copy here:\n" + src
                    + "\n\nPlease check that this folder exists and that you are allowed to write to it. "
                    + "If it keeps happening, reinstall the plugin into your Documents\\MuseScore4\\Plugins folder "
                    + "(the NotationCopilot folder goes inside Plugins) and restart MuseScore.", "", "")
                return
            }
            postHosted(src, "", force, target); return
        }
        // ---- local (developer) mode, Linux/macOS ----
        var stamp = Date.now()
        var wd = workDir !== "" ? workDir.replace(/\/+$/, "") + "/" : pluginDir()
        if (workDir !== "") { proc.startWithArgs("mkdir", ["-p", wd]); proc.waitForFinished(5000) }
        src = wd + "in-" + stamp + ".musicxml"
        var dst = wd + "out-" + stamp + ".musicxml"
        var rep = wd + "report-" + stamp + ".json"
        var done = wd + "done-" + stamp
        if (!writeScore(curScore, src, "musicxml")) {
            say("error", "Could not export the score to " + src + ".", "", ""); return
        }
        var sh = wd + "run-" + stamp + ".sh"
        fio.source = sh
        fio.write("[ -f " + shq(envFile) + " ] && { set -a; . " + shq(envFile) + "; set +a; }\n"
                  + shq(python) + " " + shq(copilot) + " " + shq(src) + " " + shq(instruction)
                  + historyArgs() + (force ? " --yes" : "") + " -o " + shq(dst) + " > " + shq(rep) + " 2>&1\n"
                  + "echo $? > " + shq(done) + "\n")
        console.log("copilot launcher: " + sh)
        job = { rep: rep, dst: dst, done: done, hosted: false, target: target }
        busy = true; elapsed = 0
        proc.startWithArgs("sh", [sh])
        poll.start()
    }

    // ---------- activation (hosted mode) ----------
    function actPost(path, body, done) {
        actBusy = true
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            actBusy = false
            var r = null
            try { r = JSON.parse(x.responseText) } catch (e) { r = null }
            done(x.status, r || {})
        }
        x.open("POST", serverUrl.replace(/\/+$/, "") + path)
        x.setRequestHeader("Content-Type", "application/json")
        x.send(JSON.stringify(body))
    }
    function submitCode() {
        var c = codeInput.text.replace(/\D/g, "")
        if (c.length !== 6 || actBusy) return
        actPost("/v1/activate", { key: apiKey, code: c }, function(st, r) {
            if (st === 0) { say("error", "Could not reach the Copilot service at " + serverUrl + ".", "", ""); return }
            if (r.ok) {
                needActivation = false; codeInput.text = ""
                say("bot", r.message || "Activated.", "", "")
                if (lastBlocked !== "" && input.text === "") { input.text = lastBlocked; input.forceActiveFocus() }
                lastBlocked = ""
            } else say("error", r.message || ("Activation failed (HTTP " + st + ")."), "", "")
        })
    }
    function resendActivation() {
        if (actBusy) return
        actPost("/v1/resend-activation", { key: apiKey }, function(st, r) {
            if (st === 0) { say("error", "Could not reach the Copilot service at " + serverUrl + ".", "", ""); return }
            if (r.result === "already") needActivation = false
            say(r.ok ? "bot" : "error", r.message || ("Could not resend (HTTP " + st + ")."), "", "")
        })
    }

    Timer {
        id: poll; interval: 1000; repeat: true
        onTriggered: {
            elapsed++
            if (job.hosted) {
                if (elapsed > requestTimeoutSec && job.xhr) {
                    var x = job.xhr; job.xhr = null; x.abort(); stop(); busy = false
                    say("error", "The Copilot service did not answer within " + requestTimeoutSec + "s.", "", "")
                    resetRequest()
                }
                return
            }
            fio.source = job.done
            if (!fio.exists()) {
                if (elapsed > 300) { stop(); busy = false; say("error", "Copilot timed out.", "", "") }
                return
            }
            stop(); busy = false
            var rc = parseInt(fio.read())
            fio.source = job.rep
            handleReport(fio.read(), rc)
        }
    }

    // ---------- hosted mode ----------
    function postHosted(src, dst, force, target) {
        if (apiKey === "") { askForKey(); return }
        fio.source = src
        var xml = fio.read()
        try { fio.remove() } catch (e) { }                  // don't leave score copies lying around
        if (!xml || xml.length < 50) { say("error", "Could not read the exported score.", "", ""); return }
        xml = String(xml).replace(/>\n[ \t]*</g, "><")     // drop indentation: ~30% smaller upload
        var xhr = new XMLHttpRequest()
        job = { dst: dst, hosted: true, xhr: xhr, target: target }
        busy = true; elapsed = 0; poll.start()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || job.xhr !== xhr) return
            job.xhr = null; poll.stop(); busy = false
            handleHosted(xhr.status, xhr.responseText)
        }
        xhr.open("POST", serverUrl.replace(/\/+$/, "") + "/v1/edit")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + apiKey)
        xhr.send(JSON.stringify({ musicxml: xml, instruction: instruction, history: history, yes: !!force,
                                  inplace: true, plugin: root.version }))
        console.log("copilot hosted request -> " + serverUrl + " (" + xml.length + " bytes)")
    }

    function handleHosted(httpStatus, txt) {
        var r = null
        try { r = JSON.parse(txt) } catch (e) { r = null }
        if (!r) {
            say("error", httpStatus === 0 ? "Could not reach the Copilot service at " + serverUrl + "."
                       : httpStatus === 413 ? "This score is too large for the Copilot service."
                                            : "Unexpected reply from the Copilot service (HTTP " + httpStatus + ").",
                "", "", String(txt || "").slice(0, 800))
            resetRequest(); return
        }
        var rep = r.report || {}
        if (r.account) updatePlan(r.account)
        var cost = r.usage ? "\n(" + (r.usage.latency_ms / 1000).toFixed(1) + "s, " + r.usage.credits + " credits)" : ""
        if (r.status === "question") {
            pendingKind = r.kind || "clarify"; pendingQuestion = r.question
            if (pendingKind === "confirm")
                say("bot", r.question, "confirm", "", (r.options || []).join("\n"))
            else
                say("bot", r.question, "clarify", (r.options || []).join("\n"))
            return
        }
        if (r.status === "error") {
            if (r.error === "activate") {
                needActivation = true
                if (!r.no_email_help) lastBlocked = instruction
            }
            say("error", rep.message || ("Error (HTTP " + httpStatus + ")."), "", "", "", rep.buy_url || "")
            resetRequest(); return
        }
        if (r.status === "applied") finishApplied(rep, r.edits || [], r.edit_notes || [], cost, r.edit_summary, r.buy_url || "")
        else say("bot", rep.message || "Nothing to change.", "", "", logText(rep) + cost)
        resetRequest()
    }

    function handleReport(txt, rc) {
        var rep = null
        var j = txt.search(/^\{/m)
        if (j >= 0) { try { rep = JSON.parse(txt.substring(j)) } catch (e) { rep = null } }
        var head = (j >= 0 ? txt.substring(0, j) : txt).trim()

        if (rep && rep.status === "question") {
            pendingKind = rep.kind; pendingQuestion = rep.question
            var opts = (rep.options || []).join("\n")
            if (rep.kind === "confirm")
                say("bot", rep.question, "confirm", "", (rep.options || []).join("\n"))
            else
                say("bot", rep.question, "clarify", opts)
            return
        }
        if (rc !== 0 || !rep) {
            say("error", "Something went wrong (exit " + rc + ").", "", "", txt.slice(-1500))
            resetRequest(); return
        }
        if (rep.status === "applied") finishApplied(rep, rep.edits || [], rep.edit_notes || [], "", rep.edit_summary)
        else say("bot", rep.message || head || "Nothing to change.", "", "", logText(rep))
        resetRequest()
    }

    function logText(rep) { return (rep.log || []).map(function(l) { return "- " + l }).join("\n") }

    function finishApplied(rep, edits, notes, cost, summary, buyUrl) {
        if (!curScore || curScore.scoreName !== job.target) {
            say("error", "The score \"" + job.target + "\" is no longer the active score, so nothing was changed. "
                + "Switch back to it and ask again.", "", ""); return
        }
        if (!edits.length) { say("error", "The service returned no edits to apply; nothing was changed.", "", ""); return }
        var res = applyEdits(edits)
        if (res.error) {
            say("error", "Could not apply the change in place (" + res.error + "); the score was left unchanged.",
                "", "", logText(rep)); return
        }
        var where = []
        var ch = summary || rep.changed || {}
        for (var k in ch) where.push(k.replace(/<\/?sym>|accidental/g, "").replace(/Flat/g, "♭").replace(/Sharp/g, "♯")
                                     + (/^\d/.test(String(ch[k])) ? " bars " : " ") + ch[k])
        var msg = "Changed " + (where.length ? where.join("; ") : (rep.message || "the score"))
        var extra = notes.concat(res.problems)
        say("bot", msg + " — Ctrl+Z to undo." + (extra.length ? "\nNote: " + extra.join("; ") + "." : ""),
            "", "", logText(rep) + cost, buyUrl || "")
    }

    // ---------- in-place edits (see edits.py for the op format) ----------
    readonly property int tpq: 480
    function gcd(a, b) { return b ? gcd(b, a % b) : a }
    function setDur(c, ticks) { var g = gcd(ticks, tpq * 4); c.setDuration(ticks / g, tpq * 4 / g) }
    function frac(ticks) { var g = gcd(ticks, tpq * 4); return fraction(ticks / g, tpq * 4 / g) }
    function normName(s) {
        return String(s || "").toLowerCase().replace(/<\/?sym>/g, "").replace(/accidentalflat|♭/g, "b")
            .replace(/accidentalsharp|♯/g, "#").replace(/[^a-z0-9#]/g, "")
    }
    function staffOf(op) {
        var p = curScore.parts[op.part]
        if (!p) throw "part " + (op.part + 1) + " not found"
        if (p.longName && op.name && normName(p.longName) !== normName(op.name))
            throw "part " + (op.part + 1) + " is \"" + p.longName + "\", expected \"" + op.name + "\""
        return p.startTrack / 4 + op.staff
    }
    // cursor on `track` at `tick`, even in an empty voice (rewind on voice 1, then switch track)
    function cursorAt(track, tick) {
        var c = curScore.newCursor()
        c.track = track - track % 4
        c.rewindToTick(tick)
        c.track = track
        return c
    }
    function sortedPitches(ch) {
        var a = []
        for (var i = 0; i < ch.notes.length; i++) a.push(ch.notes[i].pitch)
        return a.sort(function(x, y) { return x - y })
    }
    function samePitches(ch, ps) { return sortedPitches(ch).join(",") === ps.slice().sort(function(x, y) { return x - y }).join(",") }
    // chord on `staff` at `tick` (any voice) with these concert pitches
    function findChord(staff, tick, ps, grace) {
        for (var v = 0; v < 4; v++) {
            var c = curScore.newCursor(); c.track = staff * 4 + v; c.rewindToTick(tick)
            if (!c.segment || c.tick !== tick || !c.element || c.element.type !== Element.CHORD) continue
            var ch = c.element
            if (grace) {
                for (var g = 0; g < ch.graceNotes.length; g++)
                    if (samePitches(ch.graceNotes[g], ps)) return ch.graceNotes[g]
            } else if (samePitches(ch, ps)) return ch
        }
        return null
    }
    function voiceHasChords(track, t0, t1) {
        var c = curScore.newCursor(); c.track = track; c.rewindToTick(t0)
        while (c.segment && c.tick < t1) {
            if (c.tick >= t0 && c.element && c.element.type === Element.CHORD) return true
            if (!c.next()) break
        }
        return false
    }
    function elementsIn(track, t0, t1) {
        var out = [], c = curScore.newCursor(); c.track = track; c.rewindToTick(t0)
        while (c.segment && c.tick < t1) {
            if (c.tick >= t0 && c.element) out.push(c.element)
            if (!c.next()) break
        }
        return out
    }
    function setSpelling(note, tpc) {
        var delta = note.tpc2 - note.tpc1          // the staff's transposition, as MuseScore spelled it
        note.tpc1 = tpc; note.tpc2 = tpc + delta
    }

    // Drum staves: MuseScore's addNote moves every note to the voice its drumset entry says (bass drum
    // and pedal hi-hat = voice 2), ignoring the cursor's voice. A tuplet started on voice 1 then got
    // its notes in voice 2 and left both voices with the wrong length ("voice too long: 9/8 in 4/4",
    // nc-f4c7 2026-10-31). So split the events by drumset voice and write each voice on its own track.
    function drumsetOf(op) {
        try { var p = curScore.parts[op.part]; return (p && p.hasDrumStaff) ? p.instruments[0].drumset : null }
        catch (e) { return null }
    }
    function splitDrumEvents(ev, ds) {
        var byV = {}, used = [], i, k
        for (i = 0; i < ev.length; i++)
            for (k = 0; ev[i].n && k < ev[i].n.length; k++) {
                var dv = ds.voice(ev[i].n[k][0]); if (!(dv >= 0 && dv < 4)) dv = 0
                if (used.indexOf(dv) < 0) used.push(dv)
            }
        if (!used.length) used.push(0)
        for (var u = 0; u < used.length; u++) {
            var out = []
            for (i = 0; i < ev.length; i++) {
                var x = ev[i], y = { t: x.t, d: x.d }
                if (x.tup) y.tup = x.tup
                var ns = []
                for (k = 0; x.n && k < x.n.length; k++) {
                    var v2 = ds.voice(x.n[k][0]); if (!(v2 >= 0 && v2 < 4)) v2 = 0
                    if (v2 === used[u]) ns.push(x.n[k])
                }
                if (ns.length) y.n = ns; else y.rest = true
                out.push(y)
            }
            byV[used[u]] = collapseRestTuplets(out)
        }
        return { voices: used.sort(), events: byV }
    }
    // a tuplet group that is all rests in this drum voice -> one plain rest (no empty "3" brackets)
    function collapseRestTuplets(ev) {
        var out = []
        for (var i = 0; i < ev.length; i++) {
            var x = ev[i]
            if (!x.tup) { out.push(x); continue }
            var j = i, left = x.tup[2], allRest = true
            while (j < ev.length && left > 0) {
                if (!ev[j].rest) allRest = false
                left -= ev[j].d * x.tup[1] / x.tup[0]
                j++
            }
            if (allRest && left === 0) { out.push({ t: x.t, d: x.tup[2], rest: true }); i = j - 1 }
            else out.push(x)
        }
        return out
    }
    function writeEvents(op, st, staff, v, ev) {
        var track = staff * 4 + v
        var c = cursorAt(track, op.start)
        if (!c.segment || c.tick !== op.start) throw "cannot place the cursor in " + op.name
        var written = []
        for (var i = 0; i < ev.length; i++) {
            var x = ev[i]
            if (c.tick !== x.t || c.track !== track) {
                c = cursorAt(track, x.t)
                if (c.tick !== x.t) { st.problems.push(op.name + ": skipped a note at tick " + x.t); continue }
            }
            if (x.tup) c.addTuplet(fraction(x.tup[0], x.tup[1]), frac(x.tup[2]))
            setDur(c, x.d)
            if (x.rest) { c.addRest(); continue }
            c.addNote(x.n[0][0])
            for (var j = 1; j < x.n.length; j++) c.addNote(x.n[j][0], true)
            written.push(x)
        }
        return written
    }
    function opWrite(op, st) {
        var staff = staffOf(op), v = 0
        var ds = drumsetOf(op)
        if (ds) {
            // drum voices are fixed by the drumset: clear the written voices (all of them on replace)
            var sp = splitDrumEvents(op.events, ds)
            if (op.replace)
                for (var k3 = 0; k3 < 4; k3++) {
                    if (sp.voices.indexOf(k3) >= 0) continue        // overwritten below anyway
                    for (var pass3 = 0; pass3 < 2; pass3++) {       // chords -> rests -> gone
                        var els3 = elementsIn(staff * 4 + k3, op.start, op.end)
                        for (var e3 = 0; e3 < els3.length; e3++) removeElement(els3[e3])
                    }
                }
            var n3 = 0
            for (var dvi = 0; dvi < sp.voices.length; dvi++) {
                var wr = writeEvents(op, st, staff, sp.voices[dvi], sp.events[sp.voices[dvi]])
                n3 += wr.length
            }
            st.count.write = (st.count.write || 0) + n3
            st.touched.push({ staff: staff, start: op.start, end: op.end })
            return
        }
        if (op.voice === "new") {
            v = -1
            for (var k = 1; k < 4; k++) if (!voiceHasChords(staff * 4 + k, op.start, op.end)) { v = k; break }
            if (v < 0) throw op.name + " has no free voice in that range"
        } else if (op.replace) {
            for (var k2 = 1; k2 < 4; k2++)
                for (var pass = 0; pass < 2; pass++) {            // chords -> rests -> gone
                    var els = elementsIn(staff * 4 + k2, op.start, op.end)
                    for (var e = 0; e < els.length; e++) removeElement(els[e])
                }
        }
        var track = staff * 4 + v
        var written = writeEvents(op, st, staff, v, op.events)
        st.touched.push({ staff: staff, start: op.start, end: op.end })
        // spelling (tpc) + stems on what was just written; follow ties MuseScore added at barlines
        for (var w = 0; w < written.length; w++) {
            var cc = cursorAt(track, written[w].t), ch = cc.element
            if (!ch || ch.type !== Element.CHORD || cc.tick !== written[w].t) continue
            var want = written[w].n
            for (var n = 0; n < ch.notes.length && n < want.length; n++) {
                var note = ch.notes[n], hops = 0
                while (note && hops++ < 8) {
                    setSpelling(note, want[n][1])
                    var tie = note.tieForward
                    note = tie ? tie.endNote : null
                }
            }
            if (op.stem && v > 0) ch.stemDirection = op.stem === "up" ? Direction.UP : Direction.DOWN
        }
        if (op.stem === "up" && v > 0) {          // doubled line sits above: existing voice 1 stems down
            var olds = elementsIn(staff * 4, op.start, op.end)
            for (var o = 0; o < olds.length; o++) if (olds[o].type === Element.CHORD) olds[o].stemDirection = Direction.DOWN
        }
        st.count.write = (st.count.write || 0) + written.length
    }
    function opPitches(op, st) {
        var staff = staffOf(op), miss = 0
        for (var i = 0; i < op.chords.length; i++) {
            var x = op.chords[i], ch = findChord(staff, x.t, x.old, !!x.grace)
            if (!ch) { miss++; continue }
            var notes = []
            for (var k = 0; k < ch.notes.length; k++) notes.push(ch.notes[k])
            notes.sort(function(a, b) { return a.pitch - b.pitch })
            for (var n = 0; n < notes.length && n < x["new"].length; n++) {
                var delta = notes[n].tpc2 - notes[n].tpc1
                notes[n].pitch = x["new"][n][0]
                notes[n].tpc1 = x["new"][n][1]; notes[n].tpc2 = x["new"][n][1] + delta
            }
            st.count.pitches = (st.count.pitches || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " note(s) not found (score changed?), left as they were")
    }
    readonly property var articSym: ({ staccato: "articStaccatoAbove", accent: "articAccentAbove", tenuto: "articTenutoAbove" })
    function opArtic(op, st) {
        var staff = staffOf(op), miss = 0, sym = SymId[articSym[op.type]]
        if (sym === undefined) throw "unknown articulation " + op.type
        for (var i = 0; i < op.chords.length; i++) {
            var x = op.chords[i], ch = findChord(staff, x.t, x.p, false)
            if (!ch) { miss++; continue }
            var has = false
            for (var a = 0; a < ch.articulations.length; a++) if (ch.articulations[a].symbol === sym) has = true
            if (has) continue
            var art = newElement(Element.ARTICULATION); art.symbol = sym; ch.add(art)
            st.count.artic = (st.count.artic || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " " + op.type + "(s) skipped (note not found)")
    }
    function opSlur(op, st) {
        var staff = staffOf(op), miss = 0
        for (var i = 0; i < op.slurs.length; i++) {
            var x = op.slurs[i]
            var a = findChord(staff, x.t1, x.p1, false), b = findChord(staff, x.t2, x.p2, false)
            if (!a || !b) { miss++; continue }
            var sl = newElement(Element.SLUR)
            sl.spannerTick = frac(x.t1)
            sl.track = a.track
            var c = curScore.newCursor(); c.track = a.track; c.rewindToTick(x.t1)
            c.add(sl)
            sl.spannerTicks = frac(x.t2 - x.t1)
            sl.spannerTrack2 = b.track
            st.count.slur = (st.count.slur || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " slur(s) skipped (note not found)")
    }

    // cursor on `staff` at exactly `tick` on any voice that has a chord/rest there
    function cursorWithElement(staff, tick) {
        for (var v = 0; v < 4; v++) {
            var c = curScore.newCursor(); c.track = staff * 4 + v; c.rewindToTick(tick)
            if (c.segment && c.tick === tick && c.element) return c
        }
        return null
    }
    function dynSym(txt) {
        var map = { p: "dynamicPiano", m: "dynamicMezzo", f: "dynamicForte", s: "dynamicSforzando",
                    z: "dynamicZ", r: "dynamicRinforzando", n: "dynamicNiente" }
        var out = ""
        for (var i = 0; i < txt.length; i++) {
            if (!map[txt[i]]) return txt
            out += "<sym>" + map[txt[i]] + "</sym>"
        }
        return out
    }
    function opMark(op, st) {
        var staff = staffOf(op), miss = 0
        for (var i = 0; i < op.marks.length; i++) {
            var x = op.marks[i], c = cursorWithElement(staff, x.t)
            if (!c) { miss++; continue }
            var el
            if (x.kind === "dyn") {
                var ann = c.segment.annotations                  // a new dynamic replaces the one already there
                for (var a = 0; ann && a < ann.length; a++)
                    if (ann[a].type === Element.DYNAMIC && ann[a].track - ann[a].track % 4 === c.track - c.track % 4) removeElement(ann[a])
                el = newElement(Element.DYNAMIC); c.add(el); el.text = dynSym(String(x.text))
            }
            else if (x.kind === "harmony") { el = newElement(Element.HARMONY); c.add(el); el.text = String(x.text) }   // HARMONY: add BEFORE setting text (else MS crashes)
            else { el = newElement(Element.STAFF_TEXT); el.text = String(x.text); c.add(el) }
            st.count.mark = (st.count.mark || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " marking(s) skipped (no note there)")
    }
    function opHairpin(op, st) {
        var staff = staffOf(op), miss = 0
        for (var i = 0; i < op.pins.length; i++) {
            var x = op.pins[i], c = cursorWithElement(staff, x.t1)
            if (!c) { miss++; continue }
            var hp = newElement(Element.HAIRPIN)
            hp.hairpinType = x.type === "dim" ? 1 : 0
            hp.spannerTick = frac(x.t1)
            hp.track = c.track
            c.add(hp)
            hp.spannerTicks = frac(x.t2 - x.t1)
            st.count.hairpin = (st.count.hairpin || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " hairpin(s) skipped (no note there)")
    }

    // ---- score-level edits. Each one is best-effort: a failure is reported as a note with the manual
    // steps and never rolls back the note edits of the same request.
    // Written-minus-concert key offset of a staff in fifths (Bb trumpet +2, F horn +1, Eb alto +3):
    // tpc2 - tpc1 of the first note on the staff. cursor.add(KEYSIG) does NOT transpose by itself.
    function keyOffset(s) {
        var c = curScore.newCursor(); c.staffIdx = s; c.voice = 0; c.rewind(0)
        while (c.segment) {
            var e = c.element
            if (e && e.type === Element.CHORD && e.notes.length) return e.notes[0].tpc2 - e.notes[0].tpc1
            if (!c.next()) break
        }
        return 0
    }
    function opKeySig(op, st) {
        var done = 0
        for (var s = 0; s < curScore.nstaves; s++) {
            try {
                var c = curScore.newCursor(); c.staffIdx = s; c.voice = 0; c.rewindToTick(op.t)
                if (!c.segment || c.tick !== op.t) continue
                var ks = newElement(Element.KEYSIG), w = op.fifths + keyOffset(s)
                if (w > 7) w -= 12; else if (w < -7) w += 12
                ks.concertKey = op.fifths
                ks.actualKey = w
                c.add(ks); done++
            } catch (e) { console.log("copilot keysig staff " + s + ": " + e) }
        }
        if (done) st.count.keysig = done
        else st.problems.push("couldn't set the key signature from here: drag the key from the Key signatures palette onto bar " + op.bar)
    }
    readonly property var textMeta: ({ title: "workTitle", subtitle: "subtitle", composer: "composer", lyricist: "lyricist" })
    function opText(op, st) {
        try { curScore.setMetaTag(textMeta[op.field] || op.field, op.text) } catch (e0) {}
        // An existing title/composer... text in the top frame is rewritten in place (addText alone
        // would stack a second title on top of the old one).
        try {
            var tid = { title: Tid.TITLE, subtitle: Tid.SUBTITLE, composer: Tid.COMPOSER, lyricist: Tid.LYRICIST }[op.field]
            var mb = curScore.firstMeasure, found = null
            while (mb && mb.prev) mb = mb.prev
            for (; tid !== undefined && mb && mb.type !== Element.MEASURE && !found; mb = mb.next) {
                var els = mb.elements || []
                for (var i = 0; i < els.length; i++) {
                    if (els[i].subStyle !== tid) continue
                    if (!found) { found = els[i]; found.text = op.text } else removeElement(els[i])
                }
            }
            if (found) { st.count.text = (st.count.text || 0) + 1; return }
        } catch (e1) { console.log("copilot text in frame: " + e1) }
        try { curScore.addText(op.field, op.text); st.count.text = (st.count.text || 0) + 1 }
        catch (e) { st.problems.push("couldn't add the " + op.field + " text: use Add > Text > " + op.field) }
    }
    function layoutBreakType(t) {
        try { return t === "page" ? LayoutBreak.PAGE : LayoutBreak.LINE } catch (e) { return t === "page" ? 0 : 1 }
    }
    function measureAt(tick) {
        var c = curScore.newCursor(); c.track = 0; c.rewindToTick(tick)
        return (c.segment && c.measure) ? { cursor: c, measure: c.measure } : null
    }
    function opLayout(op, st) {
        var miss = 0
        if (op.clear) {                        // drop existing system breaks in the range first
            try {
                var m = measureAt(op.clear[0]) ? measureAt(op.clear[0]).measure : null
                while (m && m.firstSegment && m.firstSegment.tick <= op.clear[1]) {
                    var els = m.elements || []
                    for (var i = els.length - 1; i >= 0; i--)
                        if (els[i].type === Element.LAYOUT_BREAK && els[i].layoutBreakType === layoutBreakType("line"))
                            removeElement(els[i])
                    m = m.nextMeasure
                }
            } catch (e0) { console.log("copilot layout clear: " + e0) }
        }
        for (var b = 0; b < op.breaks.length; b++) {
            var x = op.breaks[b], at = measureAt(x.t)
            if (!at) { miss++; continue }
            try {
                var lb = newElement(Element.LAYOUT_BREAK)
                lb.layoutBreakType = layoutBreakType(x.type)
                at.cursor.add(lb)
                st.count.layout = (st.count.layout || 0) + 1
            } catch (e) { miss++; console.log("copilot layout break: " + e) }
        }
        if (miss) st.problems.push(miss + " break(s) not added: select the bar and press Enter (system break) or Ctrl+Enter (page break)")
    }

    // Lyrics (0.8): one syllable per existing chord. syllabic: MuseScore SINGLE 0, BEGIN 1, END 2, MIDDLE 3.
    readonly property var sylCode: ({ single: 0, begin: 1, end: 2, middle: 3 })
    function opLyrics(op, st) {
        var staff = staffOf(op), miss = 0, verse = Math.max(0, (op.verse || 1) - 1)
        for (var i = 0; i < op.items.length; i++) {
            var x = op.items[i], ch = findChord(staff, x.t, x.p, false)
            if (!ch) { miss++; continue }
            var old = ch.lyrics || []
            for (var o = old.length - 1; o >= 0; o--) if (old[o].verse === verse) removeElement(old[o])
            var l = newElement(Element.LYRICS)
            l.text = String(x.text)
            l.verse = verse
            l.track = ch.track
            ch.add(l)
            try { l.syllabic = sylCode[x.syl] || 0 } catch (e1) { }
            if (x.ext) { try { l.lyricTicks = frac(x.ext) } catch (e2) { } }
            st.count.lyrics = (st.count.lyrics || 0) + 1
        }
        if (miss) st.problems.push(op.name + ": " + miss + " syllable(s) skipped (note not found)")
    }

    // After the edits, BEFORE endCmd: every voice of every bar a write touched must still fit its bar
    // (voice 1 exactly, voices 2-4 at most). Otherwise the whole request is rolled back.
    function measureAtTick(tick) {
        var c = curScore.newCursor(); c.track = 0; c.rewindToTick(tick)
        return c.segment ? c.measure : null
    }
    function checkBars(st) {
        var bad = []
        for (var i = 0; i < st.touched.length && bad.length < 4; i++) {
            var r = st.touched[i], m = measureAtTick(r.start), guard = 0
            while (m && m.firstSegment && m.firstSegment.tick < r.end && guard++ < 2000) {
                var t0 = m.firstSegment.tick, len = m.ticks.ticks, t1 = t0 + len
                for (var v = 0; v < 4; v++) {
                    var c = curScore.newCursor(); c.track = r.staff * 4 + v; c.rewindToTick(t0)
                    var sum = 0, endT = t0
                    while (c.segment && c.tick < t1) {
                        var e = c.element
                        if (e && c.tick >= t0 && (e.type === Element.CHORD || e.type === Element.REST)) {
                            var a = e.actualDuration ? e.actualDuration.ticks : e.duration.ticks
                            sum += a; endT = Math.max(endT, c.tick + a)
                        }
                        if (!c.next()) break
                    }
                    if (sum > len || endT > t1 || (v === 0 && sum > 0 && sum < len))
                        bad.push("bar " + (m.no + 1) + " staff " + (r.staff + 1) + " voice " + (v + 1)
                                 + " (" + sum + "/" + len + " ticks)")
                }
                m = m.nextMeasure
            }
        }
        return bad
    }

    // Applies all ops as ONE undo step. Throws nothing; returns {error} or {problems, count}.
    function applyEdits(ops) {
        var st = { problems: [], count: {}, touched: [] }
        curScore.startCmd("Bach AI")
        try {
            for (var i = 0; i < ops.length; i++) {
                var op = ops[i]
                if (op.op === "write") opWrite(op, st)
                else if (op.op === "pitches") opPitches(op, st)
                else if (op.op === "artic") opArtic(op, st)
                else if (op.op === "slur") opSlur(op, st)
                else if (op.op === "mark") opMark(op, st)
                else if (op.op === "hairpin") opHairpin(op, st)
                else if (op.op === "keysig") opKeySig(op, st)
                else if (op.op === "text") opText(op, st)
                else if (op.op === "layout") opLayout(op, st)
                else if (op.op === "lyrics") opLyrics(op, st)
                else st.problems.push("unsupported edit \"" + op.op + "\" skipped (update the plugin)")
            }
        } catch (e) {
            curScore.endCmd(true)                 // roll back everything from this request
            console.log("copilot apply failed: " + e)
            return { error: String(e) }
        }
        var bad = []
        try { bad = checkBars(st) } catch (e4) { console.log("copilot bar check: " + e4) }
        if (bad.length) {
            curScore.endCmd(true)
            console.log("copilot bar check failed: " + bad.join("; "))
            return { error: "it would have left " + bad.join(", ") + " with the wrong length" }
        }
        curScore.endCmd()
        console.log("copilot applied in place: " + JSON.stringify(st.count))
        return st
    }
}
