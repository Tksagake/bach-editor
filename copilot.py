#!/usr/bin/env python3
"""
copilot.py — local MuseScore score parser and direct DeepSeek client.
"""

import sys
import json
import argparse
import os
import re
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Tuple
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import time

TPQ = 480  

REPORT_PATH = ""

DEEPSEEK_BASE_URL = "https://api.deepseek.com/chat/completions"
DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-pro"
REQUEST_TIMEOUT_SECONDS = 300

def print_error_and_exit(message: str, code: str = "", request_id: str = "") -> None:
    err = {"status": "error", "message": message}
    if code: err["code"] = code
    if request_id: err["request_id"] = request_id
    _write_report_file(err)
    print(json.dumps(err))
    sys.exit(1)

def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bach AI Local Backend")
    parser.add_argument("src", help="Path to the exported MusicXML file")
    parser.add_argument("instruction", help="User's prompt")
    parser.add_argument("-o", "--output", help="Output path (optional/debug)", default="")
    parser.add_argument("--yes", action="store_true", help="Force apply without confirmation")
    parser.add_argument("--question", action="append", default=[])
    parser.add_argument("--answer", action="append", default=[])
    parser.add_argument("--conversation-id", default="", help=argparse.SUPPRESS)
    parser.add_argument("--report", default="", help="Write the JSON report to this path atomically")
    return parser.parse_args()

def _write_report_file(payload: Dict[str, Any]) -> None:
    if not REPORT_PATH: return
    tmp_path = REPORT_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp_path, REPORT_PATH)

STEP_INDEX = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

def _midi_pitch(step: str, octave: int, alter: int) -> int:
    return (octave + 1) * 12 + STEP_INDEX[step] + alter

def _written_tpc(step: str, alter: int) -> int:
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
        self.tick, self.dur480, self.midi, self.tpc = tick, dur480, midi, tpc
        self.is_rest, self.is_chord_member, self.voice, self.staff = is_rest, is_chord_member, voice, staff

class MusicXMLMeasure:
    __slots__ = ("number", "start_tick", "end_tick", "divisions", "fifths", "beats", "beat_type", "notes")
    def __init__(self, number, start_tick):
        self.number = number
        self.start_tick, self.end_tick = start_tick, start_tick
        self.divisions, self.fifths, self.beats, self.beat_type = 2, 0, 4, 4
        self.notes: List[MusicXMLNote] = []

class MusicXMLPart:
    __slots__ = ("id", "name", "measures", "divisions", "fifths", "beats", "beat_type")
    def __init__(self, pid, name):
        self.id, self.name = pid, name
        self.measures: List[MusicXMLMeasure] = []
        self.divisions, self.fifths, self.beats, self.beat_type = 2, 0, 4, 4

class MusicXMLScore:
    def __init__(self):
        self.parts: List[MusicXMLPart] = []
        self.ticks_per_quarter = 2 

def parse_musicxml(file_path: str) -> MusicXMLScore:
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
    except Exception as e:
        print_error_and_exit(f"Failed to parse MusicXML: {str(e)}")

    tag = root.tag.split("}")[-1] if "}" in root.tag else root.tag
    score = MusicXMLScore()

    part_list = root.find("part-list")
    id_to_name = {}
    if part_list is not None:
        for sp in part_list.findall("score-part"):
            pid = sp.get("id")
            name_el = sp.find("part-name")
            id_to_name[pid] = name_el.text if name_el is not None else pid

    if tag == "score-timewise":
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
    divisions, fifths, beats, beat_type = part.divisions, part.fifths, part.beats, part.beat_type

    attrs = m_el.find("attributes")
    if attrs is not None:
        d = attrs.findtext("divisions")
        if d: divisions = int(d)
        k = attrs.find("key")
        if k is not None: fifths = int(k.findtext("fifths", str(fifths)) or fifths)
        t = attrs.find("time")
        if t is not None:
            beats = int(t.findtext("beats", str(beats)) or beats)
            beat_type = int(t.findtext("beat-type", str(beat_type)) or beat_type)

    part.divisions, part.fifths, part.beats, part.beat_type = divisions, fifths, beats, beat_type
    score.ticks_per_quarter = divisions

    measure = MusicXMLMeasure(number, start_tick=0)
    measure.divisions, measure.fifths, measure.beats, measure.beat_type = divisions, fifths, beats, beat_type
    part.measures.append(measure)

    factor = TPQ / divisions
    running_div = 0
    last_start: Dict[Tuple[int, int], int] = {}

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

        if not is_chord: last_start[key] = tick_div

        if is_rest:
            measure.notes.append(MusicXMLNote(int(tick_div * factor), int(dur_div * factor), -1, 0, True, False, voice, staff))
        else:
            pitch_el = child.find("pitch")
            if pitch_el is not None:
                midi, tpc = _parse_pitch(pitch_el)
                measure.notes.append(MusicXMLNote(int(tick_div * factor), int(dur_div * factor), midi, tpc, False, is_chord, voice, staff))

        if not is_chord: running_div += dur_div

