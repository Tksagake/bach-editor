#!/usr/bin/env python3
"""
copilot.py — local MuseScore score parser and Nzumari Bach API client.

Called by NotationCopilot.qml via a launcher script. It parses the exported
MusicXML locally, sends a compact score snapshot to Nzumari Bach over HTTPS,
and prints one structured edit report for the plugin to validate and apply.
No AI-provider credentials are stored or used on this computer.
"""

import sys
import json
import argparse
import os
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Tuple, Optional
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

TPQ = 480  # MuseScore internal ticks per quarter note (hardcoded in QML applyEdits)

NZUMARI_BASE_URL = "https://nzumari.vivaceke.co.ke"

# ---------------------------------------------------------------------------
# Error reporting — QML reads stdout, finds first line starting with '{', parses JSON.
# ---------------------------------------------------------------------------

def print_error_and_exit(message: str, buy_url: str = "") -> None:
    """Fails safely by returning a valid JSON error to the QML via stdout."""
    err = {
        "status": "error",
        "message": message,
        "buy_url": buy_url,
    }
    print(json.dumps(err))
    sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bach AI Local Backend")
    parser.add_argument("src", help="Path to the exported MusicXML file")
    parser.add_argument("instruction", help="User's prompt")
    parser.add_argument("-o", "--output", help="Output path (optional/debug)", default="")
    parser.add_argument("--yes", action="store_true", help="Force apply without confirmation")
    parser.add_argument("--question", action="append", default=[], help="History question (copilot's ask)")
    parser.add_argument("--answer", action="append", default=[], help="History answer (user's reply)")
    parser.add_argument("--conversation-id", default="", help="Existing Nzumari Bach conversation ID")
    return parser.parse_args()


# ---------------------------------------------------------------------------
# MusicXML parsing — normalized to partwise, ticks converted to 480-TPQ scale
# ---------------------------------------------------------------------------

STEP_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _midi_pitch(step: str, octave: int, alter: int) -> int:
    """Concert MIDI pitch number (0-127)."""
    return (octave + 1) * 12 + STEP_INDEX[step] + alter


def _written_tpc(step: str, alter: int) -> int:
    """Written pitch class 0-11 (for spelling)."""
    return (STEP_INDEX[step] + alter) % 12


def _parse_pitch(pitch_el: ET.Element) -> Tuple[int, int]:
    step = pitch_el.findtext("step", "C")
    octave = int(pitch_el.findtext("octave", "4"))
    alter = int(pitch_el.findtext("alter", "0") or 0)
    return _midi_pitch(step, octave, alter), _written_tpc(step, alter)


class MusicXMLNote:
    __slots__ = ("tick", "dur480", "midi", "tpc", "is_rest", "is_chord_member", "voice", "staff")

    def __init__(self, tick, dur480, midi, tpc, is_rest, is_chord_member, voice, staff):
        self.tick = tick
        self.dur480 = dur480
        self.midi = midi
        self.tpc = tpc
        self.is_rest = is_rest
        self.is_chord_member = is_chord_member
        self.voice = voice
        self.staff = staff


class MusicXMLMeasure:
    __slots__ = ("number", "start_tick", "end_tick", "divisions", "fifths", "beats", "beat_type", "notes")

    def __init__(self, number, start_tick):
        self.number = number
        self.start_tick = start_tick
        self.end_tick = start_tick
        self.divisions = 2
        self.fifths = 0
        self.beats = 4
        self.beat_type = 4
        self.notes: List[MusicXMLNote] = []


class MusicXMLPart:
    __slots__ = ("id", "name", "measures")

    def __init__(self, pid, name):
        self.id = pid
        self.name = name
        self.measures: List[MusicXMLMeasure] = []


class MusicXMLScore:
    def __init__(self):
        self.parts: List[MusicXMLPart] = []
        self.ticks_per_quarter = 2  # default MusicXML divisions


