#!/usr/bin/env python3
"""
copilot.py — local MuseScore score parser and direct DeepSeek client.

MusicXML is parsed locally. Score-edit requests go directly from this computer
to DeepSeek's OpenAI-compatible API; Nzumari's web backend is not in this path.
The returned structured edit report is validated before QML applies it.
"""

import sys
import json
import argparse
import os
import re
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Tuple, Optional
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import time

TPQ = 480  # MuseScore internal ticks per quarter note (hardcoded in QML applyEdits)

# Direct DeepSeek inference. The key is read from the local, git-ignored config.
DEEPSEEK_BASE_URL = "https://api.deepseek.com/chat/completions"
DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-pro"
REQUEST_TIMEOUT_SECONDS = 45

# ---------------------------------------------------------------------------
# Error reporting — QML reads stdout, finds first line starting with '{', parses JSON.
# ---------------------------------------------------------------------------

def print_error_and_exit(message: str, code: str = "", request_id: str = "") -> None:
    """Return a structured Nzumari API error to the MuseScore plugin."""
    err = {"status": "error", "message": message}
    if code:
        err["code"] = code
    if request_id:
        err["request_id"] = request_id
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
    parser.add_argument("--conversation-id", default="", help=argparse.SUPPRESS)
    return parser.parse_args()


# ---------------------------------------------------------------------------
# MusicXML parsing — normalized to partwise, ticks converted to 480-TPQ scale
# ---------------------------------------------------------------------------

STEP_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _midi_pitch(step: str, octave: int, alter: int) -> int:
    """Concert MIDI pitch number (0-127)."""
    return (octave + 1) * 12 + STEP_INDEX[step] + alter


def _written_tpc(step: str, alter: int) -> int:
    """MuseScore Tonal Pitch Class (line-of-fifths encoding)."""
    base = {"F": 13, "C": 14, "G": 15, "D": 16, "A": 17, "E": 18, "B": 19}
    return base[step] + 7 * alter


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
    __slots__ = ("id", "name", "measures", "divisions", "fifths", "beats", "beat_type")

    def __init__(self, pid, name):
        self.id = pid
        self.name = name
        self.measures: List[MusicXMLMeasure] = []
        # MusicXML attributes are stateful: omitted values carry forward.
        self.divisions = 2
        self.fifths = 0
        self.beats = 4
        self.beat_type = 4


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
    """Parse one measure while preserving MusicXML attribute state and voice timing."""
    number = int(m_el.get("number", "0"))
    divisions = part.divisions
    fifths = part.fifths
    beats = part.beats
    beat_type = part.beat_type

    attrs = m_el.find("attributes")
    if attrs is not None:
        d = attrs.findtext("divisions")
        if d:
            divisions = int(d)
        k = attrs.find("key")
        if k is not None:
            fifths = int(k.findtext("fifths", str(fifths)) or fifths)
        t = attrs.find("time")
        if t is not None:
            beats = int(t.findtext("beats", str(beats)) or beats)
            beat_type = int(t.findtext("beat-type", str(beat_type)) or beat_type)

    part.divisions = divisions
    part.fifths = fifths
    part.beats = beats
    part.beat_type = beat_type
    score.ticks_per_quarter = divisions

    measure = MusicXMLMeasure(number, start_tick=0)
    measure.divisions = divisions
    measure.fifths = fifths
    measure.beats = beats
    measure.beat_type = beat_type
    part.measures.append(measure)

    factor = TPQ / divisions
    running_div = 0
    last_start: Dict[Tuple[int, int], int] = {}

    # Process in document order. MusicXML backup/forward elements move the
    # cursor between voices; chord members share the preceding note's onset.
    for child in list(m_el):
        tag = child.tag.split("}")[-1]
        if tag == "backup":
            amount = int(child.findtext("duration", "0") or 0)
            running_div = max(0, running_div - amount)
            continue
        if tag == "forward":
            amount = int(child.findtext("duration", "0") or 0)
            running_div += amount
            continue
        if tag != "note":
            continue

        is_rest = child.find("rest") is not None
        is_chord = child.find("chord") is not None
        voice = max(0, int(child.findtext("voice", "1") or 1) - 1)
        staff = max(0, int(child.findtext("staff", "1") or 1) - 1)
        dur_div = int(child.findtext("duration", "0") or 0)
        key = (voice, staff)
        tick_div = last_start.get(key, running_div) if is_chord else running_div

        if not is_chord:
            last_start[key] = tick_div

        if is_rest:
            measure.notes.append(MusicXMLNote(
                int(tick_div * factor), int(dur_div * factor), -1, 0,
                True, False, voice, staff
            ))
        else:
            pitch_el = child.find("pitch")
            if pitch_el is not None:
                midi, tpc = _parse_pitch(pitch_el)
                measure.notes.append(MusicXMLNote(
                    int(tick_div * factor), int(dur_div * factor), midi, tpc,
                    False, is_chord, voice, staff
                ))

        if not is_chord:
            running_div += dur_div

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
        staff_count = max((n.staff for m in part.measures for n in m.notes), default=0) + 1
        lines.append(f"\nPART {p_idx} (id={part.id}, name='{part.name}', staves={staff_count}):")
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
# Direct DeepSeek LLM integration
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are an expert MuseScore 4 notation editor operating on a strict 480-ticks-per-quarter-note (TPQ) grid.

