# REAPER Agent

This is the starter chat window for REAPER.

## What it does

- opens a chat window inside REAPER
- sends messages to Yandex GPT as a planner
- executes only tools from the local tool registry
- supports voice input

## Architecture

- `reaper_chat_agent.lua` keeps the UI, sends requests, and executes tool steps
- `reaper_agent_backend.py` turns natural language into a strict JSON plan
- `reaper_tool_registry.lua` holds tools, recipes, validation, and project snapshots
- `reaper_plugin_catalog.lua` holds the local FX/instrument catalog
- `reaper_reference_notes.md` is a developer reference for adding new tools

## Setup

1. Put these files in the same folder:
   - `reaper_chat_agent.lua`
   - `reaper_agent_backend.py`
   - `voice_stt.py`
   - `.env`
2. Fill `.env` with:
   - `YANDEX_API_KEY`
   - `YANDEX_MODEL_URI`
   - `YANDEX_FOLDER_ID`
   - `REAPER_RENDER_COMMAND_ID` if you want to override the default render command
3. Load `reaper_chat_agent.lua` in REAPER as a ReaScript and run it.
