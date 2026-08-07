#!/usr/bin/env python3
"""Ingest de1app TCL or v2 JSON profiles into Decent format.

Supports:
  - de1app TCL profiles with advanced_shot steps (e.g. from de1app/de1plus/profiles/)
  - v2 JSON profiles that already have steps
  - Legacy TCL profiles (settings_2a/2b) are rejected because their stored frames
    are not authoritative

Usage:
    # Convert specific profiles (auto-detects format by extension)
    python3 tools/ingest_profiles.py path/to/profile.json -o assets/defaultProfiles/
    python3 tools/ingest_profiles.py path/to/profile.tcl -o assets/defaultProfiles/

    # Convert multiple profiles (mixed formats OK)
    python3 tools/ingest_profiles.py profiles/*.json de1app/profiles/*.tcl -o assets/defaultProfiles/

    # Dry run (print converted JSON to stdout)
    python3 tools/ingest_profiles.py path/to/profile.tcl --dry-run

    # Also update manifest.json
    python3 tools/ingest_profiles.py profiles/*.json -o assets/defaultProfiles/ --update-manifest
"""

import argparse
import json
import os
import re
import sys

VALID_BEVERAGE_TYPES = {"espresso", "calibrate", "cleaning", "manual", "pourover"}

BEVERAGE_TYPE_MAP = {
    "filter": "pourover",
    "tea": "pourover",
    "tea_portafilter": "pourover",
    "descale": "cleaning",
}


def strip_tcl_braces(value):
    """Remove TCL artifact curly braces from string values."""
    if isinstance(value, str) and value.startswith("{") and value.endswith("}"):
        return value[1:-1]
    return value



def parse_tcl_profile(content):
    """Parse a de1app TCL profile into a dict matching v2 JSON structure.

    TCL profiles have two parts:
    1. advanced_shot - a TCL list of step dicts (may be empty for legacy profiles)
    2. Flat key-value pairs for profile metadata and legacy settings

    Returns a dict that can be fed into convert_profile().
    """
    result = {}

    advanced_match = re.match(r'^advanced_shot\s+(.*)', content, re.MULTILINE)
    raw_steps_str = ""
    if advanced_match:
        raw_steps_str = advanced_match.group(1).strip()

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("advanced_shot"):
            continue
        match = re.match(r'^(\S+)\s+(.*)', line)
        if match:
            key = match.group(1)
            val = match.group(2).strip()
            if val.startswith("{") and val.endswith("}"):
                val = val[1:-1]
            result[key] = val

    profile = {
        "title": result.get("profile_title", ""),
        "author": result.get("author", ""),
        "notes": result.get("profile_notes", ""),
        "beverage_type": result.get("beverage_type", "espresso"),
        "version": "2",
        "tank_desired_water_temperature": float(
            result.get("tank_desired_water_temperature", 0)
        ),
        "target_weight": float(
            result.get("final_desired_shot_weight_advanced", 0)
        ),
        "target_volume": float(
            result.get("final_desired_shot_volume_advanced", 0)
        ),
        "number_of_preinfuse_frames": int(
            result.get("final_desired_shot_volume_advanced_count_start", 0)
        ),
    }

    settings_type = result.get("settings_profile_type", "")
    if settings_type in ("settings_2a", "settings_2b"):
        raise ValueError(
            f"de1app's stored advanced_shot is not authoritative for {settings_type} "
            "profiles. Reaprime intentionally does not regenerate those frames. "
            "Convert this profile externally into final advanced-profile JSON before "
            "ingestion."
        )

    steps = _parse_tcl_steps(raw_steps_str)
    if not steps and raw_steps_str not in ("", "{}"):
        raise ValueError("Failed to parse advanced_shot steps")

    profile["steps"] = steps
    return profile


def _parse_tcl_steps(raw):
    """Parse TCL advanced_shot list into a list of step dicts.

    The format is: {{key val key val ...} {key val key val ...} ...}
    Steps are delimited by {braces} inside the outer braces.
    """
    raw = raw.strip()
    if not raw or raw == "{}":
        return []

    if raw.startswith("{") and raw.endswith("}"):
        raw = raw[1:-1].strip()

    steps = []
    step_strings = _split_tcl_list(raw)

    for step_str in step_strings:
        step = _parse_tcl_step(step_str)
        if step:
            steps.append(step)

    return steps