def _finalize_measure_ticks(score: MusicXMLScore) -> None:
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

def serialize_score(score: MusicXMLScore) -> str:
    lines: List[str] = [f"TICKS_PER_QUARTER: {TPQ}", f"PARTS: {len(score.parts)}"]
    for p_idx, part in enumerate(score.parts):
        staff_count = max((n.staff for m in part.measures for n in m.notes), default=0) + 1
        lines.append(f"\nPART {p_idx} (id={part.id}, name='{part.name}', staves={staff_count}):")
        for m in part.measures:
            lines.append(f"  MEASURE {m.number} (tick {m.start_tick}-{m.end_tick}, key={m.fifths} fifths, {m.beats}/{m.beat_type}):")
            for n in m.notes:
                if n.is_rest:
                    lines.append(f"    REST tick={n.tick} dur={n.dur480} voice={n.voice} staff={n.staff}")
                else:
                    lines.append(f"    NOTE tick={n.tick} dur={n.dur480} midi={n.midi} tpc={n.tpc} voice={n.voice} staff={n.staff} chord_member={n.is_chord_member}")
    return "\n".join(lines)

SYSTEM_PROMPT = """CRITICAL: OUTPUT RAW JSON ONLY. NO INTRODUCTORY TEXT, NO EXPLANATION, NO MARKDOWN FENCES OUTSIDE THE JSON OBJECT.

You are an expert MuseScore 4 notation editor.

CONTEXT
-------
You receive a serialized snapshot of the open MuseScore score. 
Parts are 0-indexed; each part has staff(s) (0-indexed). Voices are 0-3.

RULES
-----
1. Only change what the user asks. Do not invent edits outside the requested scope.
2. Output your response as structured JSON.
3. First, provide a "plan" describing the musical intent (e.g., key, progression, voices).
4. For NOTE writing, use the "measures" array.
5. Specify durations as fractions of a whole note (e.g., "1/4" = quarter, "1/8" = eighth, "3/8" = dotted quarter, "1/2" = half).
6. Specify pitches as standard scientific pitch (e.g., "G4", "F#4", "Bb3"). Use "rest" for rests. For chords, use a list of strings: ["C4", "E4", "G4"].
7. If the request is ambiguous, return status "question" with kind "clarify" and options.
8. If the user asks for dynamics, lyrics, or marks, output them in the "edits" array with absolute 480-TPQ ticks.

OUTPUT SCHEMA
-------------
{
  "status": "applied",
  "plan": "8-bar period in G major, ending in a perfect cadence...",
  "measures": [
    {
      "part": 0,
      "staff": 0,
      "voice": 0,
      "measure_number": 1,
      "events": [
        { "pitch": "G4", "duration": "1/4" },
        { "pitch": "rest", "duration": "1/8" },
        { "pitch": ["D4", "F#4"], "duration": "1/8" },
        { "pitch": "E4", "duration": "1/2" }
      ]
    }
  ],
  "edits": [
    { "op":"mark", "name":"Dynamics", "part":0, "staff":0, "marks":[ {"t":0, "kind":"dyn", "text":"mf"} ] },
    { "op":"slur", "name":"Phrase", "part":0, "staff":0, "slurs":[ {"t1":0, "p1":[67], "t2":480, "p2":[62]} ] }
  ]
}

QUESTION RESPONSE (if ambiguous):
{
  "status": "question",
  "kind": "clarify",
  "question": "Which staff should I add the melody to?",
  "options": ["Staff 1", "Staff 2"]
}

Return strictly one JSON object. No markdown fences.
"""

