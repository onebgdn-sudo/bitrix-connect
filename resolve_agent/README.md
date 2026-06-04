# Resolve Chat Agent

This is a floating chat window for DaVinci Resolve Studio.

## What it does

- opens a custom chat window inside Resolve
- sends messages to Yandex GPT
- analyzes natural-language editing requests
- executes Resolve actions through the official Python Scripting API
- uses `resolve_manual.md` and the local Blackmagic API reference as operating context

## Files

- `resolve_chat_agent.lua`
- `resolve_agent_backend.py`
- `resolve_manual.md`

## Install

Copy or symlink both files into:

`~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`

Then restart Resolve or refresh the Scripts menu.

## Environment

The backend reads these variables from `.env`:

- `YANDEX_API_KEY` or `YANDEX_IAM_TOKEN`
- `YANDEX_MODEL_URI`
- `YANDEX_API_URL`
- `RESOLVE_API_REFERENCE` optional path to the Blackmagic scripting README
- `RESOLVE_AGENT_CONTEXT_CHAR_LIMIT` optional prompt context budget, default `14000`

## Control model

The model returns JSON actions. The primary action is `execute_resolve_python`,
which runs generated Python code against the live Resolve API objects.
The backend selects only relevant manual/API excerpts for each user request
instead of sending the full Resolve API reference every time.

Common requests are routed through `call_helper` capabilities first. The
backend executes action plans step by step, records Resolve state before and
after each action, and asks the model for one repair plan if a step fails.

## Reference index

The backend builds a local retrieval index at `.resolve_reference_index.json`.
It stores manual/API chunks and token statistics, then retrieves the most
relevant chunks for each request. The index is rebuilt automatically when
`resolve_manual.md` or the Blackmagic scripting README changes.