CONTEXT
-------
You receive a serialized snapshot of the open MuseScore score. Every pitch is a MIDI concert-pitch number (0-127; 60 = middle C). Every tick is on a 480-TPQ grid. Parts are 0-indexed; each part has staff(s) (staff index is 0-based within the part for multi-staff instruments like piano). Voices are 0-3 within a staff track.

The score snapshot lists measures with absolute ticks, and each note/rest with: tick, duration (480-TPQ ticks), MIDI pitch, MuseScore Tonal Pitch Class (TPC, -1 to 33), voice, staff.

RULES
-----
1. Only change what the user asks. Do not invent edits.
2. All tick values in your edits must be on the 480-TPQ scale shown in the snapshot.
3. All pitches in edits must be MIDI concert-pitch numbers. Provide MuseScore TPC values (-1 to 33) for exact written spelling.
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
  n = [[midi, MuseScore_TPC], ...]; tup = [numerator, denominator, total_ticks]

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


def load_local_config() -> Dict[str, str]:
    """Load the provider key without ever printing it or committing it."""
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bach-editor-config.json")
    config: Dict[str, Any] = {}
    try:
        with open(config_path, "r", encoding="utf-8") as config_file:
            loaded = json.load(config_file)
            if isinstance(loaded, dict):
                config = loaded
    except FileNotFoundError:
        pass
    except (OSError, json.JSONDecodeError) as error:
        print_error_and_exit("Could not read bach-editor-config.json: %s" % error)

    api_key = os.environ.get("DEEPSEEK_API_KEY", "").strip() or str(config.get("deepseek_api_key", "")).strip()
    model = str(config.get("model", DEFAULT_DEEPSEEK_MODEL)).strip() or DEFAULT_DEEPSEEK_MODEL
    if not api_key:
        print_error_and_exit(
            "DeepSeek is not configured. Create bach-editor-config.json beside copilot.py "
            "with your DeepSeek API key. See bach-editor-config.example.json."
        )
    return {"api_key": api_key, "model": model}


def call_bach_editor(
    score_context: str,
    musicxml: str,
    instruction: str,
    history: List[Tuple[str, str]],
    conversation_id: str = "",
) -> Dict[str, Any]:
    """Call DeepSeek directly; no Nzumari backend, auth, or cloud context lookup."""
    config = load_local_config()
    history_text = ""
    if history:
        history_text = "\n\nCONVERSATION SO FAR:\n" + "\n".join(
            "User: %s\nBach: %s" % (question, answer) for question, answer in history
        )

    user_content = (
        "USER REQUEST:\n" + instruction + history_text
        + "\n\nCURRENT SCORE SNAPSHOT (authoritative tick/pitch coordinates):\n"
        + score_context
        + "\n\nORIGINAL MUSICXML (for notation, instruments, key, meter and musical context):\n"
        + musicxml
    )
    payload = {
        "model": config["model"],
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ],
        "stream": False,
        "thinking": {"type": "disabled"},
        "temperature": 0.7,
        "max_tokens": 6000,
    }
    request = Request(
        DEEPSEEK_BASE_URL,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + config["api_key"],
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )

    started = time.monotonic()
    try:
        with urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            response_body = response.read().decode("utf-8")
    except HTTPError as error:
        try:
            detail = json.loads(error.read().decode("utf-8"))
            provider_message = detail.get("error", {}).get("message") if isinstance(detail.get("error"), dict) else detail.get("error")
        except Exception:
            provider_message = ""
        if error.code in (401, 403):
            message = "DeepSeek authentication failed. Check the API key in bach-editor-config.json."
        elif error.code == 402:
            message = "DeepSeek API balance is insufficient."
        elif error.code == 429:
            message = "DeepSeek rate limit reached. Wait briefly and try again."
        else:
            message = "DeepSeek API returned HTTP %s%s" % (
                error.code, (": " + str(provider_message)[:500]) if provider_message else ""
            )
        print_error_and_exit(message, code="deepseek_http_%s" % error.code)
    except (URLError, TimeoutError, OSError) as error:
        print_error_and_exit("Could not reach DeepSeek directly: %s" % error)

    try:
        data = json.loads(response_body)
    except json.JSONDecodeError:
        print_error_and_exit("DeepSeek returned invalid JSON.")

    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    if not isinstance(content, str) or not content.strip():
        finish_reason = choice.get("finish_reason", "unknown")
        print_error_and_exit("DeepSeek returned no final content (finish_reason: %s)." % finish_reason)

    try:
        result = _extract_json(content)
    except ValueError:
        print_error_and_exit("DeepSeek's response was not valid Bach edit JSON.")

    if not isinstance(result, dict):
        print_error_and_exit("Malformed DeepSeek response: expected a JSON object.")
    result.setdefault("generation_seconds", round(time.monotonic() - started, 1))
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

    # 2. Keep both representations: the compact snapshot is useful for tick lookup,
    # while the original MusicXML preserves the notation details AiHUD gives its model.
    score_context = serialize_score(score)
    try:
        with open(args.src, "r", encoding="utf-8") as musicxml_file:
            musicxml = musicxml_file.read()
    except OSError as error:
        print_error_and_exit("Could not read the exported MusicXML: %s" % error)
    # Remove inter-tag indentation only; preserve all musical text and attributes.
    musicxml = re.sub(r">\s+<", "><", musicxml).strip()

    # 3. Send the score directly to DeepSeek (the Nzumari web backend is bypassed).
    llm_report = call_bach_editor(score_context, musicxml, args.instruction, history)

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