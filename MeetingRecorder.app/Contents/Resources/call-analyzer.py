#!/usr/bin/env python3
"""
Call Intelligence Pipeline — Meeting Recorder Product
Transcribes recordings via AssemblyAI and produces structured meeting
briefs via Claude CLI.

Usage:
    python3 call-analyzer.py <audio_path> --entity <entity> --output-dir <dir> [--meeting-name "Name"] [--date YYYY-MM-DD] [--attendees "Alice,Bob"] [--dry-run]
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional


# ── Helpers ────────────────────────────────────────────────────────────

def notify(title: str, message: str):
    """Send a macOS notification."""
    subprocess.run([
        "osascript", "-e",
        f'display notification "{message}" with title "{title}"'
    ], capture_output=True)


def slugify(text: str) -> str:
    """Convert text to a URL-friendly slug."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_]+", "-", text)
    text = re.sub(r"-+", "-", text)
    return text.strip("-")


def detect_date_from_filename(filename: str) -> Optional[str]:
    """Try to extract a YYYY-MM-DD date from the filename."""
    m = re.search(r"(20\d{2})[_-](\d{2})[_-](\d{2})", filename)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    return None


def generate_meeting_name(filename: str, date_str: str) -> str:
    """Generate a human-readable meeting name from the filename."""
    name = Path(filename).stem
    # Remove date patterns
    name = re.sub(r"20\d{2}[_-]\d{2}[_-]\d{2}[_-]?\d*[_-]?\d*[_-]?\d*", "", name)
    # Clean up
    name = name.replace("_", " ").replace("-", " ").strip()
    name = re.sub(r"\s+", " ", name)
    if name:
        return name.title()
    return f"Meeting {date_str}"


# ── Pipeline Steps ─────────────────────────────────────────────────────

def transcribe(audio_path: str) -> dict:
    """Upload and transcribe audio via AssemblyAI. Returns transcript data."""
    import assemblyai as aai

    api_key = os.environ.get("ASSEMBLYAI_API_KEY")
    if not api_key:
        print("ERROR: ASSEMBLYAI_API_KEY not set in environment")
        sys.exit(1)

    aai.settings.api_key = api_key

    print(f"  Uploading and transcribing: {os.path.basename(audio_path)}")
    print("  This may take several minutes for long recordings...")

    config = aai.TranscriptionConfig(
        speaker_labels=True,
        language_code="en",
        speech_models=["universal-3-pro"],
    )

    transcriber = aai.Transcriber()
    transcript = transcriber.transcribe(audio_path, config=config)

    if transcript.status == aai.TranscriptStatus.error:
        print(f"ERROR: AssemblyAI transcription failed: {transcript.error}")
        sys.exit(1)

    # Build speaker-labeled text
    speaker_text = ""
    for utterance in transcript.utterances:
        speaker_text += f"Speaker {utterance.speaker}: {utterance.text}\n\n"

    duration_min = round(transcript.audio_duration / 60, 1)
    speakers = sorted(set(u.speaker for u in transcript.utterances))

    print(f"  Transcription complete: {duration_min} min, {len(speakers)} speakers, {len(transcript.utterances)} utterances")

    return {
        "speaker_text": speaker_text,
        "full_text": transcript.text,
        "duration_min": duration_min,
        "speakers": speakers,
        "utterance_count": len(transcript.utterances),
    }


def _fallback_output(meeting_name: str, date_str: str, entity: str,
                     transcript_data: dict) -> str:
    """Fallback output when Claude analysis fails — saves raw transcript."""
    return f"""# {meeting_name} — {date_str}

**Source:** AssemblyAI (Claude analysis failed — raw transcript only)
**Entity:** {entity}
**Duration:** {transcript_data['duration_min']} minutes
**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}

---

## Raw Transcript

{transcript_data['speaker_text']}"""


