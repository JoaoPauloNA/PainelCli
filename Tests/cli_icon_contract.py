#!/usr/bin/env python3
"""Guards the shared CLI identity appearance between detected and manual rows."""
from pathlib import Path
import sys


source = (Path(__file__).resolve().parents[1] / "Sources/main.swift").read_text(encoding="utf-8")
failures: list[str] = []
entry_list_start = source.find("private func renderEntryList(in body: NSView)")
icon_start = source.find("let icon = NSImageView()", entry_list_start)
icon_end = source.find("icon.imageScaling =", icon_start)
icon_block = source[icon_start:icon_end] if icon_start >= 0 and icon_end > icon_start else ""

if "detectedAppearance(for: installation.target)" not in icon_block:
    failures.append("detected rows do not use the shared CLI appearance mapper")
if "CLIDiscoveryTarget(rawValue: entry.provider)" not in icon_block:
    failures.append("manual rows are not mapped to their matching detection target")
manual_appearance = icon_block.find("detectedAppearance(for: target)")
if manual_appearance < 0:
    failures.append("manual rows do not reuse the detected CLI symbol and tint")
fallback = icon_block.find("icon.image = cliSymbol()")
if fallback >= 0 and manual_appearance >= 0 and fallback < manual_appearance:
    failures.append("generic terminal fallback shadows the mapped manual provider icon")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("CLI icon contract passed: manual and detected rows share provider symbol and tint.")
