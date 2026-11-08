// Bach Editor -- MuseScore 4 notation integration.
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
// Flow per message: export the OPEN score to MusicXML -> local parser creates a compact
// score snapshot -> authenticated Nzumari Bach Editor API -> apply validated edits in place.
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
    version: "0.9.0"
    title: "Bach AI"
    description: "Ask in plain language (any language) and the AI edits the open score: write melodies, scales, exercises and countermelodies, copy or clear bars, add dynamics and chord symbols, voice sections, write pads and bass lines. One Ctrl+Z undoes each request."
    categoryCode: "composing-arranging-tools"
    pluginType: "dock"
    requiresScore: true
    width: 440; height: 760

    // ---- Nzumari connection ----
    property string mode: "local"
    // Nzumari production API.
    property string serverUrl: "https://nzumari.vivaceke.co.ke"
    property string deviceToken: ""                 // scoped Nzumari device token
    property string pairingDeviceCode: ""
    property bool pairingStarting: false
    property string bachConversationId: ""
    property string python: "python"
    property string copilot: pluginDir() + "copilot.py"
    property string workDir: ""
    property int sidebarWidth: 440

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
    readonly property bool showExamples: sentCount === 0 && !busy && deviceToken !== ""

    readonly property color cBg: "#F7F5EF"
    readonly property color cUser: "#173B30"
    readonly property color cBot: "#FFFFFF"
    readonly property color cBorder: "#DED8CB"
    readonly property color cText: "#293B32"
    readonly property color cMuted: "#7A887F"
    readonly property color cBorderLight: "#E6E8E2"
    readonly property color cInputBg: "#FFFFFF"

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
        loadDeviceToken()
        if (deviceToken === "") {
            say("status", "Not connected to Nzumari. Use the Connect button above to authorise this MuseScore installation.", "", "")
        } else {
            say("bot", "Connected to Nzumari Bach. Ask me to change the open score in plain language. Your edits remain local to MuseScore and one Ctrl+Z undoes each request.", "", "")
        }
        placeTimer.start()
    }

    // ---------- Nzumari device credential ----------
    // Device tokens are scoped to Bach Editor and can be revoked from Nzumari.
    function tokenPath() { return pluginDir() + "bach-editor-token.txt" }
    function loadDeviceToken() {
        fio.source = tokenPath()
        if (fio.exists()) deviceToken = String(fio.read()).trim()
    }
    function beginPairing() {
        if (pairingDeviceCode !== "" || pairingStarting || deviceToken !== "") return
        pairingStarting = true
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            pairingStarting = false
            var r = null
            try { r = JSON.parse(x.responseText) } catch (e) {}
            if (x.status !== 200 || !r || !r.deviceCode) {
                say("error", (r && r.error) || ("Could not start Nzumari pairing (HTTP " + x.status + ")."), "", "")
                return
            }
            pairingDeviceCode = r.deviceCode
            say("bot", "Approve this MuseScore installation in your browser. Pairing code: " + r.userCode, "", "")
            Qt.openUrlExternally(r.verificationUri)
            pairingPoll.start()
        }
        x.open("POST", serverUrl + "/api/bach/editor/device")
        x.setRequestHeader("Content-Type", "application/json")
        x.send(JSON.stringify({ action: "authorize", deviceName: "Bach Editor · MuseScore" }))
    }
    function disconnectDevice() {
        if (deviceToken === "") return
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return
            var r = null
            try { r = JSON.parse(x.responseText) } catch (e) {}
            if (x.status === 200 && r && r.revoked) {
                fio.source = tokenPath()
                try { fio.remove() } catch (e) {}
                deviceToken = ""; bachConversationId = ""
                say("bot", "This MuseScore installation has been disconnected from Nzumari.", "", "")
            } else {
                say("error", (r && r.error) || "Could not revoke this device credential.", "", "")
            }
        }
        x.open("POST", serverUrl + "/api/bach/editor/device")
        x.setRequestHeader("Content-Type", "application/json")
        x.setRequestHeader("Authorization", "Bearer " + deviceToken)
        x.send(JSON.stringify({ action: "revoke" }))
    }

    Timer {
        id: pairingPoll; interval: 3000; repeat: true
        onTriggered: {
            if (pairingDeviceCode === "") { stop(); return }
            var x = new XMLHttpRequest()
            x.onreadystatechange = function() {
                if (x.readyState !== XMLHttpRequest.DONE) return
                var r = null
                try { r = JSON.parse(x.responseText) } catch (e) {}
                if (x.status !== 200 || !r) {
                    stop(); pairingDeviceCode = ""
                    say("error", (r && r.error) || "Could not complete Nzumari pairing.", "", "")
                    return
                }
                if (r.status === "authorized") {
                    stop(); pairingDeviceCode = ""; deviceToken = r.accessToken
                    fio.source = tokenPath()
                    if (!fio.write(deviceToken)) {
                        deviceToken = ""
                        say("error", "Could not save the device credential in the plugin folder.", "", "")
                        return
                    }
                    say("bot", "Bach Editor is now connected to your Nzumari account.", "", "")
                } else if (r.status === "expired" || r.status === "invalid" || r.status === "revoked") {
                    stop(); pairingDeviceCode = ""
                    say("error", "The pairing request expired or is no longer valid. Click Connect to try again.", "", "")
                }
            }
            x.open("POST", serverUrl + "/api/bach/editor/device")
            x.setRequestHeader("Content-Type", "application/json")
            x.send(JSON.stringify({ action: "token", deviceCode: pairingDeviceCode }))
        }
    }

    // ---------- Nzumari / Bach interface ----------
    Rectangle {
        anchors.fill: parent
        color: cBg

        // Brand header
        Rectangle {
            id: header
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 78
            color: "#173B30"

            Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }; width: 4; color: "#C6A66B" }

            Column {
                anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                spacing: 3
                Text {
                    text: "NZUMARI  /  NOTATION STUDIO"
                    color: "#C6A66B"; font.pixelSize: 9; font.bold: true; font.letterSpacing: 1.4
                }
                Text {
                    text: "Bach"
                    color: "#FFFFFF"; font.pixelSize: 25; font.weight: Font.DemiBold
                }
            }

            Column {
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 4
                Button {
                    text: "New chat"
                    height: 27
                    enabled: !busy
                    onClicked: {
                        chat.clear(); resetRequest(); bachConversationId = ""; sentCount = 0
                        say("bot", "A fresh conversation. Tell me what you would like to change in the open score.", "", "")
                    }
                    contentItem: Text { text: parent.text; color: "#FFFFFF"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 6; color: parent.pressed ? "#31594D" : "#244B3F"; border.color: "#547365" }
                }
                Row {
                    spacing: 5
                    Button {
                        visible: deviceToken !== ""
                        text: "Disconnect"
                        height: 23
                        enabled: !busy
                        onClicked: disconnectDevice()
                        contentItem: Text { text: parent.text; color: "#E8D8B8"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 5; color: "transparent"; border.color: "#6D887C" }
                    }
                    Button {
                        text: "Close"
                        height: 23
                        onClicked: root.quit()
                        contentItem: Text { text: parent.text; color: "#D5E1DA"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 5; color: "transparent"; border.color: "#6D887C" }
                    }
                }
            }
        }

        // Active score context
        Rectangle {
            id: contextBar
            anchors { left: parent.left; right: parent.right; top: header.bottom }
            height: 38
            color: "#F0EDE5"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }; height: 1; color: "#DED8CB" }
            Row {
                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 8
                Rectangle { width: 7; height: 7; radius: 4; color: deviceToken !== "" ? "#4D876C" : "#B58A4B"; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: curScore ? String(curScore.scoreName) : "No score open"
                    color: "#34483F"; font.pixelSize: 11; font.weight: Font.DemiBold
                    elide: Text.ElideRight; width: parent.width - 100
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: deviceToken !== "" ? "CONNECTED" : "OFFLINE"
                    color: deviceToken !== "" ? "#3E725A" : "#8A6B3F"
                    font.pixelSize: 9; font.bold: true; font.letterSpacing: 0.7
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // Connection onboarding
        Rectangle {
            id: connectionPanel
            visible: deviceToken === ""
            anchors { left: parent.left; right: parent.right; top: contextBar.bottom; margins: 12 }
            height: pairingDeviceCode !== "" ? 190 : 154
            radius: 12
            color: "#FFFFFF"
            border.color: "#DED8CB"
            Column {
                anchors { fill: parent; margins: 15 }
                spacing: 8
                Text {
                    text: pairingDeviceCode !== "" ? "AUTHORISATION REQUIRED" : (pairingStarting ? "CONTACTING NZUMARI…" : "CONNECT BACH TO NZUMARI")
                    color: "#173B30"; font.pixelSize: 11; font.bold: true; font.letterSpacing: 0.8
                }
                Text {
                    width: parent.width; wrapMode: Text.WordWrap
                    text: pairingDeviceCode !== "" ? "A browser approval is waiting. Complete the sign-in to link this MuseScore installation."
                                                     : "Sign in to your Nzumari account to use Bach with your own projects and notation workflow."
                    color: "#66736B"; font.pixelSize: 12; lineHeight: 1.2
                }
                Rectangle {
                    visible: pairingDeviceCode !== ""
                    width: parent.width; height: 34; radius: 6
                    color: "#F6F1E7"; border.color: "#E5D5B4"
                    Row {
                        anchors.centerIn: parent; spacing: 8
                        Text { text: "PAIRING CODE"; color: "#8A7655"; font.pixelSize: 9; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: pairingDeviceCode; color: "#173B30"; font.pixelSize: 16; font.bold: true; font.letterSpacing: 2; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
                Button {
                    text: pairingStarting ? "Connecting…" : (pairingDeviceCode !== "" ? "Waiting for browser approval" : "Connect to Nzumari")
                    enabled: !pairingStarting && pairingDeviceCode === ""
                    height: 34
                    onClicked: beginPairing()
                    contentItem: Text { text: parent.text; color: "#FFFFFF"; font.pixelSize: 12; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 7; color: parent.enabled ? (parent.pressed ? "#102D24" : "#173B30") : "#82958C" }
                }
            }
        }

        // Conversation
        ListView {
            id: list
            anchors {
                left: parent.left; right: parent.right
                top: connectionPanel.visible ? connectionPanel.bottom : contextBar.bottom
                bottom: showExamples ? examplesBox.top : composer.top
                leftMargin: 12; rightMargin: 12; topMargin: 12; bottomMargin: 10
            }
            clip: true
            spacing: 14
            model: chat
            ScrollBar.vertical: ScrollBar { active: true }
            onCountChanged: Qt.callLater(function() { list.positionViewAtEnd() })

            delegate: Item {
                id: messageRow
                width: list.width
                height: bubble.height + (who.visible ? 24 : 0)
                property bool mine: model.role === "user"
                property var opts: model.opts === "" ? [] : model.opts.split("\n")

                Text {
                    id: who
                    visible: model.role !== "status"
                    text: mine ? "YOU" : (model.role === "error" ? "BACH  ·  NOTICE" : "BACH")
                    font.pixelSize: 9; font.bold: true; font.letterSpacing: 0.8
                    color: model.role === "error" ? "#8B3D43" : "#7A887F"
                    anchors { top: parent.top; left: mine ? undefined : parent.left; right: mine ? parent.right : undefined }
                }

                Rectangle {
                    id: bubble
                    y: who.visible ? who.height + 6 : 0
                    width: Math.min(list.width - 20, Math.max(120, body.width + 28))
                    height: messageColumn.height + 22
                    anchors { left: mine ? undefined : parent.left; right: mine ? parent.right : undefined }
                    radius: 11
                    color: mine ? "#173B30" : (model.role === "status" ? "transparent" : (model.role === "error" ? "#F9EEEE" : (model.kind !== "" ? "#FBF6E9" : "#FFFFFF")))
                    border.width: mine || model.role === "status" ? 0 : 1
                    border.color: model.role === "error" ? "#E7C8C8" : (model.kind !== "" ? "#E5D5B4" : "#E6E8E2")

                    Column {
                        id: messageColumn
                        x: 14; y: 11; width: bubble.width - 28
                        spacing: 8
                        Text {
                            id: body
                            width: Math.min(implicitWidth, list.width - 58)
                            text: model.text
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            font.pixelSize: 13
                            lineHeight: 1.25
                            color: mine ? "#FFFFFF" : (model.role === "status" ? "#7A887F" : (model.role === "error" ? "#71383C" : "#293B32"))
                            font.italic: model.role === "status"
                        }
                        Text {
                            visible: model.detail !== ""
                            width: messageColumn.width
                            text: model.detail
                            wrapMode: Text.WordWrap
                            font.pixelSize: 10
                            font.family: "Consolas, 'Courier New', monospace"
                            color: mine ? "#D5E1DA" : "#77847C"
                        }
                        Repeater {
                            model: messageRow.opts
                            delegate: Button {
                                width: messageColumn.width
                                height: Math.max(32, optionText.implicitHeight + 14)
                                enabled: messageRow.isLive() && !busy
                                contentItem: Text {
                                    id: optionText
                                    text: modelData; wrapMode: Text.WordWrap
                                    font.pixelSize: 11; color: parent.enabled ? "#315F4D" : "#87938B"
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle { radius: 6; color: parent.pressed ? "#E8E0CF" : "#FFFFFF"; border.color: "#D8C9A8" }
                                onClicked: pickOption(modelData)
                            }
                        }
                        Button {
                            visible: model.url !== ""
                            text: "Upgrade / buy edits"
                            highlighted: true
                            onClicked: Qt.openUrlExternally(model.url)
                        }
                        Row {
                            spacing: 8
                            visible: model.kind !== "" && messageRow.isLive()
                            Button {
                                text: "Apply anyway"; enabled: !busy
                                onClicked: forceApply()
                                contentItem: Text { text: parent.text; color: "#FFFFFF"; font.pixelSize: 11; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                background: Rectangle { radius: 6; color: "#173B30" }
                            }
                            Button {
                                text: "Cancel"; flat: true; enabled: !busy
                                onClicked: { resetRequest(); say("status", "Request cancelled.", "", "") }
                            }
                        }
                    }
                }
                function isLive() { return model.live && pendingKind !== "" }
            }
        }

        // Helpful first actions
        Column {
            id: examplesBox
            visible: showExamples
            anchors { left: parent.left; right: parent.right; bottom: composer.top; leftMargin: 14; rightMargin: 14; bottomMargin: 10 }
            spacing: 8
            Text { text: "START WITH A TASK"; font.pixelSize: 9; font.bold: true; font.letterSpacing: 0.8; color: "#7A887F" }
            Grid {
                width: parent.width
                columns: 2
                spacing: 7
                Repeater {
                    model: examples
                    delegate: Button {
                        width: (examplesBox.width - 7) / 2
                        height: 45
                        contentItem: Text {
                            text: modelData; wrapMode: Text.WordWrap
                            font.pixelSize: 10; color: "#315F4D"
                            horizontalAlignment: Text.AlignLeft; verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: 7
                            color: parent.pressed ? "#E9E4D8" : "#FFFFFF"
                            border.color: "#E0DED5"
                        }
                        onClicked: useExample(modelData)
                    }
                }
            }
        }

        // Message composer
        Rectangle {
            id: composer
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
            height: input.height + 54
            radius: 12
            color: "#FFFFFF"
            border.width: 1
            border.color: input.activeFocus ? "#8AA392" : "#DED8CB"

            TextArea {
                id: input
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 12; rightMargin: 12; topMargin: 9 }
                height: Math.min(Math.max(contentHeight + 12, 42), 94)
                wrapMode: TextEdit.Wrap
                font.pixelSize: 13
                color: "#293B32"
                enabled: !busy && deviceToken !== ""
                background: null
                placeholderText: pendingKind === "clarify" ? "Answer Bach's question…" : "Describe the change you want…"
                Keys.onPressed: function(e) {
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                        e.accepted = true; send()
                    }
                }
            }

            Row {
                anchors { left: parent.left; leftMargin: 12; bottom: parent.bottom; bottomMargin: 9 }
                spacing: 6
                Text {
                    text: busy ? "WORKING  ·  " + elapsed + "s" : "OPEN SCORE  ·  LOCAL EDITS"
                    color: busy ? "#8A6B3F" : "#839087"
                    font.pixelSize: 9; font.bold: true; font.letterSpacing: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text { text: busy ? " " + ".".repeat(1 + elapsed % 3) : "·  Ctrl+Z to undo"; color: "#A1AAA3"; font.pixelSize: 9; anchors.verticalCenter: parent.verticalCenter }
            }

            Button {
                anchors { right: parent.right; rightMargin: 9; bottom: parent.bottom; bottomMargin: 7 }
                text: pendingKind === "clarify" ? "Answer" : "Send"
                enabled: !busy && deviceToken !== "" && input.text.trim() !== ""
                height: 32; width: 74
                onClicked: send()
                contentItem: Text { text: parent.text; color: "#FFFFFF"; font.pixelSize: 11; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 7; color: parent.enabled ? (parent.pressed ? "#102D24" : "#173B30") : "#AAB6AE" }
            }
        }
    }

    // ---------- conversation logic ----------
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
        say("user", t, "", "")
        if (deviceToken === "") { beginPairing(); return }
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
        if (deviceToken === "") { beginPairing(); return }
        // Export the active score; the local parser creates the compact notation snapshot for Bach.
        var stamp = Date.now()
        var wd = workDir !== "" ? workDir.replace(/\/+$/, "") + "/" : pluginDir()
        if (workDir !== "") { proc.startWithArgs("mkdir", ["-p", wd]); proc.waitForFinished(5000) }
        var src = wd + "in-" + stamp + ".musicxml"
        var dst = wd + "out-" + stamp + ".musicxml"
        var rep = wd + "report-" + stamp + ".json"
        var done = wd + "done-" + stamp
        if (!writeScore(curScore, src, "musicxml")) {
            say("error", "Could not export the score to " + src + ".", "", ""); return
        }
        var sh = wd + "run-" + stamp + ".sh"
        fio.source = sh
        fio.write(shq(python) + " " + shq(copilot) + " " + shq(src) + " " + shq(instruction)
                  + historyArgs() + (bachConversationId !== "" ? " --conversation-id " + shq(bachConversationId) : "")
                  + (force ? " --yes" : "") + " -o " + shq(dst) + " > " + shq(rep) + " 2>&1\n"
                  + "echo $? > " + shq(done) + "\n")
        console.log("copilot launcher: " + sh)
        job = { rep: rep, dst: dst, done: done, target: target }
        busy = true; elapsed = 0
        proc.startWithArgs("sh", [sh])
        poll.start()
    }

    Timer {
        id: poll; interval: 1000; repeat: true
        onTriggered: {
            elapsed++
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

    function handleReport(txt, rc) {
        var rep = null
        var j = txt.search(/^\{/m)
        if (j >= 0) { try { rep = JSON.parse(txt.substring(j)) } catch (e) { rep = null } }
        var head = (j >= 0 ? txt.substring(0, j) : txt).trim()
        if (rep && rep.conversation_id) bachConversationId = String(rep.conversation_id)

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