def _strip_markdown_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        parts = text.split("```", 2)
        if len(parts) >= 3:
            text = parts[1]
            if text.lstrip().startswith(("json", "JSON")):
                text = text.split("\n", 1)[1] if "\n" in text else ""
    return text.strip()

def _extract_json(text: str) -> Dict[str, Any]:
    cleaned = _strip_markdown_fences(text)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass

    # Aggressive fallback: search for a JSON object containing "status"
    match = re.search(r'(\{[\s\S]*"status"\s*:\s*"[^"]+"[\s\S]*\})', cleaned)
    if match:
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            pass

    # Fallback to brace-matching
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
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bach-editor-config.json")
    config: Dict[str, Any] = {}
    try:
        with open(config_path, "r", encoding="utf-8") as config_file:
            loaded = json.load(config_file)
            if isinstance(loaded, dict): config = loaded
    except FileNotFoundError: pass
    except (OSError, json.JSONDecodeError) as error:
        print_error_and_exit("Could not read bach-editor-config.json: %s" % error)

    api_key = os.environ.get("DEEPSEEK_API_KEY", "").strip() or str(config.get("deepseek_api_key", "")).strip()
    model = str(config.get("model", DEFAULT_DEEPSEEK_MODEL)).strip() or DEFAULT_DEEPSEEK_MODEL
    if not api_key:
        print_error_and_exit("DeepSeek is not configured. Create bach-editor-config.json beside copilot.py.")
    return {"api_key": api_key, "model": model}

def call_bach_editor(score_context: str, musicxml: str, instruction: str, history: List[Tuple[str, str]], conversation_id: str = "") -> Dict[str, Any]:
    config = load_local_config()
    history_text = ""
    if history:
        history_text = "\n\nCONVERSATION SO FAR:\n" + "\n".join(f"User: {q}\nBach: {a}" for q, a in history)

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
        "temperature": 0.3,
        "max_tokens": 20000,
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
        print_error_and_exit(f"DeepSeek API returned HTTP {error.code}")
    except (URLError, TimeoutError, OSError) as error:
        print_error_and_exit("Could not reach DeepSeek directly: %s" % error)

    try: data = json.loads(response_body)
    except json.JSONDecodeError: print_error_and_exit("DeepSeek returned invalid JSON.")

    choice = (data.get("choices") or [{}])[0]
    content = choice.get("message", {}).get("content")
    if not content:
        print_error_and_exit("DeepSeek returned no final content.")

    try: result = _extract_json(content)
    except ValueError: print_error_and_exit("DeepSeek's response was not valid Bach edit JSON.")

    result.setdefault("generation_seconds", round(time.monotonic() - started, 1))
    return result