def parse_musicxml(file_path: str) -> MusicXMLScore:
    """
    Parse a MusicXML file (partwise or timewise), normalize to partwise,
    convert all durations/positions to the 480-TPQ scale expected by QML.
    """
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
    except Exception as e:
        print_error_and_exit(f"Failed to parse MusicXML: {str(e)}")

    tag = root.tag.split("}")[-1] if "}" in root.tag else root.tag
    score = MusicXMLScore()

    # ------------------------------------------------------------------
    # Normalize timewise -> partwise
    # ------------------------------------------------------------------
    if tag == "score-timewise":
        part_list = root.find("part-list")
        id_to_name = {}
        if part_list is not None:
            for sp in part_list.findall("score-part"):
                pid = sp.get("id")
                name_el = sp.find("part-name")
                id_to_name[pid] = name_el.text if name_el is not None else pid

        parts_data: Dict[str, List[ET.Element]] = {}
        for part in root.findall("part"):
            pid = part.get("id")
            parts_data.setdefault(pid, []).append(part)

        for pid, measure_elements in parts_data.items():
            measure_elements.sort(key=lambda m: int(m.get("number", "0")))
            part = MusicXMLPart(pid, id_to_name.get(pid, pid))
            score.parts.append(part)
            for m_el in measure_elements:
                _parse_measure(m_el, part, score)
    else:
        part_list = root.find("part-list")
        id_to_name = {}
        if part_list is not None:
            for sp in part_list.findall("score-part"):
                pid = sp.get("id")
                name_el = sp.find("part-name")
                id_to_name[pid] = name_el.text if name_el is not None else pid

        for part_el in root.findall("part"):
            pid = part_el.get("id")
            part = MusicXMLPart(pid, id_to_name.get(pid, pid))
            score.parts.append(part)
            for m_el in part_el.findall("measure"):
                _parse_measure(m_el, part, score)

    _finalize_measure_ticks(score)
    return score


def _parse_measure(m_el: ET.Element, part: MusicXMLPart, score: MusicXMLScore) -> None:
    number = int(m_el.get("number", "0"))

    divisions = score.ticks_per_quarter
    fifths = 0
    beats = 4
    beat_type = 4
    attrs = m_el.find("attributes")
    if attrs is not None:
        d = attrs.findtext("divisions")
        if d:
            divisions = int(d)
            score.ticks_per_quarter = divisions
        k = attrs.find("key")
        if k is not None:
            fifths = int(k.findtext("fifths", "0") or 0)
        t = attrs.find("time")
        if t is not None:
            beats = int(t.findtext("beats", "4") or 4)
            beat_type = int(t.findtext("beat-type", "4") or 4)

    measure = MusicXMLMeasure(number, start_tick=0)
    measure.divisions = divisions
    measure.fifths = fifths
    measure.beats = beats
    measure.beat_type = beat_type
    part.measures.append(measure)

    factor = TPQ / divisions  # ticks per division
    running_div = 0
    chord_tick_div = 0
    chord_members: List[Tuple[int, int]] = []

    for note_el in m_el.findall("note"):
        is_rest = note_el.find("rest") is not None
        is_chord = note_el.find("chord") is not None
        voice = int(note_el.findtext("voice", "1") or 1)
        staff = int(note_el.findtext("staff", "1") or 1)

        dur_div = int(note_el.findtext("duration", "0") or 0)

        if is_chord and chord_members:
            if not is_rest:
                midi, tpc = _parse_pitch(note_el.find("pitch"))
                chord_members.append((midi, tpc))
            continue

        if chord_members:
            tick_div = chord_tick_div
            for midi, tpc in chord_members:
                measure.notes.append(
                    MusicXMLNote(
                        int(tick_div * factor),
                        int(dur_div * factor) if dur_div else 0,
                        midi,
                        tpc,
                        False,
                        True,
                        voice,
                        staff,
                    )
                )
            chord_members = []
            running_div = chord_tick_div + dur_div

        if is_rest:
            measure.notes.append(
                MusicXMLNote(
                    int(running_div * factor),
                    int(dur_div * factor),
                    -1,
                    0,
                    True,
                    False,
                    voice,
                    staff,
                )
            )
            running_div += dur_div
        else:
            pitch_el = note_el.find("pitch")
            if pitch_el is None:
                continue
            midi, tpc = _parse_pitch(pitch_el)
            tick_div = running_div
            measure.notes.append(
                MusicXMLNote(
                    int(tick_div * factor),
                    int(dur_div * factor),
                    midi,
                    tpc,
                    False,
                    False,
                    voice,
                    staff,
                )
            )
            running_div += dur_div
            chord_tick_div = tick_div

    if chord_members:
        tick_div = chord_tick_div
        for midi, tpc in chord_members:
            measure.notes.append(
                MusicXMLNote(
                    int(tick_div * factor),
                    int(dur_div * factor) if dur_div else 0,
                    midi,
                    tpc,
                    False,
                    True,
                    voice,
                    staff,
                )
            )


