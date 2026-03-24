#!/usr/bin/env python3
"""
Call Intelligence Pipeline — Meeting Recorder Product
Transcribes recordings via AssemblyAI and produces structured meeting
briefs via Claude CLI.

All output goes to stdout as JSON. All progress/status goes to stderr.
The calling Swift app handles file writing and notifications.

Usage:
    python3 call-analyzer.py <audio_path> --entity <entity> [--meeting-name "Name"] [--date YYYY-MM-DD] [--attendees "Alice,Bob"]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional


def log(msg: str):
    """Print to stderr so stdout stays clean for JSON output."""
    print(msg, file=sys.stderr)


def slugify(text: str) -> str:
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_]+", "-", text)
    text = re.sub(r"-+", "-", text)
    return text.strip("-")


def detect_date_from_filename(filename: str) -> Optional[str]:
    m = re.search(r"(20\d{2})[_-](\d{2})[_-](\d{2})", filename)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    return None


def generate_meeting_name(filename: str, date_str: str) -> str:
    name = Path(filename).stem
    name = re.sub(r"20\d{2}[_-]\d{2}[_-]\d{2}[_-]?\d*[_-]?\d*[_-]?\d*", "", name)
    name = name.replace("_", " ").replace("-", " ").strip()
    name = re.sub(r"\s+", " ", name)
    if name:
        return name.title()
    return f"Meeting {date_str}"


# ── Pipeline Steps ─────────────────────────────────────────────────────

def transcribe(audio_path: str) -> dict:
    import assemblyai as aai

    api_key = os.environ.get("ASSEMBLYAI_API_KEY")
    if not api_key:
        log("ERROR: ASSEMBLYAI_API_KEY not set in environment")
        sys.exit(1)

    aai.settings.api_key = api_key

    log(f"  Uploading and transcribing: {os.path.basename(audio_path)}")
    log("  This may take several minutes for long recordings...")

    config = aai.TranscriptionConfig(
        speaker_labels=True,
        language_code="en",
        speech_models=["universal-3-pro"],
    )

    transcriber = aai.Transcriber()
    transcript = transcriber.transcribe(audio_path, config=config)

    if transcript.status == aai.TranscriptStatus.error:
        log(f"ERROR: AssemblyAI transcription failed: {transcript.error}")
        sys.exit(1)

    speaker_text = ""
    for utterance in transcript.utterances:
        speaker_text += f"Speaker {utterance.speaker}: {utterance.text}\n\n"

    duration_min = round(transcript.audio_duration / 60, 1)
    speakers = sorted(set(u.speaker for u in transcript.utterances))

    log(f"  Transcription complete: {duration_min} min, {len(speakers)} speakers, {len(transcript.utterances)} utterances")

    return {
        "speaker_text": speaker_text,
        "full_text": transcript.text,
        "duration_min": duration_min,
        "speakers": speakers,
        "utterance_count": len(transcript.utterances),
    }


def _fallback_output(meeting_name: str, date_str: str, entity: str,
                     transcript_data: dict) -> str:
    return f"""# {meeting_name} — {date_str}

**Source:** AssemblyAI (Claude analysis failed — raw transcript only)
**Entity:** {entity}
**Duration:** {transcript_data['duration_min']} minutes
**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}

---

## Raw Transcript

{transcript_data['speaker_text']}"""


ANALYSIS_PROMPT = """You are analyzing a meeting transcript. Produce a structured summary following the format below. Be thorough — this summary will be used for follow-up planning and reference.

### Output Format

## Meeting Overview
- Date, duration (estimate from transcript length)
- All attendees with confirmed names and roles
- Purpose of the meeting

## Executive Summary
3-5 sentence overview of what was discussed and the key takeaway.

## Key Discussion Points
For EACH major topic discussed, create a subsection:
### [Topic]
- Summary of what was discussed
- Include direct quotes for anything specific or quantifiable
- Note who raised the topic and any decisions made

## Decisions & Consensus
Any points where the group agreed, disagreed, or made a decision.

## Action Items & Next Steps
Bulleted list of committed or implied next steps, with owner if stated.

## Attendee Roster
Final confirmed list of names, roles, and contact info if mentioned.

---

