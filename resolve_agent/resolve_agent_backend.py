#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import io
import json
import math
import os
import re
import sys
import textwrap
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any


CODEX_AUTOCUT_ROOT = Path(
    os.getenv(
        "CODEX_AUTOCUT_ROOT",
        "/Users/bogdan/Documents/Codex/2026-05-23/codex-api-api",
    )
).expanduser().resolve()

if str(CODEX_AUTOCUT_ROOT) not in sys.path:
    sys.path.insert(0, str(CODEX_AUTOCUT_ROOT))

from resolve_codex_bridge import api as resolve_api  # noqa: E402
from resolve_codex_bridge import ui_mac  # noqa: E402


DEBUG_LOG = Path(os.getenv("RESOLVE_AGENT_DEBUG_LOG", "/tmp/resolve_chat_agent.log"))
DEFAULT_CONTEXT_CHAR_LIMIT = int(os.getenv("RESOLVE_AGENT_CONTEXT_CHAR_LIMIT", "14000"))
REFERENCE_INDEX_PATH = Path(
    os.getenv(
        "RESOLVE_AGENT_REFERENCE_INDEX",
        str(Path(__file__).resolve().with_name(".resolve_reference_index.json")),
    )
)
INDEX_VERSION = 1
HELPER_SCHEMAS: dict[str, str] = {
    "open_page": "page: media|cut|edit|fusion|color|fairlight|deliver",
    "save_project": "no args",
    "create_timeline": "name optional",
    "list_timelines": "no args",
    "set_timeline": "name required",
    "set_timecode": "timecode HH:MM:SS:FF required",
    "import_media": "paths list required",
    "append_media": "paths list required",
    "create_timeline_from_media": "paths list required, name optional",
    "insert_textplus": "text required, title optional",
    "change_textplus": "text required",
    "animate_textplus": "text optional, style optional simple|fade",
    "add_marker": "name optional, color optional, frame optional",
    "add_generator": "name required",
    "add_adjustment_clip": "no args",
    "create_subtitles": "language optional auto|ru",
    "set_voice_isolation": "amount optional 0-100, track_index optional",
    "set_current_clip_transform": "zoom/pan/tilt/opacity optional",
    "apply_lut": "path required, node_index optional",
    "setup_mp4_export": "target_dir optional, name optional, start optional bool",
}


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
    load_env_file(here.parent / ".env")
    load_env_file(Path.cwd() / ".env")


def debug_log(label: str, payload: Any) -> None:
    try:
        DEBUG_LOG.parent.mkdir(parents=True, exist_ok=True)
        text = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False, indent=2)
        with DEBUG_LOG.open("a", encoding="utf-8") as file:
            file.write(f"\n[{datetime.now().isoformat(timespec='seconds')}] {label}\n{text}\n")
    except Exception:
        pass


def _query_terms(query: str) -> set[str]:
    text = query.lower()
    terms = set(re.findall(r"[a-zа-яё0-9_+]{3,}", text))
    expansions = {
        "текст": ["text", "title", "titles", "fusion", "styledtext", "timeline", "insert_textplus"],
        "титр": ["text", "title", "titles", "fusion", "styledtext", "timeline", "insert_textplus"],
        "caption": ["subtitle", "subtitles", "timeline", "create subtitles"],
        "субтит": ["subtitle", "subtitles", "timeline", "create subtitles"],
        "таймлайн": ["timeline", "media pool", "createemptytimeline"],
        "timeline": ["timeline", "media pool", "createemptytimeline"],
        "маркер": ["marker", "markers", "timeline"],
        "marker": ["marker", "markers", "timeline"],
        "импорт": ["import", "media storage", "media pool", "importmedia"],
        "import": ["import", "media storage", "media pool", "importmedia"],
        "экспорт": ["render", "export", "render settings", "quick export"],
        "export": ["render", "export", "render settings", "quick export"],
        "render": ["render", "export", "render settings", "quick export"],
        "цвет": ["color", "gallery", "node graph", "lut"],
        "color": ["color", "gallery", "node graph", "lut"],
        "звук": ["audio", "fairlight", "voice isolation"],
        "audio": ["audio", "fairlight", "voice isolation"],
        "fairlight": ["audio", "fairlight", "voice isolation"],
        "проект": ["project", "projectmanager", "settings"],
        "project": ["project", "projectmanager", "settings"],
    }
    for needle, extra_terms in expansions.items():
        if needle in text:
            terms.update(extra_terms)
    return terms


def _tokenize(text: str) -> list[str]:
    tokens = re.findall(r"[a-zа-яё0-9_+]{3,}", text.lower())
    normalized: list[str] = []
    for token in tokens:
        normalized.append(token)
        if token.endswith("s") and len(token) > 4:
            normalized.append(token[:-1])
        if token.endswith("ing") and len(token) > 6:
            normalized.append(token[:-3])
    return normalized


def _split_reference_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    current: list[str] = []
    for line in text.splitlines():
        starts_new_object = bool(re.match(r"^[A-Za-z][A-Za-z0-9 ]{1,50}$", line.strip()))
        starts_heading = bool(re.match(r"^[A-Za-z].*\n?-{3,}$", line.strip()))
        if current and (starts_new_object or starts_heading):
            blocks.append("\n".join(current).strip())
            current = []
        current.append(line)
        if not line.strip() and current:
            block = "\n".join(current).strip()
            if block:
                blocks.append(block)
            current = []
    if current:
        block = "\n".join(current).strip()
        if block:
            blocks.append(block)
    return blocks


def _chunk_reference_text(source_name: str, text: str) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    for block_index, block in enumerate(_split_reference_blocks(text)):
        block = block.strip()
        if not block:
            continue
        lines = block.splitlines()
        title = lines[0].strip()[:120] if lines else source_name
        if len(block) <= 1800:
            chunks.append(
                {
                    "id": f"{source_name}:{block_index}:0",
                    "source": source_name,
                    "title": title,
                    "text": block,
                    "tokens": _tokenize(block),
                }
            )
            continue

        step = 18
        window = 30
        for start in range(0, len(lines), step):
            snippet = "\n".join(lines[start : start + window]).strip()
            if not snippet:
                continue
            chunks.append(
                {
                    "id": f"{source_name}:{block_index}:{start}",
                    "source": source_name,
                    "title": title,
                    "text": snippet,
                    "tokens": _tokenize(" ".join([title, snippet])),
                }
            )
    return chunks


def _file_signature(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False}
    stat = path.stat()
    return {
        "path": str(path),
        "exists": True,
        "mtime": int(stat.st_mtime),
        "size": stat.st_size,
    }


