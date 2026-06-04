#!/usr/bin/env python3
import argparse
import json
import os
import re
import time
from pathlib import Path
import sys
import urllib.request
import urllib.error


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def load_env() -> None:
    here = Path(__file__).resolve().parent
    load_env_file(here / ".env")
    load_env_file(Path.cwd() / ".env")


def latest_user_text(history) -> str:
    for item in reversed(history):
        if item.get("role") == "user":
            return item.get("content", "")
    return ""


def call_yandex(messages, temperature=0.1, max_tokens=900):
    api_key = os.getenv("YANDEX_API_KEY", "").strip()
    iam_token = os.getenv("YANDEX_IAM_TOKEN", "").strip()
    model_uri = os.getenv("YANDEX_MODEL_URI", "").strip()
    api_url = os.getenv(
        "YANDEX_API_URL",
        "https://llm.api.cloud.yandex.net/foundationModels/v1/completion",
    ).strip()

    if not model_uri:
        raise RuntimeError("YANDEX_MODEL_URI is not set")
    if not api_key and not iam_token:
        raise RuntimeError("YANDEX_API_KEY or YANDEX_IAM_TOKEN is not set")

    payload = {
        "modelUri": model_uri,
        "completionOptions": {
            "stream": False,
            "temperature": temperature,
            "maxTokens": str(max_tokens),
        },
        "messages": messages,
    }

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Api-Key {api_key}"
    else:
        headers["Authorization"] = f"Bearer {iam_token}"

    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = json.loads(response.read().decode("utf-8"))
            break
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
            last_error = exc
            if attempt < 2:
                time.sleep(0.5 * (attempt + 1))
                continue
            raise RuntimeError(f"Yandex request failed: {exc}") from exc
    else:
        raise RuntimeError(f"Yandex request failed: {last_error}")

    result = data.get("result") or {}
    alternatives = result.get("alternatives") or data.get("alternatives") or []
    if not alternatives:
        raise RuntimeError("Yandex returned no alternatives")
    message = alternatives[0].get("message") or {}
    text = message.get("text") or message.get("content") or ""
    return text.strip()