### Guidelines
- Preserve exact quotes when someone states a number, priority, or strong opinion
- Flag any names or roles that seem uncertain
- If speakers aren't labeled, infer from context and note your confidence
- Prioritize detail over brevity — this is a reference document
- Note anything said "off the cuff" that reveals strategic insight"""


def analyze(transcript_data: dict, meeting_name: str, entity: str,
            date_str: str, attendees: Optional[str]) -> str:
    context_lines = [
        f"**Meeting context:** {meeting_name}",
        f"**Entity:** {entity}",
        f"**Date:** {date_str}",
    ]
    if attendees:
        context_lines.append(f"**Known attendees:** {attendees}")

    context_block = "\n".join(context_lines)

    full_prompt = f"""{ANALYSIS_PROMPT}

{context_block}

IMPORTANT OUTPUT INSTRUCTIONS:
- Output ONLY the markdown analysis. No preamble, no "Here is the analysis", no closing remarks.
- Start directly with the # heading.
- Use this exact heading: # {meeting_name} — {date_str}
- After the heading, include this metadata block:

**Source:** AssemblyAI + Claude Analysis
**Entity:** {entity}
**Duration:** {transcript_data['duration_min']} minutes
**Speakers detected:** {len(transcript_data['speakers'])}
**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}

---

- At the end, include a "Full Transcript" section in a collapsed <details> block.
- Map speaker labels (Speaker A, Speaker B, etc.) to real names where you can infer them from conversation context.

## Transcript

{transcript_data['speaker_text']}"""

    log("  Running Claude analysis...")

    env = os.environ.copy()
    env.pop("CLAUDECODE", None)

    try:
        result = subprocess.run(
            ["claude", "-p", "--output-format", "text"],
            input=full_prompt,
            capture_output=True,
            text=True,
            timeout=1800,
            env=env,
        )
    except subprocess.TimeoutExpired:
        log("  ERROR: Claude CLI timed out after 30 minutes.")
        return _fallback_output(meeting_name, date_str, entity, transcript_data)

    if result.returncode != 0:
        log(f"WARNING: Claude CLI returned exit code {result.returncode}")
        if result.stderr:
            log(f"  stderr: {result.stderr[:500]}")
        if not result.stdout.strip():
            log("  Claude produced no output. Using raw transcript as fallback.")
            return _fallback_output(meeting_name, date_str, entity, transcript_data)

    return result.stdout.strip()


# ── Main ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Call Intelligence Pipeline — transcribe and analyze meeting recordings"
    )
    parser.add_argument("file_path", help="Path to the audio recording")
    parser.add_argument("--entity", required=True, help="Entity (team/client) name")
    parser.add_argument("--meeting-name", default=None,
                        help="Human-readable meeting name (auto-generated if omitted)")
    parser.add_argument("--date", default=None,
                        help="Meeting date YYYY-MM-DD (auto-detected from filename if omitted)")
    parser.add_argument("--attendees", default=None,
                        help="Comma-separated attendee names to help speaker identification")

    args = parser.parse_args()

    audio_path = os.path.expanduser(args.file_path)
    if not os.path.isfile(audio_path):
        log(f"ERROR: File not found: {audio_path}")
        sys.exit(1)

    date_str = args.date or detect_date_from_filename(os.path.basename(audio_path))
    if not date_str:
        date_str = datetime.now().strftime("%Y-%m-%d")
        log(f"  No date detected — using today: {date_str}")

    meeting_name = args.meeting_name or generate_meeting_name(
        os.path.basename(audio_path), date_str
    )
    slug = slugify(meeting_name)

    log(f"\n{'='*60}")
    log(f"  Meeting Recorder — Analysis Pipeline")
    log(f"  Meeting:  {meeting_name}")
    log(f"  Date:     {date_str}")
    log(f"  Entity:   {args.entity}")
    log(f"  File:     {os.path.basename(audio_path)}")
    if args.attendees:
        log(f"  Attendees: {args.attendees}")
    log(f"{'='*60}\n")

    # Step 1: Transcribe
    log("[1/2] Transcribing via AssemblyAI...")
    transcript_data = transcribe(audio_path)

    # Step 2: Analyze
    log("\n[2/2] Analyzing via Claude...")
    analysis = analyze(transcript_data, meeting_name, args.entity, date_str, args.attendees)

    # Output JSON to stdout — Swift app handles file writing
    output = {
        "meeting_name": meeting_name,
        "date": date_str,
        "slug": slug,
        "entity": args.entity,
        "analysis": analysis,
    }
    print(json.dumps(output))

    log(f"\n  Done! Analysis ready for: {meeting_name}")


if __name__ == "__main__":
    main()