def _load_reference_index(index_path: Path, signatures: list[dict[str, Any]]) -> dict[str, Any] | None:
    try:
        index = json.loads(index_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if index.get("version") != INDEX_VERSION:
        return None
    if index.get("signatures") != signatures:
        return None
    return index


def _build_reference_index(sources: list[tuple[str, Path, str]]) -> dict[str, Any]:
    chunks: list[dict[str, Any]] = []
    for source_name, _path, text in sources:
        chunks.extend(_chunk_reference_text(source_name, text))

    df: dict[str, int] = {}
    for chunk in chunks:
        for token in set(chunk["tokens"]):
            df[token] = df.get(token, 0) + 1

    index = {
        "version": INDEX_VERSION,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "signatures": [_file_signature(path) for _name, path, _text in sources],
        "document_count": len(chunks),
        "df": df,
        "chunks": chunks,
    }
    try:
        REFERENCE_INDEX_PATH.write_text(json.dumps(index, ensure_ascii=False), encoding="utf-8")
    except Exception as exc:
        debug_log("REFERENCE_INDEX_WRITE_ERROR", repr(exc))
    return index


def _get_reference_index(sources: list[tuple[str, Path, str]]) -> dict[str, Any]:
    signatures = [_file_signature(path) for _name, path, _text in sources]
    index = _load_reference_index(REFERENCE_INDEX_PATH, signatures)
    if index:
        return index
    index = _build_reference_index(sources)
    debug_log(
        "REFERENCE_INDEX_BUILT",
        {"chunks": index.get("document_count"), "path": str(REFERENCE_INDEX_PATH)},
    )
    return index


def _search_reference_index(index: dict[str, Any], query: str, max_chars: int) -> str:
    if max_chars <= 0:
        return ""
    query_tokens = _tokenize(" ".join([query, " ".join(_query_terms(query))]))
    if not query_tokens:
        return ""

    query_counts: dict[str, int] = {}
    for token in query_tokens:
        query_counts[token] = query_counts.get(token, 0) + 1

    chunks = index.get("chunks") or []
    df = index.get("df") or {}
    doc_count = max(1, int(index.get("document_count") or len(chunks) or 1))
    scored: list[tuple[float, int, dict[str, Any]]] = []

    for chunk_index, chunk in enumerate(chunks):
        chunk_tokens = chunk.get("tokens") or []
        if not chunk_tokens:
            continue
        token_counts: dict[str, int] = {}
        for token in chunk_tokens:
            token_counts[token] = token_counts.get(token, 0) + 1

        score = 0.0
        for token, query_count in query_counts.items():
            count = token_counts.get(token)
            if not count:
                continue
            idf = math.log((doc_count + 1) / (int(df.get(token, 0)) + 1)) + 1.0
            score += query_count * count * idf

        lowered_text = (chunk.get("title", "") + "\n" + chunk.get("text", "")).lower()
        if "insert_textplus" in lowered_text and any(t in query_tokens for t in ("text", "текст", "титр")):
            score += 20
        if "execute_resolve_python" in lowered_text:
            score += 10
        if score > 0:
            scored.append((score, chunk_index, chunk))

    selected = sorted(scored, key=lambda item: (-item[0], item[1]))
    parts: list[str] = []
    used = 0
    seen: set[str] = set()
    for score, _chunk_index, chunk in selected:
        text = chunk.get("text", "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        header = f"[{chunk.get('source')}: {chunk.get('title')}; score={score:.2f}]"
        block = f"{header}\n{text}"
        next_len = used + len(block) + 2
        if next_len > max_chars:
            remaining = max_chars - used
            if remaining > 700:
                parts.append(block[:remaining].rstrip())
            break
        parts.append(block)
        used = next_len
    return "\n\n".join(parts)


def _matching_snippets(block: str, terms: set[str], radius: int = 5) -> list[str]:
    lines = block.splitlines()
    matched_indexes: set[int] = set()
    for index, line in enumerate(lines):
        lowered = line.lower()
        if any(term in lowered for term in terms):
            for snippet_index in range(max(0, index - radius), min(len(lines), index + radius + 1)):
                matched_indexes.add(snippet_index)
    if not matched_indexes:
        return []

    snippets: list[str] = []
    current: list[str] = []
    previous = -2
    for index in sorted(matched_indexes):
        if current and index > previous + 1:
            snippets.append("\n".join(current).strip())
            current = []
        current.append(lines[index])
        previous = index
    if current:
        snippets.append("\n".join(current).strip())
    return [snippet for snippet in snippets if snippet]


def _select_relevant_text(source: str, query: str, max_chars: int) -> str:
    if not source.strip() or max_chars <= 0:
        return ""

    terms = _query_terms(query)
    scored: list[tuple[int, int, str]] = []
    for index, block in enumerate(_split_reference_blocks(source)):
        lowered = block.lower()
        score = 0
        for term in terms:
            if term in lowered:
                score += 1 + lowered.count(term)
        if "insert_textplus" in lowered or "execute_resolve_python" in lowered:
            score += 8
        if score > 0:
            if len(block) > 2400:
                snippets = _matching_snippets(block, terms)
                for snippet in snippets:
                    scored.append((score, index, snippet))
            else:
                scored.append((score, index, block))

    selected = sorted(scored, key=lambda item: (-item[0], item[1]))
    parts: list[str] = []
    used = 0
    for _score, _index, block in selected:
        chunk = block.strip()
        if not chunk:
            continue
        next_len = used + len(chunk) + 2
        if next_len > max_chars:
            remaining = max_chars - used
            if remaining > 600:
                parts.append(chunk[:remaining].rstrip())
            break
        parts.append(chunk)
        used = next_len
    return "\n\n".join(parts)


def build_system_prompt(context: str, user_query: str = "") -> str:
    manual_path = Path(__file__).resolve().with_name("resolve_manual.md")
    manual_text = manual_path.read_text(encoding="utf-8") if manual_path.exists() else ""
    api_reference_path = Path(
        os.getenv(
            "RESOLVE_API_REFERENCE",
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/README.txt",
        )
    )
    api_reference = (
        api_reference_path.read_text(encoding="utf-8", errors="replace")
        if api_reference_path.exists()
        else ""
    )
    reference_query = user_query or context
    index = _get_reference_index(
        [
            ("manual", manual_path, manual_text),
            ("official_api", api_reference_path, api_reference),
        ]
    )
    reference_excerpt = _search_reference_index(
        index,
        reference_query,
        max_chars=max(3000, DEFAULT_CONTEXT_CHAR_LIMIT - 5000),
    )
    helper_schema_text = "\n".join(f"- {name}: {schema}" for name, schema in HELPER_SCHEMAS.items())
    return (
        "You are a DaVinci Resolve control agent inside a custom chat window.\n"
        "Your job is to analyze natural-language user instructions and directly control Resolve.\n"
        "Do not explain how to use Resolve.\n"
        "Do not write tutorials.\n"
        "Do not give the user general advice when they asked for a direct action.\n"
        "Infer the user's actual editing intent, inspect the current context, and produce an ordered action plan.\n"
        "For multi-step requests, return multiple actions in execution order.\n"
        "Use call_helper first. Use generated Python only when no helper fits the requested operation.\n"
        "If no action is needed, reply briefly.\n"
        "Return STRICT JSON only with this shape:\n"
        "{\n"
        '  "reply": "short user-facing confirmation or short answer",\n'
        '  "actions": [\n'
        '    {"tool": "tool_name", "args": {...}}\n'
        "  ]\n"
        "}\n"
        "Primary action for common requests:\n"
        "- call_helper: args {\"name\": \"helper_name\", \"args\": {...}}\n"
        "Available helpers:\n"
        f"{helper_schema_text}\n"
        "Fallback action for unusual complex requests only:\n"
        "- execute_resolve_python: args {\"code\": \"Python code to execute against the live Resolve API\"}\n"
        "Prefer call_helper whenever a helper fits. Do not invent Resolve API methods when a helper exists.\n"
        "The Python code receives these variables: resolve, project_manager, project, media_storage, media_pool, timeline, ui, Path, json, helpers, insert_textplus, animate_textplus.\n"
        "The code must print a short verified result or assign a string to result after confirming the requested change happened.\n"
        "Check return values from Resolve calls and raise RuntimeError on failure. Never leave a script silent after a user-requested action.\n"
        "For visible text/title requests on the timeline, use `result = insert_textplus(\"user text\")`.\n"
        "For simple animation of visible text/title items, use `result = animate_textplus()` or `result = animate_textplus(\"user text\")`.\n"
        "If the user asks to create text and animate it in the same request, use `result = animate_textplus(\"user text\")` in one action.\n"
        "`Timeline.InsertTitleIntoTimeline(name)` and `Timeline.InsertFusionTitleIntoTimeline(name)` take a Resolve preset name, not the displayed text.\n"
        "There is no Timeline.GetSelectedItem() method in the Resolve API. Use animate_textplus or timeline.GetCurrentVideoItem() plus track scanning.\n"
        "Do not call those title insertion APIs directly for user text unless you also set StyledText and verify it.\n"
        "Use the retrieved manual/API context below as the operating guide. If an API detail is absent, inspect live objects and use conservative Resolve API calls.\n"
        "Retrieved Resolve reference context:\n"
        f"{reference_excerpt or manual_text[:4000]}\n"
        "Current Resolve context:\n"
        f"{context or 'No context available.'}"
    )


def call_yandex(messages, temperature=0.2, max_tokens=700):
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
    headers["Authorization"] = f"Api-Key {api_key}" if api_key else f"Bearer {iam_token}"

    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=120) as response:
        data = json.loads(response.read().decode("utf-8"))

    result = data.get("result") or {}
    alternatives = result.get("alternatives") or data.get("alternatives") or []
    if not alternatives:
        raise RuntimeError("Yandex returned no alternatives")

    message = alternatives[0].get("message") or {}
    text = message.get("text") or message.get("content") or ""
    return text.strip()


def extract_json(text: str) -> dict[str, Any]:
    raw = text.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw.replace("json\n", "", 1)

    start = raw.find("{")
    end = raw.rfind("}")
    if start != -1 and end != -1 and end > start:
        raw = raw[start : end + 1]

    return json.loads(raw)


def read_request(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def current_project_context() -> str:
    try:
        return json.dumps(resolve_api.status(), ensure_ascii=False, indent=2, sort_keys=True)
    except Exception as exc:  # noqa: BLE001
        return f"Resolve status unavailable: {exc!r}"


def resolve_state_snapshot() -> dict[str, Any]:
    try:
        status = resolve_api.status()
    except Exception as exc:  # noqa: BLE001
        return {"available": False, "error": repr(exc)}

    snapshot: dict[str, Any] = {"available": True, "status": status}
    try:
        resolve, _project_manager, project = get_project()
        timeline = project.GetCurrentTimeline()
        snapshot["current_page"] = _safe_text(resolve.GetCurrentPage())
        snapshot["project_name"] = _safe_text(project.GetName())
        if timeline:
            track_counts = {}
            item_counts = {}
            for track_type in ("video", "audio", "subtitle"):
                count = int(timeline.GetTrackCount(track_type) or 0)
                track_counts[track_type] = count
                item_counts[track_type] = sum(
                    len(timeline.GetItemListInTrack(track_type, index) or [])
                    for index in range(1, count + 1)
                )
            snapshot["timeline"] = {
                "name": _safe_text(timeline.GetName()),
                "timecode": _safe_text(_call_if_callable(timeline, "GetCurrentTimecode")),
                "track_counts": track_counts,
                "item_counts": item_counts,
                "markers": len(timeline.GetMarkers() or {}),
            }
    except Exception as exc:  # noqa: BLE001
        snapshot["detail_error"] = repr(exc)
    return snapshot


def get_project():
    resolve = resolve_api.get_resolve()
    project_manager = resolve.GetProjectManager()
    project = project_manager.GetCurrentProject() if project_manager else None
    if not project:
        raise RuntimeError("No open Resolve project.")
    return resolve, project_manager, project


def _safe_text(value: Any) -> str:
    return "" if value is None else str(value)


def _find_timeline_by_name(project, name: str):
    count = int(project.GetTimelineCount() or 0)
    for index in range(1, count + 1):
        timeline = project.GetTimelineByIndex(index)
        if timeline and _safe_text(timeline.GetName()) == name:
            return timeline
    return None


def _resolve_media_paths(paths: list[str]) -> list[str]:
    return [str(Path(p).expanduser().resolve()) for p in paths]


def _timeline_item_count(timeline) -> int:
    if not timeline:
        return 0
    total = 0
    for track_type in ("video", "audio", "subtitle"):
        try:
            track_count = int(timeline.GetTrackCount(track_type) or 0)
        except Exception:
            track_count = 0
        for index in range(1, track_count + 1):
            try:
                total += len(timeline.GetItemListInTrack(track_type, index) or [])
            except Exception:
                pass
    return total


def _call_if_callable(obj: Any, method_name: str, *args: Any) -> Any:
    method = getattr(obj, method_name, None)
    if not callable(method):
        return None
    try:
        return method(*args)
    except Exception:
        return None


def _timecode_to_frame(timecode: str, fps: float) -> int:
    match = re.match(r"^(\d+):(\d+):(\d+)[:;](\d+)$", _safe_text(timecode).strip())
    if not match:
        return 0
    hours, minutes, seconds, frames = [int(part) for part in match.groups()]
    return int(round(((hours * 60 + minutes) * 60 + seconds) * fps + frames))


def _timeline_current_frame(project, timeline) -> int:
    if not timeline:
        return 0
    fps = 24.0
    try:
        fps = float(project.GetSetting("timelineFrameRate") or 24)
    except Exception:
        pass
    current_tc = _call_if_callable(timeline, "GetCurrentTimecode") or "00:00:00:00"
    start_tc = _call_if_callable(timeline, "GetStartTimecode") or "00:00:00:00"
    return max(0, _timecode_to_frame(current_tc, fps) - _timecode_to_frame(start_tc, fps))


def _find_text_tool(comp):
    if not comp:
        return None
    for name in ("Text1", "Template", "StyledText", "TextPlus1"):
        tool_obj = _call_if_callable(comp, "FindTool", name)
        if tool_obj:
            return tool_obj
    tools = _call_if_callable(comp, "GetToolList", False) or {}
    if isinstance(tools, dict):
        for tool_obj in tools.values():
            try:
                attrs = tool_obj.GetAttrs() or {}
            except Exception:
                attrs = {}
            name = _safe_text(attrs.get("TOOLS_RegID") or attrs.get("TOOLS_Name"))
            if "text" in name.lower():
                return tool_obj
            try:
                tool_obj.SetInput("StyledText", tool_obj.GetInput("StyledText"))
                return tool_obj
            except Exception:
                pass
    return None


def _item_has_text_tool(item) -> bool:
    if not item:
        return False
    try:
        count = int(item.GetFusionCompCount() or 0)
    except Exception:
        count = 0
    for index in range(1, count + 1):
        comp = _call_if_callable(item, "GetFusionCompByIndex", index)
        if _find_text_tool(comp):
            return True
    return False


def _find_textplus_item(project, timeline):
    if not timeline:
        return None

    current_item = _call_if_callable(timeline, "GetCurrentVideoItem")
    if _item_has_text_tool(current_item):
        return current_item

    current_frame = _timeline_current_frame(project, timeline)
    candidates: list[tuple[int, Any]] = []
    try:
        video_tracks = int(timeline.GetTrackCount("video") or 0)
    except Exception:
        video_tracks = 0

    for track_index in range(video_tracks, 0, -1):
        items = _call_if_callable(timeline, "GetItemListInTrack", "video", track_index) or []
        for item in items:
            if not _item_has_text_tool(item):
                continue
            try:
                start = int(item.GetStart(False) or 0)
                end = int(item.GetEnd(False) or start)
            except Exception:
                start = 0
                end = 0
            priority = 1000000 + start if start <= current_frame <= end else start
            candidates.append((priority, item))

    if not candidates:
        return None
    return sorted(candidates, key=lambda pair: pair[0])[-1][1]


def _key_scalar(comp, tool, input_name: str, keys: list[tuple[int, float]]) -> None:
    setattr(tool, input_name, comp.BezierSpline())
    spline = getattr(tool, input_name)
    for frame, value in keys:
        spline[max(0, int(frame))] = float(value)


def _key_point(comp, tool, input_name: str, keys: list[tuple[int, float, float]]) -> None:
    setattr(tool, input_name, comp.BezierSpline())
    spline = getattr(tool, input_name)
    for frame, x, y in keys:
        spline[max(0, int(frame))] = {1: float(x), 2: float(y)}


def _set_textplus_text(title_item, text_value: str) -> bool:
    if not text_value:
        return True

    try:
        comp = title_item.GetFusionCompByIndex(1)
    except Exception:
        comp = None
    if not comp:
        return False

    tool_obj = _find_text_tool(comp)
    if tool_obj:
        try:
            tool_obj.SetInput("StyledText", text_value)
            return True
        except Exception:
            pass
    return False


def insert_textplus_helper(text: str, title: str = "Text+") -> str:
    resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")

    before_count = _timeline_item_count(timeline)
    title_item = None
    for method_name in ("InsertFusionTitleIntoTimeline", "InsertTitleIntoTimeline"):
        method = getattr(timeline, method_name, None)
        if not method:
            continue
        try:
            title_item = method(title)
        except Exception:
            title_item = None
        if title_item:
            break

    after_count = _timeline_item_count(timeline)
    if not title_item and after_count <= before_count:
        raise RuntimeError(f"Resolve не добавил титр {title}.")

    text_applied = True
    if title_item:
        text_applied = _set_textplus_text(title_item, text)
    resolve.OpenPage("edit")

    if text and not text_applied:
        return f"Добавил титр {title}, но Resolve не дал изменить текст через Fusion API."
    return f"Добавил титр {title}" + (f' с текстом "{text}".' if text else ".")


def animate_textplus_helper(text: str = "", style: str = "simple") -> str:
    resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")

    item = _find_textplus_item(project, timeline)
    if not item:
        if text:
            insert_textplus_helper(text)
            timeline = project.GetCurrentTimeline()
            item = _find_textplus_item(project, timeline)
        if not item:
            raise RuntimeError("Не нашёл Text+ на текущем таймлайне.")

    try:
        comp = item.GetFusionCompByIndex(1)
    except Exception:
        comp = None
    if not comp:
        raise RuntimeError("У выбранного Text+ нет Fusion comp.")

    text_tool = _find_text_tool(comp)
    if not text_tool:
        raise RuntimeError("Не нашёл Text+ tool внутри Fusion comp.")
    if text:
        text_tool.SetInput("StyledText", text)

    try:
        text_tool.SetInput("MotionBlur", 1)
        text_tool.SetInput("Quality", 8)
        text_tool.SetInput("ShutterAngle", 180)
    except Exception:
        pass

    if style == "fade":
        _key_scalar(comp, text_tool, "Opacity1", [(0, 0.0), (8, 1.0), (42, 1.0), (54, 0.0)])
    else:
        _key_scalar(comp, text_tool, "Size", [(0, 0.02), (8, 0.09), (14, 0.075), (54, 0.075)])
        _key_point(comp, text_tool, "Center", [(0, 0.5, 0.44), (10, 0.5, 0.5), (54, 0.5, 0.5)])
        try:
            _key_scalar(comp, text_tool, "Opacity1", [(0, 0.0), (5, 1.0), (54, 1.0)])
        except Exception:
            pass

    resolve.OpenPage("edit")
    name = _safe_text(_call_if_callable(item, "GetName")) or "Text+"
    return f"Добавил простую анимацию для {name}."


def change_textplus_helper(text: str) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")

    item = _find_textplus_item(project, timeline)
    if not item:
        raise RuntimeError("Не нашёл Text+ на текущем таймлайне.")

    try:
        comp = item.GetFusionCompByIndex(1)
    except Exception:
        comp = None
    text_tool = _find_text_tool(comp)
    if not text_tool:
        raise RuntimeError("Не нашёл Text+ tool внутри Fusion comp.")

    text_tool.SetInput("StyledText", text)
    return f'Изменил текст на "{text}".'


def _create_timeline_helper(name: str = "") -> str:
    resolve, _project_manager, project = get_project()
    media_pool = project.GetMediaPool()
    name = _safe_text(name).strip() or f"New Timeline {datetime.now().strftime('%H%M%S')}"
    timeline = media_pool.CreateEmptyTimeline(name) if media_pool else None
    if not timeline:
        raise RuntimeError("Resolve не создал таймлайн.")
    project.SetCurrentTimeline(timeline)
    resolve.OpenPage("edit")
    return f"Создал таймлайн: {name}."


def _list_timelines_helper() -> str:
    _resolve, _project_manager, project = get_project()
    count = int(project.GetTimelineCount() or 0)
    names = []
    current = project.GetCurrentTimeline()
    current_name = _safe_text(current.GetName()) if current else ""
    for index in range(1, count + 1):
        timeline = project.GetTimelineByIndex(index)
        if not timeline:
            continue
        name = _safe_text(timeline.GetName())
        names.append(f"{name}" + (" (текущий)" if name == current_name else ""))
    return "Таймлайны: " + (", ".join(names) if names else "нет.")


def _set_timeline_helper(name: str) -> str:
    resolve, _project_manager, project = get_project()
    timeline = _find_timeline_by_name(project, _safe_text(name).strip())
    if not timeline:
        raise RuntimeError(f"Таймлайн не найден: {name}")
    project.SetCurrentTimeline(timeline)
    resolve.OpenPage("edit")
    return f"Выбрал таймлайн: {name}."


def _import_media_helper(paths: list[str]) -> str:
    _resolve, _project_manager, project = get_project()
    media_pool = project.GetMediaPool()
    resolved_paths = _resolve_media_paths(paths)
    imported = media_pool.ImportMedia(resolved_paths) if media_pool else None
    if not imported:
        raise RuntimeError("Resolve не импортировал медиа.")
    return f"Импортировал {len(imported)} файлов."


def _append_media_helper(paths: list[str]) -> str:
    _resolve, _project_manager, project = get_project()
    media_pool = project.GetMediaPool()
    clips = media_pool.ImportMedia(_resolve_media_paths(paths)) if media_pool else None
    if not clips:
        raise RuntimeError("Resolve не импортировал исходные клипы.")
    appended = media_pool.AppendToTimeline(clips)
    if not appended:
        raise RuntimeError("Resolve не добавил клипы на таймлайн.")
    return f"Добавил {len(appended)} клипов на текущий таймлайн."


def _create_timeline_from_media_helper(paths: list[str], name: str = "") -> str:
    resolve, _project_manager, project = get_project()
    media_pool = project.GetMediaPool()
    clips = media_pool.ImportMedia(_resolve_media_paths(paths)) if media_pool else None
    if not clips:
        raise RuntimeError("Resolve не импортировал исходные клипы.")
    timeline_name = _safe_text(name).strip() or f"New Timeline {datetime.now().strftime('%H%M%S')}"
    timeline = media_pool.CreateTimelineFromClips(timeline_name, clips)
    if not timeline:
        raise RuntimeError("Resolve не создал таймлайн из клипов.")
    project.SetCurrentTimeline(timeline)
    resolve.OpenPage("edit")
    return f"Создал таймлайн из клипов: {timeline_name}."


def _add_marker_helper(name: str = "Marker", color: str = "Blue", frame: Any = None) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    if frame is None:
        frame = _timeline_current_frame(project, timeline)
    if not timeline.AddMarker(int(frame), _safe_text(color).strip() or "Blue", _safe_text(name).strip() or "Marker", "", 1, ""):
        raise RuntimeError("Resolve не поставил маркер.")
    return f"Поставил маркер: {_safe_text(name).strip() or 'Marker'}."


def _set_timecode_helper(timecode: str) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    if not timeline.SetCurrentTimecode(_safe_text(timecode).strip()):
        raise RuntimeError(f"Resolve не поставил курсор на {timecode}.")
    return f"Поставил курсор на {timecode}."


def _add_generator_helper(name: str) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    generator_name = _safe_text(name).strip()
    item = timeline.InsertGeneratorIntoTimeline(generator_name)
    if not item:
        raise RuntimeError(f"Resolve не добавил генератор: {generator_name}.")
    return f"Добавил генератор: {generator_name}."


def _add_adjustment_clip_helper() -> str:
    return _add_generator_helper("Adjustment Clip")


def _create_subtitles_helper(language: str = "auto") -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    settings: dict[Any, Any] = {}
    language = _safe_text(language).lower().strip()
    if language in {"ru", "rus", "russian", "русский"}:
        resolve = resolve_api.get_resolve()
        settings[resolve.SUBTITLE_LANGUAGE] = resolve.AUTO_CAPTION_RUSSIAN
    ok = timeline.CreateSubtitlesFromAudio(settings)
    if not ok:
        raise RuntimeError("Resolve не создал субтитры из аудио.")
    return "Создал субтитры из аудио."


def _set_voice_isolation_helper(amount: int = 75, track_index: int = 1) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    state = {"isEnabled": True, "amount": max(0, min(100, int(amount)))}
    ok = timeline.SetVoiceIsolationState(int(track_index), state)
    if not ok:
        item = _call_if_callable(timeline, "GetCurrentVideoItem")
        ok = bool(item and _call_if_callable(item, "SetVoiceIsolationState", state))
    if not ok:
        raise RuntimeError("Resolve не включил Voice Isolation.")
    return f"Включил Voice Isolation на {state['amount']}%."


def _set_current_clip_transform_helper(
    zoom: Any = None,
    pan: Any = None,
    tilt: Any = None,
    opacity: Any = None,
) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        raise RuntimeError("Нет активного таймлайна.")
    item = _call_if_callable(timeline, "GetCurrentVideoItem")
    if not item:
        raise RuntimeError("Нет текущего клипа для изменения.")
    updates = {}
    if zoom is not None:
        updates["ZoomX"] = float(zoom)
        updates["ZoomY"] = float(zoom)
    if pan is not None:
        updates["Pan"] = float(pan)
    if tilt is not None:
        updates["Tilt"] = float(tilt)
    if opacity is not None:
        updates["Opacity"] = float(opacity)
    if not updates:
        raise RuntimeError("Нет параметров трансформации.")
    failed = [key for key, value in updates.items() if not item.SetProperty(key, value)]
    if failed:
        raise RuntimeError("Resolve не применил параметры: " + ", ".join(failed))
    return "Изменил параметры текущего клипа."


def _apply_lut_helper(path: str, node_index: int = 1) -> str:
    _resolve, _project_manager, project = get_project()
    timeline = project.GetCurrentTimeline()
    item = _call_if_callable(timeline, "GetCurrentVideoItem") if timeline else None
    if not item:
        raise RuntimeError("Нет текущего клипа для LUT.")
    graph = _call_if_callable(item, "GetNodeGraph")
    if not graph:
        raise RuntimeError("Не получил node graph текущего клипа.")
    lut_path = _safe_text(path).strip()
    if not graph.SetLUT(int(node_index), lut_path):
        raise RuntimeError(f"Resolve не применил LUT: {lut_path}.")
    return f"Применил LUT: {lut_path}."


def _setup_mp4_export_helper(target_dir: str = "", name: str = "", start: bool = False) -> str:
    _resolve, _project_manager, project = get_project()
    target = Path(_safe_text(target_dir).strip() or str(Path.home() / "Movies")).expanduser()
    target.mkdir(parents=True, exist_ok=True)
    custom_name = _safe_text(name).strip() or f"resolve_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if not project.SetCurrentRenderFormatAndCodec("mp4", "H.264"):
        raise RuntimeError("Resolve не выбрал MP4/H.264.")
    settings = {
        "TargetDir": str(target),
        "CustomName": custom_name,
        "ExportVideo": True,
        "ExportAudio": True,
        "SelectAllFrames": True,
    }
    if not project.SetRenderSettings(settings):
        raise RuntimeError("Resolve не применил render settings.")
    job_id = project.AddRenderJob()
    if not job_id:
        raise RuntimeError("Resolve не добавил render job.")
    if start and not project.StartRendering(job_id):
        raise RuntimeError("Resolve добавил render job, но не запустил рендер.")
    return ("Запустил экспорт MP4" if start else "Подготовил экспорт MP4") + f": {custom_name}."


def call_helper_action(args: dict[str, Any]) -> str:
    name = _safe_text(args.get("name")).strip()
    helper_args = args.get("args") or {}
    if not isinstance(helper_args, dict):
        raise RuntimeError("call_helper args must be an object.")

    helpers = {
        "open_page": lambda **kw: (resolve_api.open_page(_safe_text(kw.get("page")).strip()), f"Открыл страницу {_safe_text(kw.get('page')).strip()}.")[1],
        "save_project": lambda **_kw: (resolve_api.save_project(), "Сохранил проект.")[1],
        "create_timeline": lambda **kw: _create_timeline_helper(_safe_text(kw.get("name"))),
        "list_timelines": lambda **_kw: _list_timelines_helper(),
        "set_timeline": lambda **kw: _set_timeline_helper(_safe_text(kw.get("name"))),
        "set_timecode": lambda **kw: _set_timecode_helper(_safe_text(kw.get("timecode"))),
        "import_media": lambda **kw: _import_media_helper(list(kw.get("paths") or [])),
        "append_media": lambda **kw: _append_media_helper(list(kw.get("paths") or [])),
        "create_timeline_from_media": lambda **kw: _create_timeline_from_media_helper(list(kw.get("paths") or []), _safe_text(kw.get("name"))),
        "insert_textplus": lambda **kw: insert_textplus_helper(_safe_text(kw.get("text")), _safe_text(kw.get("title")) or "Text+"),
        "change_textplus": lambda **kw: change_textplus_helper(_safe_text(kw.get("text"))),
        "animate_textplus": lambda **kw: animate_textplus_helper(_safe_text(kw.get("text")), _safe_text(kw.get("style")) or "simple"),
        "add_marker": lambda **kw: _add_marker_helper(_safe_text(kw.get("name")) or "Marker", _safe_text(kw.get("color")) or "Blue", kw.get("frame")),
        "add_generator": lambda **kw: _add_generator_helper(_safe_text(kw.get("name"))),
        "add_adjustment_clip": lambda **_kw: _add_adjustment_clip_helper(),
        "create_subtitles": lambda **kw: _create_subtitles_helper(_safe_text(kw.get("language")) or "auto"),
        "set_voice_isolation": lambda **kw: _set_voice_isolation_helper(int(kw.get("amount") or 75), int(kw.get("track_index") or 1)),
        "set_current_clip_transform": lambda **kw: _set_current_clip_transform_helper(kw.get("zoom"), kw.get("pan"), kw.get("tilt"), kw.get("opacity")),
        "apply_lut": lambda **kw: _apply_lut_helper(_safe_text(kw.get("path")), int(kw.get("node_index") or 1)),
        "setup_mp4_export": lambda **kw: _setup_mp4_export_helper(_safe_text(kw.get("target_dir")), _safe_text(kw.get("name")), bool(kw.get("start"))),
    }
    helper = helpers.get(name)
    if not helper:
        available = ", ".join(sorted(HELPER_SCHEMAS))
        raise RuntimeError(f"Unknown helper: {name}. Available helpers: {available}")
    return helper(**helper_args)


def execute_resolve_python(args: dict[str, Any]) -> str:
    code = textwrap.dedent(_safe_text(args.get("code"))).strip()
    if not code:
        raise RuntimeError("Python code is required.")
    if "GetSelectedItem" in code:
        raise RuntimeError(
            "Resolve API не поддерживает timeline.GetSelectedItem(). "
            "Для анимации текста используй animate_textplus()."
        )

    resolve = resolve_api.get_resolve()
    project_manager = resolve.GetProjectManager()
    project = project_manager.GetCurrentProject() if project_manager else None
    media_pool = project.GetMediaPool() if project else None
    timeline = project.GetCurrentTimeline() if project else None

    safe_builtins = {
        "abs": abs,
        "all": all,
        "any": any,
        "bool": bool,
        "dict": dict,
        "enumerate": enumerate,
        "Exception": Exception,
        "float": float,
        "getattr": getattr,
        "hasattr": hasattr,
        "int": int,
        "iter": iter,
        "isinstance": isinstance,
        "len": len,
        "list": list,
        "max": max,
        "min": min,
        "next": next,
        "print": print,
        "range": range,
        "reversed": reversed,
        "round": round,
        "RuntimeError": RuntimeError,
        "set": set,
        "setattr": setattr,
        "sorted": sorted,
        "str": str,
        "sum": sum,
        "tuple": tuple,
        "type": type,
        "ValueError": ValueError,
        "zip": zip,
    }
    exec_namespace: dict[str, Any] = {
        "__builtins__": safe_builtins,
        "resolve": resolve,
        "project_manager": project_manager,
        "project": project,
        "media_storage": resolve.GetMediaStorage(),
        "media_pool": media_pool,
        "timeline": timeline,
        "ui": ui_mac,
        "Path": Path,
        "json": json,
        "helpers": {"call": lambda name, **kwargs: call_helper_action({"name": name, "args": kwargs})},
        "insert_textplus": insert_textplus_helper,
        "animate_textplus": animate_textplus_helper,
        "result": "",
    }

    stdout = io.StringIO()
    debug_log("EXECUTE_RESOLVE_PYTHON_CODE", code)
    with contextlib.redirect_stdout(stdout):
        exec(code, exec_namespace, exec_namespace)

    result = _safe_text(exec_namespace.get("result")).strip()
    printed = stdout.getvalue().strip()
    if not result and not printed:
        raise RuntimeError(
            "Скрипт выполнился без подтверждения результата. Команда не засчитана как выполненная."
        )
    return result or printed


def execute_action(action: dict[str, Any]) -> str:
    tool = (action.get("tool") or "").strip()
    args = action.get("args") or {}

    resolve = None
    project_manager = None
    project = None

    if tool in {
        "open_page",
        "save_project",
        "create_empty_timeline",
        "create_timeline_from_clips",
        "import_media",
        "append_to_current_timeline",
        "set_current_timeline",
        "set_current_timecode",
        "insert_textplus_title",
        "add_marker",
        "click_menu",
    }:
        resolve, project_manager, project = get_project()

    if tool == "call_helper":
        return call_helper_action(args)

    if tool == "execute_resolve_python":
        return execute_resolve_python(args)

    if tool == "open_page":
        page = _safe_text(args.get("page")).lower().strip()
        resolve_api.open_page(page)
        return f"Открыл страницу {page}."

    if tool == "save_project":
        resolve_api.save_project()
        return "Сохранил проект."

    media_pool = project.GetMediaPool() if project else None

    if tool == "import_media":
        paths = _resolve_media_paths(list(args.get("paths") or []))
        imported = media_pool.ImportMedia(paths) if media_pool else None
        if not imported:
            raise RuntimeError("Resolve did not import media.")
        return f"Импортировал {len(imported)} файлов."

    if tool == "create_empty_timeline":
        name = _safe_text(args.get("name")).strip() or f"New Timeline {datetime.now().strftime('%H%M%S')}"
        timeline = media_pool.CreateEmptyTimeline(name) if media_pool else None
        if not timeline:
            raise RuntimeError("Resolve did not create a timeline.")
        project.SetCurrentTimeline(timeline)
        resolve.OpenPage("edit")
        return f"Создал новый таймлайн: {name}."

    if tool == "set_current_timeline":
        name = _safe_text(args.get("name")).strip()
        if not name:
            raise RuntimeError("Timeline name is required.")
        timeline = _find_timeline_by_name(project, name)
        if not timeline:
            raise RuntimeError(f"Timeline not found: {name}")
        project.SetCurrentTimeline(timeline)
        resolve.OpenPage("edit")
        return f"Выбрал таймлайн: {name}."

    if tool == "create_timeline_from_clips":
        name = _safe_text(args.get("name")).strip() or f"New Timeline {datetime.now().strftime('%H%M%S')}"
        paths = _resolve_media_paths(list(args.get("paths") or []))
        clips = media_pool.ImportMedia(paths) if media_pool else None
        if not clips:
            raise RuntimeError("Resolve did not import source clips.")
        timeline = media_pool.CreateTimelineFromClips(name, clips)
        if not timeline:
            raise RuntimeError("Resolve did not create a timeline from clips.")
        project.SetCurrentTimeline(timeline)
        resolve.OpenPage("edit")
        return f"Создал таймлайн из клипов: {name}."

    if tool == "append_to_current_timeline":
        paths = _resolve_media_paths(list(args.get("paths") or []))
        clips = media_pool.ImportMedia(paths) if media_pool else None
        if not clips:
            raise RuntimeError("Resolve did not import source clips.")
        appended = media_pool.AppendToTimeline(clips)
        if not appended:
            raise RuntimeError("Resolve did not append clips to the current timeline.")
        return f"Добавил {len(appended)} клипов на текущий таймлайн."

    if tool == "set_current_timecode":
        timecode = _safe_text(args.get("timecode")).strip()
        timeline = project.GetCurrentTimeline()
        if not timeline:
            raise RuntimeError("No current timeline.")
        if not timeline.SetCurrentTimecode(timecode):
            raise RuntimeError(f"Could not set timecode: {timecode}")
        return f"Поставил курсор на {timecode}."

    if tool == "add_marker":
        name = _safe_text(args.get("name")).strip() or "Marker"
        color = _safe_text(args.get("color")).strip() or "Blue"
        frame = args.get("frame")
        timeline = project.GetCurrentTimeline()
        if not timeline:
            raise RuntimeError("No current timeline.")
        if frame is None:
            current_tc = timeline.GetCurrentTimecode() or "00:00:00:00"
            fps = float(project.GetSetting("timelineFrameRate") or 24)
            frame = 0
            try:
                hh, mm, ss, ff = [int(part) for part in current_tc.split(":")]
                frame = (((hh * 60 + mm) * 60) + ss) * int(round(fps)) + ff
            except Exception:
                frame = 0
        if not timeline.AddMarker(int(frame), color, name, "", 1, ""):
            raise RuntimeError("Could not add marker.")
        return f"Поставил маркер: {name}."

    if tool == "insert_textplus_title":
        title_name = _safe_text(args.get("title")).strip() or "Text+"
        text_value = _safe_text(args.get("text")).strip()
        return insert_textplus_helper(text_value, title_name)

    if tool == "click_menu":
        path = list(args.get("path") or [])
        if not path:
            raise RuntimeError("Menu path is required.")
        ui_mac.click_menu_path(path)
        return f"Нажал меню: {' > '.join(path)}."

    raise RuntimeError(f"Unknown tool: {tool}")


def normalize_action(action: dict[str, Any]) -> dict[str, Any]:
    tool = _safe_text(action.get("tool")).strip()
    args = action.get("args") or {}
    if not isinstance(args, dict):
        args = {}

    legacy_map = {
        "open_page": "open_page",
        "save_project": "save_project",
        "create_empty_timeline": "create_timeline",
        "import_media": "import_media",
        "append_to_current_timeline": "append_media",
        "set_current_timeline": "set_timeline",
        "set_current_timecode": "set_timecode",
        "insert_textplus_title": "insert_textplus",
        "add_marker": "add_marker",
    }
    if tool in legacy_map:
        helper_args = dict(args)
        if tool == "insert_textplus_title":
            helper_args = {"text": args.get("text", ""), "title": args.get("title", "Text+")}
        if tool == "create_empty_timeline":
            helper_args = {"name": args.get("name", "")}
        return {"tool": "call_helper", "args": {"name": legacy_map[tool], "args": helper_args}}

    known_helpers = {
        "open_page",
        "save_project",
        "create_timeline",
        "list_timelines",
        "set_timeline",
        "set_timecode",
        "import_media",
        "append_media",
        "create_timeline_from_media",
        "insert_textplus",
        "change_textplus",
        "animate_textplus",
        "add_marker",
        "add_generator",
        "add_adjustment_clip",
        "create_subtitles",
        "set_voice_isolation",
        "set_current_clip_transform",
        "apply_lut",
        "setup_mp4_export",
    }
    if tool in known_helpers:
        return {"tool": "call_helper", "args": {"name": tool, "args": args}}
    return action


def normalize_plan(plan: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(plan)
    normalized["actions"] = [
        normalize_action(action)
        for action in (plan.get("actions") or [])
        if isinstance(action, dict)
    ]
    return normalized


def state_changed(before: dict[str, Any], after: dict[str, Any]) -> bool:
    if not before or not after:
        return False
    return json.dumps(before, ensure_ascii=False, sort_keys=True) != json.dumps(after, ensure_ascii=False, sort_keys=True)


def action_expects_state_change(action: dict[str, Any]) -> bool:
    tool = _safe_text(action.get("tool")).strip()
    args = action.get("args") or {}
    if tool == "call_helper":
        helper_name = _safe_text((args if isinstance(args, dict) else {}).get("name")).strip()
        return helper_name not in {"list_timelines"}
    return tool not in {"open_page"}


def execute_plan(plan: dict[str, Any]) -> list[str]:
    actions = plan.get("actions") or []
    results: list[str] = []
    for action in actions:
        if not isinstance(action, dict):
            continue
        results.append(execute_action(action))
    return results


def build_repair_system_prompt(context: str, user_query: str) -> str:
    base_prompt = build_system_prompt(context, user_query)
    return (
        f"{base_prompt}\n"
        "Repair mode:\n"
        "You are repairing a failed Resolve action plan. Use the completed results, failed action, error, and current Resolve state.\n"
        "Return STRICT JSON with replacement actions only for the failed or remaining work.\n"
        "Prefer call_helper. Do not repeat the same failed API call. Do not claim success without an action.\n"
    )


def repair_actions(
    *,
    user_query: str,
    history: list[dict[str, Any]],
    context: str,
    original_plan: dict[str, Any],
    completed_results: list[str],
    failed_action: dict[str, Any],
    error: Exception,
    remaining_actions: list[dict[str, Any]],
    state_before: dict[str, Any] | None,
    state_after: dict[str, Any] | None,
    temperature: float,
    max_tokens: int,
) -> list[dict[str, Any]]:
    repair_context = current_project_context()
    repair_prompt = build_repair_system_prompt(repair_context or context, user_query)
    repair_payload = {
        "user_request": user_query,
        "available_helpers": HELPER_SCHEMAS,
        "original_plan": original_plan,
        "completed_results": completed_results,
        "failed_action": failed_action,
        "error": str(error),
        "remaining_actions": remaining_actions,
        "state_before_failed_action": state_before,
        "state_after_failed_action": state_after,
        "current_resolve_state": repair_context,
    }
    messages = [{"role": "system", "text": repair_prompt}]
    for item in history[-8:]:
        role = item.get("role", "user")
        content = item.get("content", "")
        messages.append({"role": role, "text": content})
    messages.append(
        {
            "role": "user",
            "text": (
                "Repair this failed Resolve plan. Return JSON only.\n"
                f"{json.dumps(repair_payload, ensure_ascii=False, indent=2)}"
            ),
        }
    )

    raw_text = call_yandex(messages, temperature=min(temperature, 0.2), max_tokens=max(max_tokens, 900))
    debug_log("YANDEX_REPAIR_RAW_TEXT", raw_text)
    plan = extract_json(raw_text)
    if not isinstance(plan, dict):
        raise RuntimeError("Yandex returned invalid repair plan.")
    plan = normalize_plan(plan)
    debug_log("YANDEX_REPAIR_PLAN", plan)
    actions = plan.get("actions") or []
    if not actions:
        raise RuntimeError("Yandex не вернул действий для ремонта ошибки.")
    return [action for action in actions if isinstance(action, dict)]


def execute_plan_with_repair(
    *,
    plan: dict[str, Any],
    user_query: str,
    history: list[dict[str, Any]],
    context: str,
    temperature: float,
    max_tokens: int,
) -> list[str]:
    actions = [action for action in (plan.get("actions") or []) if isinstance(action, dict)]
    results: list[str] = []
    index = 0
    repaired = False

    while index < len(actions):
        action = actions[index]
        state_before = resolve_state_snapshot()
        try:
            debug_log("ACTION_START", {"index": index, "action": action, "state_before": state_before})
            result = execute_action(action)
            state_after = resolve_state_snapshot()
            changed = state_changed(state_before, state_after)
            if action_expects_state_change(action) and not changed:
                debug_log(
                    "ACTION_NO_VISIBLE_STATE_CHANGE",
                    {"index": index, "action": action, "result": result, "state_before": state_before, "state_after": state_after},
                )
            debug_log("ACTION_DONE", {"index": index, "result": result, "state_after": state_after, "state_changed": changed})
            results.append(result)
            index += 1
        except Exception as exc:
            state_after = resolve_state_snapshot()
            debug_log(
                "ACTION_FAILED",
                {
                    "index": index,
                    "action": action,
                    "error": str(exc),
                    "completed_results": results,
                    "remaining_actions": actions[index + 1 :],
                    "state_before": state_before,
                    "state_after": state_after,
                },
            )
            if repaired:
                raise RuntimeError(f"{exc}. Повторный ремонт плана тоже не сработал.")
            repaired = True
            replacement = repair_actions(
                user_query=user_query,
                history=history,
                context=context,
                original_plan=plan,
                completed_results=results,
                failed_action=action,
                error=exc,
                remaining_actions=actions[index + 1 :],
                state_before=state_before,
                state_after=state_after,
                temperature=temperature,
                max_tokens=max_tokens,
            )
            actions = actions[:index] + replacement + actions[index + 1 :]
            debug_log("ACTION_REPAIRED_SEQUENCE", actions)

    return results


def looks_like_action_request(text: str) -> bool:
    lowered = text.lower()
    keywords = [
        "создай",
        "сделай",
        "добавь",
        "напиши",
        "поставь",
        "удали",
        "перемести",
        "импорт",
        "экспорт",
        "сохрани",
        "открой",
        "перейди",
        "вставь",
        "нарежь",
        "почисти",
        "смонтируй",
        "timeline",
        "таймлайн",
        "text",
        "текст",
        "title",
        "титр",
    ]
    return any(keyword in lowered for keyword in keywords)


def main() -> int:
    load_env()

    parser = argparse.ArgumentParser(description="DaVinci Resolve chat backend for Yandex GPT")
    parser.add_argument("request_file", nargs="?", help="JSON request file path")
    parser.add_argument("--prompt", help="Quick test prompt without Resolve")
    args = parser.parse_args()

    if args.prompt:
        request_data = {
            "messages": [{"role": "user", "content": args.prompt}],
            "context": "",
        }
    elif args.request_file:
        request_data = read_request(Path(args.request_file))
    else:
        raise SystemExit("Provide a request file or --prompt")

    context = request_data.get("context", "")
    history = request_data.get("messages") or []
    temperature = request_data.get("temperature", 0.2)
    max_tokens = request_data.get("max_tokens", 900)
    last_user_message = ""
    for item in reversed(history):
        if item.get("role") == "user":
            last_user_message = _safe_text(item.get("content"))
            break

    system_prompt = build_system_prompt(context, last_user_message)
    debug_log(
        "SYSTEM_PROMPT_STATS",
        {
            "chars": len(system_prompt),
            "user_query": last_user_message,
            "context_limit": DEFAULT_CONTEXT_CHAR_LIMIT,
        },
    )
    messages = [{"role": "system", "text": system_prompt}]
    for item in history:
        role = item.get("role", "user")
        content = item.get("content", "")
        messages.append({"role": role, "text": content})

    try:
        raw_text = call_yandex(messages, temperature=temperature, max_tokens=max_tokens)
        debug_log("YANDEX_RAW_TEXT", raw_text)
        plan = extract_json(raw_text)
        if not isinstance(plan, dict):
            raise RuntimeError("Yandex returned invalid plan.")
        plan = normalize_plan(plan)
        debug_log("YANDEX_PLAN", plan)

        if not plan.get("actions") and looks_like_action_request(last_user_message):
            repair_plan_actions = repair_actions(
                user_query=last_user_message,
                history=history,
                context=context,
                original_plan=plan,
                completed_results=[],
                failed_action={"tool": "none", "args": {}},
                error=RuntimeError("Initial plan contained no executable actions."),
                remaining_actions=[],
                state_before=None,
                state_after=None,
                temperature=temperature,
                max_tokens=max_tokens,
            )
            plan = {"reply": plan.get("reply", ""), "actions": repair_plan_actions}

        results = execute_plan_with_repair(
            plan=plan,
            user_query=last_user_message,
            history=history,
            context=context,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        debug_log("ACTION_RESULTS", results)
        reply = _safe_text(plan.get("reply")).strip()
        if results:
            reply = reply or "Готово."
            if len(results) == 1:
                reply = results[0]
            else:
                reply = "\n".join(results)

        sys.stdout.write("@@REPLY_START@@\n")
        sys.stdout.write(reply or "Готово.")
        sys.stdout.write("\n@@REPLY_END@@\n")
        return 0
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write("@@ERROR_START@@\n")
        sys.stdout.write(str(exc))
        sys.stdout.write("\n@@ERROR_END@@\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
