// Bach Editor -- MuseScore 4 notation integration.
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Window 2.15
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    id: root
    version: "0.9.2"
    title: "Bach AI"
    description: "Ask in plain language..."
    categoryCode: "composing-arranging-tools"
    pluginType: "dock"
    requiresScore: true
    width: 400; height: 760

    function urlToPath(u) {
        var s = String(u)
        if (/^file:\/\/\//i.test(s)) s = s.substring(7)
        else if (/^file:\/\//i.test(s)) s = "//" + s.substring(7)
        else if (/^file:/i.test(s)) s = s.substring(5)
        try { s = decodeURIComponent(s) } catch (e) { }
        if (/^\/[A-Za-z]:/.test(s)) s = s.substring(1)
        return s
    }
    function pluginDir() {
        var d = urlToPath(Qt.resolvedUrl("."))
        return /\/$/.test(d) ? d : d + "/"
    }

    // ---- Local inference ----
    property string bachConversationId: ""
    property string python: "python"
    property string copilot: pluginDir() + "copilot.py"
    property string workDir: ""
    property int sidebarWidth: 400

    property string instruction: ""
    property var history: []
    property string pendingQuestion: ""
    property string pendingKind: ""
    property bool busy: false
    property var job: ({})
    property int elapsed: 0
    property int sentCount: 0
    readonly property var examples: ["Add a simple piano accompaniment to bars 1-8",
                                     "Transpose the flute part up a major second in bars 1-8",
                                     "Add chord symbols to the melody in bars 1-8",
                                     "Double the melody in the strings in bars 1-8"]
    readonly property bool showExamples: sentCount === 0 && !busy

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
        var top = 108
        w.width = sidebarWidth
        w.height = Math.max(400, hh - top)
        w.x = x0 + ww - sidebarWidth
        w.y = y0 + top
        root.width = w.width; root.height = w.height
        return true
    }

    property string lastScoreName: ""
    onScoreStateChanged: {
        var n = curScore ? String(curScore.scoreName) : ""
        if (n !== lastScoreName) { if (lastScoreName !== "" && !busy) sentCount = 0; lastScoreName = n }
    }

    onRun: {
        lastScoreName = curScore ? String(curScore.scoreName) : ""
        say("bot", "Bach is ready. Score generation runs directly from this computer to DeepSeek; Nzumari sign-in is not required. Your edits remain local to MuseScore and one Ctrl+Z undoes each request.", "", "")
        placeTimer.start()
    }

    Rectangle {
        anchors.fill: parent; color: cBg

        Rectangle {
            id: header; anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 48; color: "#173B30"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: "#547365" }
            Text { id: titleText; anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                   text: "NZUMARI  /  BACH"; font.bold: true; font.pixelSize: 12; font.letterSpacing: 1; color: "#FFFFFF" }
            Row {
                anchors { right: parent.right; rightMargin: 8; top: parent.top; topMargin: 4 } spacing: 4
                Button { text: "New chat"; flat: true; font.pixelSize: 11; enabled: !busy
                         onClicked: { chat.clear(); resetRequest(); bachConversationId = ""; sentCount = 0
                                      say("bot", "A fresh conversation. Tell me what you would like to change in the open score.", "", "") } }
                Button { text: "Close"; flat: true; font.pixelSize: 11; onClicked: root.quit() }
            }
        }

        ListView {
            id: list
            anchors { left: parent.left; right: parent.right; top: header.bottom
                      bottom: showExamples ? examplesBox.top : composer.top; margins: 10 }
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

                Text { id: who; visible: model.role !== "status"; text: mine ? "You" : "Bach"
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
                           : (model.role === "error" ? "#F9EEEE" : (model.kind !== "" ? "#FBF6E9" : cBot)))
                    border.color: mine ? "transparent" : (model.role === "error" ? "#E7C8C8" : (model.kind !== "" ? "#E5D5B4" : cBorderLight))
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

        Column {
            id: examplesBox
            visible: showExamples
            anchors { left: parent.left; right: parent.right; bottom: composer.top
                      leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
            spacing: 8
            Text { text: "START WITH A TASK"; font.pixelSize: 12; font.bold: true; color: cMuted }
            Row {
                spacing: 8
                Repeater {
                    model: examples
                    delegate: Button {
                        width: (examplesBox.width - 24) / 3
                        height: 44
                        contentItem: Text { text: modelData; wrapMode: Text.Wrap; font.pixelSize: 11; color: cUser }
                        background: Rectangle {
                            color: parent.pressed ? "#E9E4D8" : cInputBg
                            radius: 10
                            border.color: cBorderLight
                            border.width: 1
                        }
                        onClicked: useExample(modelData)
                    }
                }
            }
        }

        Rectangle {
            id: composer
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
            height: input.height + 48; radius: 10; color: cInputBg
            border.color: input.activeFocus ? cUser : cBorderLight
            border.width: 1

            TextArea {
                id: input
                anchors {
                    left: parent.left; leftMargin: 8
                    right: sendBtn.left; rightMargin: 8
                    top: parent.top; topMargin: 6
                }
                height: Math.min(Math.max(contentHeight + 8, 36), 100)
                wrapMode: TextEdit.Wrap; font.pixelSize: 13; enabled: !busy
                color: cText
                selectedTextColor: "#FFFFFF"
                selectionColor: cUser
                background: Rectangle {
                    color: "#FFFFFF"
                    radius: 8
                    border.color: input.activeFocus ? cUser : cBorderLight
                    border.width: 1
                }
                placeholderText: pendingKind === "clarify" ? "Answer the question, or click an option above"
                                                           : "Ask Bach to change the score (Enter to send)"
                Keys.onPressed: function(e) {
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                        e.accepted = true; send()
                    }
                }
            }

            Text {
                anchors { left: parent.left; leftMargin: 10; bottom: parent.bottom; bottomMargin: 6 }
                font.pixelSize: 10; color: cMuted
                text: busy ? "Working" + ".".repeat(1 + elapsed % 3) + "  " + elapsed + "s"
                           : "Edits apply to open score (Ctrl+Z to undo)"
            }

            Button {
                id: sendBtn
                anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 6 }
                height: 30
                text: pendingKind === "clarify" ? "Answer" : "Send"; highlighted: true
                enabled: !busy && input.text.trim() !== ""
                onClicked: send()
            }
        }
    }

    function say(role, text, kind, opts, detail) {
        for (var i = 0; i < chat.count; i++) chat.setProperty(i, "live", false)
        chat.append({ role: role, text: text, kind: kind || "", opts: opts || "",
                      detail: detail || "", live: (kind || "") !== "" })
    }
    function useExample(t) {
        input.text = t
        input.forceActiveFocus()
        input.cursorPosition = input.text.length
    }
    function resetRequest() { instruction = ""; history = []; pendingQuestion = ""; pendingKind = "" }
    function addAnswer(a) { var h = history.slice(); h.push({ question: pendingQuestion, answer: a }); history = h }

    function send() {
        var t = input.text.trim()
        if (t === "" || busy) return
        input.text = ""
        say("user", t, "", "")
        sentCount++
        if (pendingKind === "clarify") {
            addAnswer(t)
            runBach(false)
        } else {
            resetRequest(); instruction = t; runBach(false)
        }
    }
    function pickOption(o) {
        if (/e\.g\./.test(o)) {
            var m = /"([^"]+)"/.exec(o)
            input.text = m ? m[1] : ""; input.forceActiveFocus(); input.cursorPosition = input.text.length
            return
        }
        say("user", o, "", "")
        addAnswer(o)
        runBach(false)
    }
    function forceApply() {
        say("user", "Apply anyway", "", "")
        if (pendingKind === "clarify")
            addAnswer("No more detail; use your best judgement.")
        runBach(true)
    }

    function runBach(force) {
        if (!curScore) { say("error", "Open a score first.", "", ""); return }
        var target = curScore.scoreName
        var stamp = Date.now()
        var wd = workDir !== "" ? workDir.replace(/\/+$/, "") + "/" : pluginDir()
        var src = wd + "in-" + stamp + ".musicxml"
        var dst = wd + "out-" + stamp + ".musicxml"
        busy = true; elapsed = 0
        say("status", "Preparing the score for Bach…", "", "")
        var exported = false
        try { exported = writeScore(curScore, src, "musicxml") } 
        catch (e) { busy = false; say("error", "MuseScore could not export this score. " + String(e), "", ""); return }
        if (!exported) { busy = false; say("error", "MuseScore's MusicXML export failed.", "", ""); return }
        fio.source = src
        if (!fio.exists()) { busy = false; say("error", "The MusicXML file was not created: " + src, "", ""); return }

        var args = [copilot, src, instruction]
        for (var h = 0; h < history.length; h++) {
            args.push("--question"); args.push(history[h].question)
            args.push("--answer"); args.push(history[h].answer)
        }
        if (bachConversationId !== "") { args.push("--conversation-id"); args.push(bachConversationId) }
        if (force) args.push("--yes")
        args.push("-o"); args.push(dst)
        var rep = wd + "rep-" + stamp + ".json"
        args.push("--report"); args.push(rep)
        job = { target: target, rep: rep }
        proc.startWithArgs(python, args)
        poll.start()
    }

    Timer {
        id: poll; interval: 500; repeat: true
        onTriggered: {
            elapsed++
            var finished = proc.waitForFinished(1)
            var st = (typeof proc.state === "function") ? proc.state() : proc.state
            fio.source = job.rep
            var hasReport = fio.exists()
            if (!hasReport && !finished) {
                if (elapsed > 600) {
                    stop(); proc.kill(); proc.waitForFinished(1000)
                    var timeoutOut = String(proc.readAllStandardOutput())
                    var timeoutErr = String(proc.readAllStandardError())
                    busy = false
                    say("error", "Bach exceeded the 5-minute limit.", "", "", ("STDOUT:\n" + timeoutOut + "\nSTDERR:\n" + timeoutErr).slice(-3000))
                    resetRequest()
                }
                return
            }
            stop(); busy = false
            var txt = hasReport ? String(fio.read()) : String(proc.readAllStandardOutput())
            var rc = finished ? proc.exitCode : 0
            var diagnostics = finished ? ("Exit code: " + rc + " | Exit status: " + proc.exitStatus) : ""
            if (finished) {
                var stderrText = String(proc.readAllStandardError())
                if (stderrText.trim() !== "") diagnostics += "\nSTDERR:\n" + stderrText
            }
            handleReport(txt, rc, diagnostics)
        }
    }

    function handleReport(txt, rc, diagnostics) {
        var rep = null
        var j = txt.search(/^\{/m)
        if (j >= 0) { try { rep = JSON.parse(txt.substring(j)) } catch (e) { rep = null } }
        var head = (j >= 0 ? txt.substring(0, j) : txt).trim()
        if (rep && rep.conversation_id) bachConversationId = String(rep.conversation_id)

        if (rep && rep.status === "error") {
            say("error", rep.message || "Bach could not complete this request.", "", "",
                [logText(rep), diagnostics || ""].filter(function(x) { return x !== "" }).join("\n"))
            resetRequest(); return
        }

        if (rep && rep.status === "question") {
            pendingKind = rep.kind; pendingQuestion = rep.question
            var opts = (rep.options || []).join("\n")
            if (rep.kind === "confirm") say("bot", rep.question, "confirm", "", (rep.options || []).join("\n"))
            else say("bot", rep.question, "clarify", opts)
            return
        }
        if (rc !== 0 || !rep) {
            var detail = (txt + "\n" + (diagnostics || "")).trim()
            say("error", "Bach's local process failed (exit " + rc + ").", "", "", detail.slice(-3000))
            resetRequest(); return
        }
        if (rep.status === "applied") finishApplied(rep, rep.edits || [], rep.edit_notes || [], rep.edit_summary)
        else say("bot", rep.message || head || "Nothing to change.", "", "", logText(rep))
        resetRequest()
    }

    function logText(rep) { return (rep.log || []).map(function(l) { return "- " + l }).join("\n") }

    function finishApplied(rep, edits, notes, summary) {
        if (!curScore || curScore.scoreName !== job.target) {
            say("error", "The score \"" + job.target + "\" is no longer the active score.", "", ""); return
        }
        if (!edits.length) { say("error", "The service returned no edits.", "", ""); return }
        var res = applyEdits(edits)
        if (res.error) {
            say("error", "Could not apply the change in place (" + res.error + ").", "", "", logText(rep)); return
        }
        var where = []
        var ch = summary || rep.changed || {}
        for (var k in ch) where.push(k.replace(/<\/?sym>|accidental/g, "").replace(/Flat/g, "♭").replace(/Sharp/g, "♯")
                                     + (/^\d/.test(String(ch[k])) ? " bars " : " ") + ch[k])
        var msg = "Changed " + (where.length ? where.join("; ") : (rep.message || "the score"))
        var extra = notes.concat(res.problems)
        say("bot", msg + " — Ctrl+Z to undo." + (extra.length ? "\nNote: " + extra.join("; ") + "." : ""), "", "", logText(rep))
    }

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
        return p.startTrack / 4 + op.staff
    }

    // *CRITICAL FIX* 
    // Explicitly set staffIdx and voice before rewinding the cursor to prevent track desync.
    function cursorAt(track, tick) {
        var c = curScore.newCursor()
        c.staffIdx = Math.floor(track / 4)
        c.voice = track % 4
        c.rewindToTick(tick)
        return c
    }

    function sortedPitches(ch) {
        var a = []
        for (var i = 0; i < ch.notes.length; i++) a.push(ch.notes[i].pitch)
        return a.sort(function(x, y) { return x - y })
    }
    function samePitches(ch, ps) { return sortedPitches(ch).join(",") === ps.slice().sort(function(x, y) { return x - y }).join(",") }

    function findChord(staff, tick, ps, grace) {
        for (var v = 0; v < 4; v++) {
            var c = cursorAt(staff * 4 + v, tick)
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
        var c = cursorAt(track, t0)
        while (c.segment && c.tick < t1) {
            if (c.tick >= t0 && c.element && c.element.type === Element.CHORD) return true
            if (!c.next()) break
        }
        return false
    }

    function elementsIn(track, t0, t1) {
        var out = [], c = cursorAt(track, t0)
        while (c.segment && c.tick < t1) {
            if (c.tick >= t0 && c.element) out.push(c.element)
            if (!c.next()) break
        }
        return out
    }
    function setSpelling(note, tpc) {
        var delta = note.tpc2 - note.tpc1
        note.tpc1 = tpc; note.tpc2 = tpc + delta
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
        var staff = staffOf(op), v = op.voice
        if (op.replace) {
            for (var k2 = (v === 0 ? 0 : 1); k2 < 4; k2++)
                for (var pass = 0; pass < 2; pass++) {
                    var els = elementsIn(staff * 4 + k2, op.start, op.end)
                    for (var e = 0; e < els.length; e++) removeElement(els[e])
                }
        }
        var track = staff * 4 + v
        var written = writeEvents(op, st, staff, v, op.events)
        st.touched.push({ staff: staff, start: op.start, end: op.end })

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
        if (miss) st.problems.push(op.name + ": " + miss + " note(s) not found")
    }

    readonly property var articSym: ({ staccato: "articStaccatoAbove", accent: "articAccentAbove", tenuto: "articTenutoAbove" })
    function opArtic(op, st) {
        var staff = staffOf(op), miss = 0, sym = SymId[articSym[op.type]]
        for (var i = 0; i < op.chords.length; i++) {
            var x = op.chords[i], ch = findChord(staff, x.t, x.p, false)
            if (!ch) { miss++; continue }
            var art = newElement(Element.ARTICULATION); art.symbol = sym; ch.add(art)
            st.count.artic = (st.count.artic || 0) + 1
        }
    }

    function opSlur(op, st) {
        var staff = staffOf(op)
        for (var i = 0; i < op.slurs.length; i++) {
            var x = op.slurs[i]
            var a = findChord(staff, x.t1, x.p1, false), b = findChord(staff, x.t2, x.p2, false)
            if (!a || !b) continue
            var sl = newElement(Element.SLUR)
            sl.spannerTick = frac(x.t1)
            sl.track = a.track
            var c = cursorAt(a.track, x.t1)
            c.add(sl)
            sl.spannerTicks = frac(x.t2 - x.t1)
            sl.spannerTrack2 = b.track
            st.count.slur = (st.count.slur || 0) + 1
        }
    }

    function cursorWithElement(staff, tick) {
        for (var v = 0; v < 4; v++) {
            var c = cursorAt(staff * 4 + v, tick)
            if (c.segment && c.tick === tick && c.element) return c
        }
        return null
    }

    function dynSym(txt) {
        var map = { p: "dynamicPiano", m: "dynamicMezzo", f: "dynamicForte", s: "dynamicSforzando", z: "dynamicZ", r: "dynamicRinforzando", n: "dynamicNiente" }
        var out = ""
        for (var i = 0; i < txt.length; i++) {
            if (!map[txt[i]]) return txt
            out += "<sym>" + map[txt[i]] + "</sym>"
        }
        return out
    }

    function opMark(op, st) {
        var staff = staffOf(op)
        for (var i = 0; i < op.marks.length; i++) {
            var x = op.marks[i], c = cursorWithElement(staff, x.t)
            if (!c) continue
            var el
            if (x.kind === "dyn") {
                el = newElement(Element.DYNAMIC); c.add(el); el.text = dynSym(String(x.text))
            } else if (x.kind === "harmony") { 
                el = newElement(Element.HARMONY); c.add(el); el.text = String(x.text) 
            } else { 
                el = newElement(Element.STAFF_TEXT); el.text = String(x.text); c.add(el) 
            }
            st.count.mark = (st.count.mark || 0) + 1
        }
    }

    function opHairpin(op, st) {
        var staff = staffOf(op)
        for (var i = 0; i < op.pins.length; i++) {
            var x = op.pins[i], c = cursorWithElement(staff, x.t1)
            if (!c) continue
            var hp = newElement(Element.HAIRPIN)
            hp.hairpinType = x.type === "dim" ? 1 : 0
            hp.spannerTick = frac(x.t1); hp.track = c.track; c.add(hp)
            hp.spannerTicks = frac(x.t2 - x.t1)
        }
    }

    function keyOffset(s) {
        var c = cursorAt(s * 4, 0)
        while (c.segment) {
            var e = c.element
            if (e && e.type === Element.CHORD && e.notes.length) return e.notes[0].tpc2 - e.notes[0].tpc1
            if (!c.next()) break
        }
        return 0
    }

    function opKeySig(op, st) {
        for (var s = 0; s < curScore.nstaves; s++) {
            try {
                var c = cursorAt(s * 4, op.t)
                if (!c.segment || c.tick !== op.t) continue
                var ks = newElement(Element.KEYSIG), w = op.fifths + keyOffset(s)
                if (w > 7) w -= 12; else if (w < -7) w += 12
                ks.concertKey = op.fifths; ks.actualKey = w; c.add(ks)
            } catch (e) {}
        }
    }

    function opText(op, st) {
        try { curScore.addText(op.field, op.text); st.count.text = (st.count.text || 0) + 1 } catch (e) { }
    }

    function layoutBreakType(t) { return t === "page" ? LayoutBreak.PAGE : LayoutBreak.LINE }
    function measureAt(tick) {
        var c = cursorAt(0, tick)
        return (c.segment && c.measure) ? { cursor: c, measure: c.measure } : null
    }

    function opLayout(op, st) {
        for (var b = 0; b < op.breaks.length; b++) {
            var x = op.breaks[b], at = measureAt(x.t)
            if (!at) continue
            try {
                var lb = newElement(Element.LAYOUT_BREAK)
                lb.layoutBreakType = layoutBreakType(x.type)
                at.cursor.add(lb)
            } catch (e) { }
        }
    }

    readonly property var sylCode: ({ single: 0, begin: 1, end: 2, middle: 3 })
    function opLyrics(op, st) {
        var staff = staffOf(op), verse = Math.max(0, (op.verse || 1) - 1)
        for (var i = 0; i < op.items.length; i++) {
            var x = op.items[i], ch = findChord(staff, x.t, x.p, false)
            if (!ch) continue
            var l = newElement(Element.LYRICS); l.text = String(x.text); l.verse = verse; l.track = ch.track
            ch.add(l)
            try { l.syllabic = sylCode[x.syl] || 0 } catch (e1) { }
        }
    }

    function measureAtTick(tick) {
        var c = cursorAt(0, tick)
        return c.segment ? c.measure : null
    }

    function checkBars(st) {
        var bad = []
        for (var i = 0; i < st.touched.length && bad.length < 4; i++) {
            var r = st.touched[i], m = measureAtTick(r.start), guard = 0
            while (m && m.firstSegment && m.firstSegment.tick < r.end && guard++ < 2000) {
                var t0 = m.firstSegment.tick, len = m.ticks.ticks, t1 = t0 + len
                for (var v = 0; v < 4; v++) {
                    var c = cursorAt(r.staff * 4 + v, t0)
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
                        bad.push("bar " + (m.no + 1) + " staff " + (r.staff + 1) + " voice " + (v + 1))
                }
                m = m.nextMeasure
            }
        }
        return bad
    }

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
            }
        } catch (e) {
            curScore.endCmd(true)
            return { error: String(e) }
        }
        var bad = []
        try { bad = checkBars(st) } catch (e4) { }
        if (bad.length) {
            curScore.endCmd(true)
            return { error: "it would have left " + bad.join(", ") + " with the wrong length" }
        }
        curScore.endCmd()
        return st
    }
}