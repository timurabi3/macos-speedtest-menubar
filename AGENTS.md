# AGENTS.md - macOS Speedtest Menu Bar Widget

## Role
You are working inside the Codex landing folder for **macOS Speedtest Menu Bar Widget**.

## Operating Rules
- Lead with reality. Verify the real source/deploy path before changing anything.
- Never print secret values. It is fine to name env var names and secret file locations.
- Treat imported Claude/Obsidian/persona files as historical context unless the user explicitly says otherwise.
- Preserve user work. Do not delete or move original source folders unless Timur explicitly asks.
- For live Pi work, verify in this order: hostname -> deployed path -> service state -> fresh logs -> config/env names.

## Project Summary
Mac menu-bar network speed widget request: live download/upload top speed, visually similar to speedtest.net and more polished than prior Stats widget.

## Status
Historical/open Codex thread from prompt history; final working state unclear.

## High-Signal Facts
- User wanted live top download/upload speed in Mbps, updated as close to real time as practical.
- Old issue: widget appeared on the wrong side, got stuck, or showed only a red ST indicator.
- Prompt history mentions SpeedtestMenuBar.swift runner LaunchAgent.
- Attached screenshots show Stats-style menubar numbers and speedtest.net visual target.

## Gotchas
- Not discussed.