def compile_llm_measures_to_ops(llm_report: Dict[str, Any], score: MusicXMLScore) -> None:
    """Compiles high-level musical strings into low-level deterministic QML write operations."""
    if llm_report.get("status") != "applied": return
    
    edits = llm_report.get("edits", [])
    if not isinstance(edits, list): edits = []
        
    measures = llm_report.pop("measures", [])
    if not isinstance(measures, list): measures = []
        
    for m_data in measures:
        p_idx = m_data.get("part", 0)
        s_idx = m_data.get("staff", 0)
        v_idx = m_data.get("voice", 0)
        m_num = m_data.get("measure_number", 1)

        start_tick = -1
        end_tick = -1
        if p_idx < len(score.parts):
            for m_obj in score.parts[p_idx].measures:
                if m_obj.number == m_num:
                    start_tick = m_obj.start_tick
                    end_tick = m_obj.end_tick
                    break
        
        if start_tick < 0: continue
        
        expected_ticks = end_tick - start_tick
        events = []
        curr_tick = start_tick
        sum_ticks = 0
        
        for ev in m_data.get("events", []):
            dur_str = str(ev.get("duration", "1/4"))
            try:
                num, den = map(int, dur_str.split('/'))
                dur_ticks = int((num / den) * 4 * TPQ)
            except:
                dur_ticks = TPQ
                
            # Auto-truncate to prevent breaking the bar
            if sum_ticks + dur_ticks > expected_ticks:
                dur_ticks = expected_ticks - sum_ticks
            
            if dur_ticks <= 0: break
            
            pitch_data = ev.get("pitch", "rest")
            out_ev = {"t": curr_tick, "d": dur_ticks}
            
            if pitch_data == "rest" or not pitch_data:
                out_ev["rest"] = True
            else:
                if isinstance(pitch_data, str): pitch_data = [pitch_data]
                n_list = []
                for p_str in pitch_data:
                    m = re.match(r"^([a-gA-G])([#b♭♯]*)(-?\d+)$", p_str.strip())
                    if m:
                        step, acc, oct_str = m.groups()
                        step = step.upper()
                        octave = int(oct_str)
                        alter = 0
                        for char in acc:
                            if char in ('#', '♯'): alter += 1
                            elif char in ('b', '♭'): alter -= 1
                        midi = _midi_pitch(step, octave, alter)
                        tpc = _written_tpc(step, alter)
                        n_list.append([midi, tpc])
                    else:
                        n_list.append([60, 14]) # Fallback C4
                out_ev["n"] = n_list
                
            events.append(out_ev)
            curr_tick += dur_ticks
            sum_ticks += dur_ticks
            
        # Auto-pad with rest if underflowing to prevent rhythmic corruption
        if sum_ticks < expected_ticks:
            events.append({"t": curr_tick, "d": expected_ticks - sum_ticks, "rest": True})
            
        if events:
            edits.append({
                "op": "write",
                "name": f"AI Gen Part {p_idx+1} Staff {s_idx+1} M{m_num}",
                "part": p_idx,
                "staff": s_idx,
                "voice": v_idx,
                "start": start_tick,
                "end": end_tick,
                "replace": True,
                "events": events
            })
            
    llm_report["edits"] = edits

def validate_report(report: Dict[str, Any]) -> None:
    status = report.get("status")
    if status not in ("question", "applied", "error"):
        print_error_and_exit(f"Invalid status '{status}' in LLM report.")
    if status == "question":
        report.setdefault("kind", "clarify")
        report.setdefault("options", [])
        return
    if status == "applied":
        edits = report.get("edits", [])
        if not isinstance(edits, list): print_error_and_exit("Applied response missing 'edits' array.")
        report.setdefault("edit_notes", [])
        report.setdefault("edit_summary", {})

def main() -> None:
    global REPORT_PATH
    args = parse_arguments()
    REPORT_PATH = args.report
    history = list(zip(args.question, args.answer))
    score = parse_musicxml(args.src)
    score_context = serialize_score(score)
    try:
        with open(args.src, "r", encoding="utf-8") as musicxml_file:
            musicxml = musicxml_file.read()
    except OSError as error:
        print_error_and_exit("Could not read the exported MusicXML: %s" % error)
    
    musicxml = re.sub(r">\s+<", "><", musicxml).strip()
    llm_report = call_bach_editor(score_context, musicxml, args.instruction, history)
    
    compile_llm_measures_to_ops(llm_report, score)
    validate_report(llm_report)
    _write_report_file(llm_report)
    print(json.dumps(llm_report))

    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f: f.write(score_context)
        except Exception: pass
    sys.exit(0)

if __name__ == "__main__":
    main()