# Embedded analysis prompt — no external file dependency
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
    """Run Claude CLI to analyze the transcript. Returns the markdown analysis."""

    # Build the full prompt with context
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

    print("  Running Claude analysis...")

    # Remove CLAUDECODE env var so claude -p works even when called from Claude Code
    env = os.environ.copy()
    env.pop("CLAUDECODE", None)

    try:
        result = subprocess.run(
            ["claude", "-p", "--output-format", "text"],
            input=full_prompt,
            capture_output=True,
            text=True,
            timeout=1800,  # 30 min — long transcripts need time
            env=env,
        )
    except subprocess.TimeoutExpired:
        print("  ERROR: Claude CLI timed out after 30 minutes.")
        print("  Saving raw transcript as fallback.")
        return _fallback_output(meeting_name, date_str, entity, transcript_data)

    if result.returncode != 0:
        print(f"WARNING: Claude CLI returned exit code {result.returncode}")
        if result.stderr:
            print(f"  stderr: {result.stderr[:500]}")
        if not result.stdout.strip():
            print("  Claude produced no output. Saving raw transcript as fallback.")
            return _fallback_output(meeting_name, date_str, entity, transcript_data)

    return result.stdout.strip()


def write_output(analysis: str, output_dir: str, entity: str,
                 date_str: str, slug: str, dry_run: bool) -> Path:
    """Write the analysis markdown to the output directory."""
    # Structure: output_dir/entity/meetings/date-slug.md
    meetings_dir = Path(output_dir) / entity / "meetings"
    meetings_dir.mkdir(parents=True, exist_ok=True)

    filename = f"{date_str}-{slug}.md"
    output_path = meetings_dir / filename

    if output_path.exists():
        print(f"  Overwriting existing file: {output_path}")
    else:
        print(f"  Writing new file: {output_path}")

    if not dry_run:
        output_path.write_text(analysis + "\n")

    return output_path


# ── Main ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Call Intelligence Pipeline — transcribe and analyze meeting recordings"
    )
    parser.add_argument("file_path", help="Path to the audio recording")
    parser.add_argument("--entity", required=True, help="Entity (team/client) name")
    parser.add_argument("--output-dir", required=True, help="Base directory for transcript output")
    parser.add_argument("--meeting-name", default=None,
                        help="Human-readable meeting name (auto-generated if omitted)")
    parser.add_argument("--date", default=None,
                        help="Meeting date YYYY-MM-DD (auto-detected from filename if omitted)")
    parser.add_argument("--attendees", default=None,
                        help="Comma-separated attendee names to help speaker identification")
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate analysis but don't write files")

    args = parser.parse_args()

    # Resolve and validate file path
    audio_path = os.path.expanduser(args.file_path)
    if not os.path.isfile(audio_path):
        print(f"ERROR: File not found: {audio_path}")
        sys.exit(1)

    # Determine date
    date_str = args.date or detect_date_from_filename(os.path.basename(audio_path))
    if not date_str:
        date_str = datetime.now().strftime("%Y-%m-%d")
        print(f"  No date detected — using today: {date_str}")

    # Determine meeting name
    meeting_name = args.meeting_name or generate_meeting_name(
        os.path.basename(audio_path), date_str
    )
    slug = slugify(meeting_name)

    print(f"\n{'='*60}")
    print(f"  Meeting Recorder — Analysis Pipeline")
    print(f"  Meeting:  {meeting_name}")
    print(f"  Date:     {date_str}")
    print(f"  Entity:   {args.entity}")
    print(f"  Output:   {args.output_dir}")
    print(f"  File:     {os.path.basename(audio_path)}")
    if args.attendees:
        print(f"  Attendees: {args.attendees}")
    if args.dry_run:
        print(f"  Mode:     DRY RUN")
    print(f"{'='*60}\n")

    # Step 1: Transcribe
    print("[1/3] Transcribing via AssemblyAI...")
    transcript_data = transcribe(audio_path)

    # Step 2: Analyze
    print("\n[2/3] Analyzing via Claude...")
    analysis = analyze(transcript_data, meeting_name, args.entity, date_str, args.attendees)

    # Step 3: Write output
    print("\n[3/3] Writing output...")
    output_path = write_output(analysis, args.output_dir, args.entity, date_str, slug, args.dry_run)

    # Notify
    if not args.dry_run:
        notify("Meeting Analysis Complete", f"{meeting_name} saved to {args.entity}/meetings/")

    print(f"\n{'='*60}")
    print(f"  Done! Analysis written to:")
    print(f"  {output_path}")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