def extract_json_text(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
        stripped = re.sub(r"\s*```$", "", stripped)
    if stripped.startswith("{") and stripped.endswith("}"):
        return stripped
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start != -1 and end != -1 and end > start:
        return stripped[start : end + 1]
    raise ValueError("Planner response did not contain JSON")


def allowed_tools(request_data):
    tools = request_data.get("selected_tools") or request_data.get("tool_registry") or []
    return [tool.get("name") for tool in tools if tool.get("name")]


CATEGORY_DESCRIPTIONS = [
    {"name": "tracks", "description": "creation, selection, renaming, deletion, and track state"},
    {"name": "fx", "description": "plugin search, insertion, removal, bypass, presets"},
    {"name": "midi", "description": "MIDI items, notes, patterns, quantize"},
    {"name": "audio_items", "description": "audio item import, slicing, moving"},
    {"name": "routing", "description": "sends, buses, sidechain routing"},
    {"name": "project", "description": "tempo, meter, and project-level setup"},
    {"name": "arrangement", "description": "sections, regions, structure"},
    {"name": "render", "description": "rendering, stems, exports"},
    {"name": "transport", "description": "play, stop, record, cursor"},
    {"name": "automation", "description": "automation and envelopes"},
    {"name": "samples", "description": "sample search and insertion"},
    {"name": "analysis", "description": "project and track analysis"},
    {"name": "recipes", "description": "macro commands and reusable templates"},
    {"name": "system", "description": "project snapshot, validation, dry runs, undo"},
    {"name": "history_versions", "description": "snapshots, versions, checkpoints, rollbacks"},
    {"name": "context_resolution", "description": "pronoun resolution and dialog target tracking"},
    {"name": "articulations", "description": "keyswitches, articulations, orchestral performance control"},
    {"name": "groove_timing", "description": "groove, swing, timing feel, quantize strength"},
    {"name": "harmony", "description": "chord track, harmony, theory, transposition"},
    {"name": "arrangement_intelligence", "description": "arrangement energy, transitions, section logic"},
    {"name": "semantic_audio_editing", "description": "audio editing by meaning, loop, slicing, cleanup"},
    {"name": "metering_quality_control", "description": "loudness, metering, phase, masking, quality checks"},
    {"name": "delivery", "description": "stems, delivery packages, exports"},
    {"name": "sample_pack_creation", "description": "sample pack and loop pack creation"},
    {"name": "recording_session_setup", "description": "recording templates, cue mixes, live sessions"},
    {"name": "performance_editing", "description": "comping, takes, cleanup, vocal/instrument editing"},
    {"name": "sound_design", "description": "sound design, effects, resampling, textures"},
    {"name": "drum_midi_generation", "description": "drum MIDI pattern generation"},
    {"name": "bass_generation", "description": "bassline generation and bass shaping"},
    {"name": "vocal_chop_remix", "description": "vocal chop workflows and remix tools"},
    {"name": "reference_matching_extended", "description": "reference matching and AB comparison"},
    {"name": "chat_ui_agent", "description": "agent UI and user-facing chat helpers"},
    {"name": "recipes_extended", "description": "extended recipes and macros"},
]


def build_router_prompt(request_data):
    user_text = request_data.get("user_text", "").strip()
    history = request_data.get("messages") or []
    project_state = request_data.get("project_state") or {}

    prompt = {
        "role": "system",
        "text": (
            "Ты REAPER router.\n"
            "Ты не строишь план.\n"
            "Ты не исполняешь действия.\n"
            "Ты только определяешь релевантные домены и намёки на tools.\n"
            "Верни только JSON без markdown.\n"
            "Формат ответа:\n"
            "{\n"
            '  "domains": ["tracks"],\n'
            '  "complexity": "single_step",\n'
            '  "needs_project_state": true,\n'
            '  "candidate_tools_hint": ["get_project_state"],\n'
            '  "reason": "..."\n'
            "}\n"
        ),
    }

    router_payload = {
        "user_text": user_text,
        "history": history[-8:],
        "project_state": project_state,
        "categories": CATEGORY_DESCRIPTIONS,
    }
    messages = [prompt, {"role": "user", "text": json.dumps(router_payload, ensure_ascii=False)}]
    return messages


def route(request_data):
    messages = build_router_prompt(request_data)
    raw_text = call_yandex(messages, temperature=0.05, max_tokens=500)
    plan_obj = json.loads(extract_json_text(raw_text))
    if not isinstance(plan_obj, dict):
        raise ValueError("Router output must be a JSON object")
    for field in ("domains", "complexity", "needs_project_state", "candidate_tools_hint", "reason"):
        if field not in plan_obj:
            raise ValueError(f"Missing field: {field}")
    return plan_obj


def build_planner_prompt(request_data):
    user_text = request_data.get("user_text", "").strip()
    history = request_data.get("messages") or []
    project_state = request_data.get("project_state") or {}
    tools = request_data.get("selected_tools") or request_data.get("tool_registry") or []
    recipes = request_data.get("recipes") or []
    plugin_catalog = request_data.get("plugin_catalog") or []
    mode = request_data.get("mode", "plan")
    execution_error = request_data.get("execution_error") or {}

    tool_brief = []
    for tool in tools:
      tool_brief.append(
          {
              "name": tool.get("name"),
              "description": tool.get("description"),
              "schema": tool.get("json_schema"),
              "example": tool.get("example_user_phrase"),
              "possible_errors": tool.get("possible_errors"),
              "result_format": tool.get("result_format"),
          }
      )

    prompt = {
        "role": "system",
        "text": (
            "Ты REAPER planner.\n"
            "Ты не пишешь Lua/ReaScript напрямую.\n"
            "Ты не придумываешь имена команд.\n"
            "Ты выбираешь только tools из списка.\n"
            "Для сложной задачи сначала строишь план.\n"
            "Для неоднозначных команд используешь project_state.\n"
            "Если track/plugin не найден - вызываешь resolve/find tool.\n"
            "Всегда проверяешь результат через verify_project_state.\n"
            "Верни только JSON без markdown и без пояснений вокруг него.\n"
            "Формат ответа:\n"
            "{\n"
            '  "intent": "...",\n'
            '  "requires_confirmation": false,\n'
            '  "recipe": "optional_recipe_name",\n'
            '  "recipe_args": {},\n'
            '  "steps": [{"tool": "...", "args": {}}],\n'
            '  "user_message": "..."\n'
            "}\n"
        ),
    }

    user_payload = {
        "mode": mode,
        "user_text": user_text,
        "history": history[-12:],
        "project_state": project_state,
        "selected_tools": tool_brief,
        "tool_registry": tool_brief,
        "recipes": recipes,
        "plugin_catalog": plugin_catalog,
    }
    if execution_error:
        user_payload["execution_error"] = execution_error

    messages = [prompt, {"role": "user", "text": json.dumps(user_payload, ensure_ascii=False)}]
    return messages


def validate_plan(plan, allowed):
    if not isinstance(plan, dict):
        raise ValueError("Planner output must be a JSON object")
    for field in ("intent", "requires_confirmation", "user_message"):
        if field not in plan:
            raise ValueError(f"Missing field: {field}")
    if not isinstance(plan["intent"], str) or not plan["intent"].strip():
        raise ValueError("intent must be a non-empty string")
    if not isinstance(plan["requires_confirmation"], bool):
        raise ValueError("requires_confirmation must be boolean")
    if not isinstance(plan["user_message"], str):
        raise ValueError("user_message must be a string")
    if "steps" in plan and not isinstance(plan["steps"], list):
        raise ValueError("steps must be an array")
    if "recipe" in plan and not isinstance(plan["recipe"], str):
        raise ValueError("recipe must be a string")
    if "recipe_args" in plan and not isinstance(plan["recipe_args"], dict):
        raise ValueError("recipe_args must be an object")
    if "recipe" not in plan and "steps" not in plan:
        raise ValueError("Either recipe or steps must be present")

    for idx, step in enumerate(plan.get("steps", []), start=1):
        if not isinstance(step, dict):
            raise ValueError(f"Step {idx} must be an object")
        tool = step.get("tool")
        args = step.get("args")
        if tool not in allowed:
            raise ValueError(f"Tool not allowed: {tool}")
        if not isinstance(args, dict):
            raise ValueError(f"Step {idx} args must be an object")
    return plan


def repair_plan(request_data, original_text, validation_error):
    repair_request = dict(request_data)
    repair_request["mode"] = "repair"
    repair_request["execution_error"] = {
        "type": "planner_validation_error",
        "message": validation_error,
        "original_response": original_text,
    }
    messages = build_planner_prompt(repair_request)
    return call_yandex(messages, temperature=0.05, max_tokens=900)


def plan(request_data):
    if request_data.get("mode") == "route":
        return route(request_data)

    messages = build_planner_prompt(request_data)
    raw_text = call_yandex(messages, temperature=0.1, max_tokens=900)
    allowed = allowed_tools(request_data)
    try:
        plan_obj = json.loads(extract_json_text(raw_text))
        return validate_plan(plan_obj, allowed)
    except Exception as exc:  # noqa: BLE001
        repaired_text = repair_plan(request_data, raw_text, str(exc))
        plan_obj = json.loads(extract_json_text(repaired_text))
        return validate_plan(plan_obj, allowed)


def read_request(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    load_env()
    parser = argparse.ArgumentParser(description="REAPER planner backend for Yandex GPT")
    parser.add_argument("request_file", nargs="?", help="JSON request file path")
    parser.add_argument("--prompt", help="Quick test prompt without REAPER")
    args = parser.parse_args()

    if args.prompt:
        request_data = {
            "mode": "plan",
            "user_text": args.prompt,
            "project_state": {},
            "tool_registry": [],
            "recipes": [],
            "plugin_catalog": [],
        }
    elif args.request_file:
        request_data = read_request(Path(args.request_file))
    else:
        raise SystemExit("Provide a request file or --prompt")

    try:
        plan_obj = plan(request_data)
        sys.stdout.write(json.dumps(plan_obj, ensure_ascii=False))
        return 0
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write("@@ERROR_START@@\n")
        sys.stdout.write(str(exc))
        sys.stdout.write("\n@@ERROR_END@@\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