def _split_tcl_list(raw):
    """Split a TCL list into its top-level elements.

    Handles nested {braces} correctly.
    """
    elements = []
    depth = 0
    current = []
    i = 0

    while i < len(raw):
        ch = raw[i]
        if ch == "{":
            if depth == 0:
                current = []
            else:
                current.append(ch)
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                elements.append("".join(current))
            else:
                current.append(ch)
        else:
            if depth > 0:
                current.append(ch)
        i += 1

    return elements


def _parse_tcl_step(step_str):
    """Parse a single TCL step string into a profile step dict.

    TCL step format: key1 val1 key2 val2 ...
    Values can be in {braces} if they contain spaces.
    """
    tokens = _tokenize_tcl(step_str.strip())
    if len(tokens) < 2:
        return None

    raw = {}
    i = 0
    while i < len(tokens) - 1:
        key = tokens[i]
        val = tokens[i + 1]
        raw[key] = val
        i += 2

    step = {
        "name": raw.get("name", ""),
        "pump": raw.get("pump", "pressure"),
        "transition": raw.get("transition", "fast"),
        "temperature": float(raw.get("temperature", 0)),
        "sensor": raw.get("sensor", "coffee"),
        "seconds": float(raw.get("seconds", 0)),
        "volume": float(raw.get("volume", 0)),
        "weight": float(raw.get("weight", 0)),
        "flow": float(raw.get("flow", 0)),
        "pressure": float(raw.get("pressure", 0)),
    }

    exit_if = int(raw.get("exit_if", 0))
    if exit_if:
        exit_type = raw.get("exit_type", "")
        if exit_type == "pressure_over":
            step["exit"] = {
                "type": "pressure",
                "condition": "over",
                "value": float(raw.get("exit_pressure_over", 0)),
            }
        elif exit_type == "pressure_under":
            step["exit"] = {
                "type": "pressure",
                "condition": "under",
                "value": float(raw.get("exit_pressure_under", 0)),
            }
        elif exit_type == "flow_over":
            step["exit"] = {
                "type": "flow",
                "condition": "over",
                "value": float(raw.get("exit_flow_over", 0)),
            }
        elif exit_type == "flow_under":
            step["exit"] = {
                "type": "flow",
                "condition": "under",
                "value": float(raw.get("exit_flow_under", 0)),
            }

    max_val = float(raw.get("max_flow_or_pressure", 0))
    max_range = float(raw.get("max_flow_or_pressure_range", 0))
    if max_val > 0 or max_range > 0:
        step["limiter"] = {
            "value": max_val,
            "range": max_range,
        }

    return step


def _tokenize_tcl(s):
    """Tokenize a TCL key-value string, handling {braced} values."""
    tokens = []
    i = 0
    while i < len(s):
        while i < len(s) and s[i] in " \t":
            i += 1
        if i >= len(s):
            break

        if s[i] == "{":
            depth = 1
            i += 1
            start = i
            while i < len(s) and depth > 0:
                if s[i] == "{":
                    depth += 1
                elif s[i] == "}":
                    depth -= 1
                i += 1
            tokens.append(s[start : i - 1])
        elif s[i] == '"':
            i += 1
            start = i
            while i < len(s) and s[i] != '"':
                i += 1
            tokens.append(s[start:i])
            i += 1
        else:
            start = i
            while i < len(s) and s[i] not in " \t":
                i += 1
            tokens.append(s[start:i])

    return tokens



def convert_step(step):
    """Convert a parsed profile step to Decent format."""
    converted = {
        "name": step["name"],
        "pump": step["pump"],
        "transition": step["transition"],
        "temperature": str(float(step["temperature"])),
        "sensor": step["sensor"],
        "seconds": str(float(step["seconds"])),
        "volume": str(float(step.get("volume", 0))),
        "weight": str(float(step.get("weight", 0))),
    }

    if step["pump"] == "flow":
        converted["flow"] = str(float(step.get("flow", 0)))
    else:
        converted["pressure"] = str(float(step.get("pressure", 0)))

    if step["pump"] == "flow":
        converted["pressure"] = str(float(step.get("pressure", 0)))
    else:
        converted["flow"] = str(float(step.get("flow", 0)))

    if "exit" in step and step["exit"]:
        exit_cond = step["exit"]
        converted["exit"] = {
            "type": exit_cond["type"],
            "condition": exit_cond["condition"],
            "value": str(float(exit_cond["value"])),
        }

    if "limiter" in step and step["limiter"]:
        limiter = step["limiter"]
        lim_value = float(limiter.get("value", 0))
        lim_range = float(limiter.get("range", 0))
        converted["limiter"] = {
            "value": str(lim_value),
            "range": str(lim_range),
        }

    return converted