def _finalize_measure_ticks(score: MusicXMLScore) -> None:
    """Assign absolute 480-TPQ start/end ticks to measures within each part."""
    for part in score.parts:
        cursor = 0
        for measure in part.measures:
            if measure.notes:
                max_end = max((n.tick + n.dur480 for n in measure.notes), default=0)
                if max_end == 0:
                    max_end = int(measure.beats * TPQ * 4 / measure.beat_type)
                measure.start_tick = cursor
                measure.end_tick = cursor + max_end
                cursor = measure.end_tick
            else:
                measure.start_tick = cursor
                measure.end_tick = cursor + int(measure.beats * TPQ * 4 / measure.beat_type)
                cursor = measure.end_tick


# ---------------------------------------------------------------------------
# Score serialization — compact text snapshot for the LLM system prompt
# ---------------------------------------------------------------------------

def serialize_score(score: MusicXMLScore) -> str:
    """Turn the parsed score into a compact text description the LLM can use."""
    lines: List[str] = []
    lines.append(f"TICKS_PER_QUARTER: {TPQ}")
    lines.append(f"PARTS: {len(score.parts)}")
    for p_idx, part in enumerate(score.parts):
        lines.append(f"\nPART {p_idx} (id={part.id}, name='{part.name}', staves=1):")
        for m in part.measures:
            lines.append(f"  MEASURE {m.number} (tick {m.start_tick}-{m.end_tick}, key={m.fifths} fifths, "
                         f"{m.beats}/{m.beat_type}):")
            for n in m.notes:
                if n.is_rest:
                    lines.append(f"    REST tick={n.tick} dur={n.dur480} voice={n.voice} staff={n.staff}")
                else:
                    lines.append(
                        f"    NOTE tick={n.tick} dur={n.dur480} midi={n.midi} tpc={n.tpc} "
                        f"voice={n.voice} staff={n.staff} chord_member={n.is_chord_member}"
                    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Dahl LLM integration
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are an expert MuseScore 4 notation editor operating on a strict 480-ticks-per-quarter-note (TPQ) grid.

CONTEXT
-------
You receive a serialized snapshot of the open MuseScore score. Every pitch is a MIDI concert-pitch number (0-127; 60 = middle C). Every tick is on a 480-TPQ grid. Parts are 0-indexed; each part has staff(s) (staff index is 0-based within the part for multi-staff instruments like piano). Voices are 0-3 within a staff track.

The score snapshot lists measures with absolute ticks, and each note/rest with: tick, duration (480-TPQ ticks), MIDI pitch, written pitch-class (tpc, 0-11), voice, staff.

RULES
-----
1. Only change what the user asks. Do not invent edits.
2. All tick values in your edits must be on the 480-TPQ scale shown in the snapshot.
3. All pitches in edits must be MIDI concert-pitch numbers. Provide written tpc (0-11) for spelling corrections.
4. Bar lengths must remain valid: voice 1 must exactly fill each bar; voices 2-4 may be partial. If your edits would break this, the whole request is rolled back.
5. If the request is ambiguous (missing bars, staff, pitches, etc.), return status "question" with kind "clarify" or "confirm" plus helpful options.
6. Otherwise return status "applied" with a valid "edits" array.

EDIT OP SCHEMA (exact fields QML expects)
----------------------------------------
Every op: { "op": "<type>", "name": "<label>" } plus type-specific fields.

write:
  { "op":"write","name":"...","part":0,"staff":0,"start":0,"end":1920,"voice":0,"replace":true,"stem":"up",
    "events":[ {"t":0,"d":480,"rest":true},
               {"t":480,"d":960,"n":[[60,0],[64,2]],"tup":[3,2,720]} ] }
  n = [[midi, tpc], ...]; tup = [numerator, denominator, total_ticks]

pitches:
  { "op":"pitches","name":"...","part":0,"staff":0,
    "chords":[ {"t":0,"old":[60,64],"new":[[62,1],[65,4]],"grace":false} ] }

artic:
  { "op":"artic","name":"...","part":0,"staff":0,"type":"staccato",
    "chords":[ {"t":0,"p":[60]} ] }
  type: "staccato" | "accent" | "tenuto"

slur:
  { "op":"slur","name":"...","part":0,"staff":0,
    "slurs":[ {"t1":0,"p1":[60],"t2":480,"p2":[64]} ] }

mark:
  { "op":"mark","name":"...","part":0,"staff":0,
    "marks":[ {"t":0,"kind":"dyn","text":"mf"},
              {"t":480,"kind":"harmony","text":"Am7"},
              {"t":960,"kind":"staff text","text":"cresc."} ] }
  dyn text chars mapped: p/m/f/s/z/r/n

hairpin:
  { "op":"hairpin","name":"...","part":0,"staff":0,
    "pins":[ {"t1":0,"t2":480,"type":"cresc"} ] }  // "dim" -> diminuendo

keysig:
  { "op":"keysig","name":"...","t":0,"fifths":-1,"bar":1 }

text:
  { "op":"text","name":"...","field":"title","text":"New Title" }
  field: "title" | "subtitle" | "composer" | "lyricist"

layout:
  { "op":"layout","name":"...","clear":[0,1920],
    "breaks":[ {"t":960,"type":"line"} ] }  // "page" | "line"

lyrics:
  { "op":"lyrics","name":"...","part":0,"staff":0,"verse":1,
    "items":[ {"t":0,"p":[60],"text":"Do","syl":"single","ext":480} ] }
  syl: "single"|"begin"|"end"|"middle"

QUESTION RESPONSE (status == "question"):
  { "status":"question","kind":"clarify","question":"...","options":["a","b"] }

APPLIED RESPONSE (status == "applied"):
  { "status":"applied","edits":[...],"edit_notes":["..."],"edit_summary":{"staff 1":"2 bars"} }

OUTPUT
------
Return strictly one JSON object. No markdown fences, no prose outside the JSON.
"""


def _strip_markdown_fences(text: str) -> str:
    """Remove ```json ... ``` fences if present."""
    text = text.strip()
    if text.startswith("```"):
        parts = text.split("```", 2)
        if len(parts) >= 3:
            text = parts[1]
            if text.lstrip().startswith(("json", "JSON")):
                text = text.split("\n", 1)[1] if "\n" in text else ""
    return text.strip()


def _extract_json(text: str) -> Dict[str, Any]:
    """Parse JSON from model output, tolerating fences and leading/trailing text."""
    cleaned = _strip_markdown_fences(text)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass
    # Fallback: find the first '{' and try to parse to the matching '}'
    start = cleaned.find("{")
    if start >= 0:
        depth = 0
        for i in range(start, len(cleaned)):
            if cleaned[i] == "{":
                depth += 1
            elif cleaned[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(cleaned[start:i + 1])
                    except json.JSONDecodeError:
                        break
    raise ValueError("Could not extract JSON from model output")


def call_bach_editor(
    score_context: str,
    instruction: str,
    history: List[Tuple[str, str]],
    conversation_id: str = "",
) -> Dict[str, Any]:
    """Send notation-edit requests to the authenticated Nzumari Bach API."""
    token_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bach-editor-token.txt")
    try:
        with open(token_path, "r", encoding="utf-8") as token_file:
            device_token = token_file.read().strip()
    except OSError:
        device_token = ""

    if not device_token:
        print_error_and_exit("Bach Editor is not connected. Use Connect in the plugin to pair it with Nzumari.")

    payload = {
        "instruction": instruction,
        "history": [{"question": question, "answer": answer} for question, answer in history],
        "scoreContext": {"editor": "musescore", "scoreSummary": score_context},
    }
    if conversation_id:
        payload["conversationId"] = conversation_id

    request = Request(
        NZUMARI_BASE_URL.rstrip("/") + "/api/bach/editor/edit",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + device_token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urlopen(request, timeout=300) as response:
            response_body = response.read().decode("utf-8")
    except HTTPError as error:
        try:
            detail = json.loads(error.read().decode("utf-8"))
            message = detail.get("error") or "Bach Editor request failed."
        except Exception:
            message = "Bach Editor request failed (HTTP %s)." % error.code
        print_error_and_exit(message)
    except (URLError, TimeoutError, OSError) as error:
        print_error_and_exit("Could not reach Nzumari Bach: %s" % error)

    try:
        result = json.loads(response_body)
    except json.JSONDecodeError:
        print_error_and_exit("Nzumari Bach returned an invalid response.")

    if not isinstance(result, dict):
        print_error_and_exit("Malformed Bach response.")
    if result.get("error"):
        print_error_and_exit(str(result["error"]))

    conversation_id = result.pop("conversationId", "")
    if conversation_id:
        result["conversation_id"] = conversation_id
    if "status" not in result:
        print_error_and_exit("Malformed Bach response: missing 'status' field.")
    return result

# ---------------------------------------------------------------------------
# Report validation (lightweight; QML also validates structurally when applying)
# ---------------------------------------------------------------------------

_VALID_OPS = {"write", "pitches", "artic", "slur", "mark", "hairpin", "keysig", "text", "layout", "lyrics"}


def validate_report(report: Dict[str, Any]) -> None:
    """Basic structural validation so QML never receives garbage JSON."""
    status = report.get("status")
    if status not in ("question", "applied", "error"):
        print_error_and_exit(f"Invalid status '{status}' in LLM report.")

    if status == "question":
        if "question" not in report:
            print_error_and_exit("Question response missing 'question' field.")
        report.setdefault("kind", "clarify")
        report.setdefault("options", [])
        return

    if status == "applied":
        edits = report.get("edits")
        if not isinstance(edits, list):
            print_error_and_exit("Applied response missing 'edits' array.")
        for op in edits:
            if not isinstance(op, dict):
                print_error_and_exit("Edit op is not an object.")
            op_type = op.get("op")
            if op_type not in _VALID_OPS:
                print_error_and_exit(f"Unknown edit op '{op_type}'.")
            if "name" not in op:
                print_error_and_exit(f"Edit op '{op_type}' missing 'name' field.")
        report.setdefault("edit_notes", [])
        report.setdefault("edit_summary", {})
        return

    # status == "error": nothing further required


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_arguments()

    history = list(zip(args.question, args.answer))

    # 1. Parse the incoming MusicXML
    score = parse_musicxml(args.src)

    # 2. Serialize for the LLM
    score_context = serialize_score(score)

    # 3. Query Dahl (MiniMax-M2.7 primary, DeepSeek-V4-Flash-0731 fallback)
    llm_report = call_bach_editor(score_context, args.instruction, history, args.conversation_id)

    # 4. Validate + print the clean JSON to stdout for QML
    validate_report(llm_report)
    print(json.dumps(llm_report))

    # 5. Optional debug output (QML ignores this file in local mode)
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(score_context)
        except Exception:
            pass

    sys.exit(0)


if __name__ == "__main__":
    main()