def convert_profile(source):
    """Convert a parsed profile dict to Decent format."""
    beverage_type = strip_tcl_braces(source.get("beverage_type", "espresso"))
    beverage_type = BEVERAGE_TYPE_MAP.get(beverage_type, beverage_type)
    if beverage_type not in VALID_BEVERAGE_TYPES:
        raise ValueError(
            f"Unknown beverage_type '{beverage_type}' "
            f"(original: '{source.get('beverage_type')}')"
        )

    tank_temp = source.get(
        "tank_temperature",
        source.get("tank_desired_water_temperature", 0),
    )

    vol_count_start = source.get(
        "target_volume_count_start",
        source.get("number_of_preinfuse_frames", 0),
    )

    steps = [convert_step(s) for s in source.get("steps", [])]

    converted = {
        "version": str(source.get("version", "2")),
        "title": source.get("title", ""),
        "author": source.get("author", ""),
        "notes": source.get("notes", ""),
        "beverage_type": beverage_type,
        "steps": steps,
        "tank_temperature": str(float(tank_temp)),
        "target_weight": str(float(source.get("target_weight", 0))),
        "target_volume": str(float(source.get("target_volume", 0))),
        "target_volume_count_start": str(int(vol_count_start)),
        "type": "advanced",
        "hidden": "0",
    }

    return converted


def load_profile(input_path):
    """Load a profile from JSON or TCL file, returning a parsed dict."""
    with open(input_path) as f:
        content = f.read()

    if input_path.endswith(".tcl"):
        return parse_tcl_profile(content)
    else:
        return json.loads(content)


def update_manifest(output_dir, new_filenames):
    """Add new filenames to manifest.json if not already present."""
    manifest_path = os.path.join(output_dir, "manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)
    else:
        manifest = {
            "version": "1.0.0",
            "description": "Default espresso profiles bundled with Decent",
            "profiles": [],
        }

    existing = set(manifest["profiles"])
    added = []
    for name in new_filenames:
        if name not in existing:
            manifest["profiles"].append(name)
            added.append(name)

    manifest["profiles"].sort()

    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    return added


def main():
    parser = argparse.ArgumentParser(
        description="Ingest de1app TCL or v2 JSON profiles into Decent format"
    )
    parser.add_argument("profiles", nargs="+", help="Input profile files (.json or .tcl)")
    parser.add_argument("-o", "--output-dir", help="Output directory for converted profiles")
    parser.add_argument("--dry-run", action="store_true", help="Print to stdout instead of writing")
    parser.add_argument("--update-manifest", action="store_true", help="Update manifest.json")

    args = parser.parse_args()

    converted_filenames = []
    errors = []

    for input_path in args.profiles:
        filename = os.path.basename(input_path)
        out_filename = (
            filename.rsplit(".", 1)[0] + ".json" if filename.endswith(".tcl") else filename
        )
        try:
            source = load_profile(input_path)
            converted = convert_profile(source)

            if args.dry_run:
                print(f"=== {filename} -> {out_filename} ===")
                print(json.dumps(converted, indent=2))
                print()
            elif args.output_dir:
                output_path = os.path.join(args.output_dir, out_filename)
                with open(output_path, "w") as f:
                    json.dump(converted, f, indent=2)
                    f.write("\n")
                print(f"  OK  {filename} -> {output_path}")
                converted_filenames.append(out_filename)
            else:
                print(json.dumps(converted, indent=2))

        except Exception as e:
            errors.append((filename, str(e)))
            print(f"FAIL  {filename}: {e}", file=sys.stderr)

    if args.update_manifest and args.output_dir and converted_filenames:
        added = update_manifest(args.output_dir, converted_filenames)
        if added:
            print(f"\nAdded {len(added)} profiles to manifest.json")
        else:
            print("\nNo new profiles added to manifest (all already present)")

    if errors:
        print(f"\n{len(errors)} error(s):", file=sys.stderr)
        for name, err in errors:
            print(f"  {name}: {err}", file=sys.stderr)
        return 1

    print(f"\nConverted {len(converted_filenames)} profiles successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
