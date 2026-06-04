#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path


HERE = Path(__file__).resolve().parent


def trim(text: str | None) -> str:
    return str(text or "").strip()


def has_token(text: str, token: str) -> bool:
    return token.lower() in trim(text).lower()


def load_catalog() -> list[dict]:
    source = (HERE / "reaper_plugin_catalog.lua").read_text(encoding="utf-8")
    plugins: list[dict] = []
    for block in re.findall(r"\{\s*display_name\s*=.*?\n\s*\},", source, flags=re.S):
        display = re.search(r'display_name\s*=\s*"([^"]+)"', block)
        exact = re.search(r'exact_reaper_fx_name\s*=\s*"([^"]+)"', block)
        aliases_match = re.search(r"aliases\s*=\s*\{([^}]*)\}", block, flags=re.S)
        aliases = re.findall(r'"([^"]+)"', aliases_match.group(1)) if aliases_match else []
        plugins.append(
            {
                "display_name": display.group(1) if display else "",
                "exact_reaper_fx_name": exact.group(1) if exact else "",
                "aliases": aliases,
            }
        )
    return plugins


CATALOG = load_catalog()


def matches_known_plugin(text: str) -> bool:
    normalized = trim(text).lower()
    for plugin in CATALOG:
        haystack = [
            plugin.get("display_name", ""),
            plugin.get("exact_reaper_fx_name", ""),
            *plugin.get("aliases", []),
        ]
        for item in haystack:
            item = trim(item).lower()
            if item and item in normalized:
                return True
    return False


def extract_plugin_query(text: str) -> str:
    cleaned = trim(text)
    if not cleaned:
        return ""

    create_match = (
        re.search(r"^[Сс]делай\s+[Тт]рек\s+с\s+(.+)$", cleaned)
        or re.search(r"^[Сс]делай\s+[Дд]орожку\s+с\s+(.+)$", cleaned)
        or re.search(r"^[Сс]оздай\s+[Тт]рек\s+с\s+(.+)$", cleaned)
        or re.search(r"^[Сс]оздай\s+[Дд]орожку\s+с\s+(.+)$", cleaned)
        or re.search(r"^[Сс]делай\s+[Тт]рек\s+with\s+(.+)$", cleaned, flags=re.I)
        or re.search(r"^[Сс]оздай\s+[Тт]рек\s+with\s+(.+)$", cleaned, flags=re.I)
        or re.search(r"^[Сс]делай\s+[Дд]орожку\s+with\s+(.+)$", cleaned, flags=re.I)
        or re.search(r"^[Сс]оздай\s+[Дд]орожку\s+with\s+(.+)$", cleaned, flags=re.I)
    )
    if create_match:
        cleaned = create_match.group(1)

    add_match = (
        re.search(r"[Дд]обавь\s+(.+)\s+[Нн]а\s+выбранный\s+трек", cleaned)
        or re.search(r"[Дд]обавь\s+(.+)\s+[Нн]а\s+этот\s+трек", cleaned)
        or re.search(r"[Вв]ставь\s+(.+)\s+[Нн]а\s+выбранный\s+трек", cleaned)
        or re.search(r"[Вв]ставь\s+(.+)\s+[Нн]а\s+этот\s+трек", cleaned)
        or re.search(r"[Пп]оставь\s+(.+)\s+[Нн]а\s+выбранный\s+трек", cleaned)
        or re.search(r"[Пп]оставь\s+(.+)\s+[Нн]а\s+этот\s+трек", cleaned)
        or re.search(r"[Зз]акинь\s+(.+)\s+[Нн]а\s+выбранный\s+трек", cleaned)
        or re.search(r"[Зз]акинь\s+(.+)\s+[Нн]а\s+этот\s+трек", cleaned)
        or re.search(r"[Дд]обавь\s+[Нн]а\s+выбранный\s+трек\s+(.+)", cleaned)
        or re.search(r"[Дд]обавь\s+[Нн]а\s+этот\s+трек\s+(.+)", cleaned)
        or re.search(r"[Вв]ставь\s+[Нн]а\s+выбранный\s+трек\s+(.+)", cleaned)
        or re.search(r"[Вв]ставь\s+[Нн]а\s+этот\s+трек\s+(.+)", cleaned)
        or re.search(r"[Пп]оставь\s+[Нн]а\s+выбранный\s+трек\s+(.+)", cleaned)
        or re.search(r"[Пп]оставь\s+[Нн]а\s+этот\s+трек\s+(.+)", cleaned)
        or re.search(r"[Зз]акинь\s+[Нн]а\s+выбранный\s+трек\s+(.+)", cleaned)
        or re.search(r"[Зз]акинь\s+[Нн]а\s+этот\s+трек\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+выбранный\s+трек\s+[Пп]оставь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+выбранный\s+трек\s+[Дд]обавь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+выбранный\s+трек\s+[Вв]ставь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+выбранный\s+трек\s+[Зз]акинь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+этот\s+трек\s+[Пп]оставь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+этот\s+трек\s+[Дд]обавь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+этот\s+трек\s+[Вв]ставь\s+(.+)", cleaned)
        or re.search(r"[Нн]а\s+этот\s+трек\s+[Зз]акинь\s+(.+)", cleaned)
    )
    if add_match:
        cleaned = add_match.group(1)

    match = re.search(r"\s[Сс]\s+(.+)$", cleaned) or re.search(r"\swith\s+(.+)$", cleaned, flags=re.I)
    if match and any(
        has_token(cleaned, marker)
        for marker in ("трек", "дорож", "track", "еще одну", "ещё одну", "еще один", "ещё один")
    ):
        cleaned = match.group(1)

    replacements = [
        r"^[Оо]ткрой\s+",
        r"^open\s+",
        r"^[Зз]апусти\s+",
        r"^load\s+",
        r"^[Дд]обавь\s+",
        r"^[Зз]акинь\s+",
        r"^[Вв]ставь\s+",
        r"^[Дд]обавить\s+",
        r"^[Вв]ставить\s+",
        r"^[Пп]лагин\s+",
        r"^[Пп]лагином\s+",
        r"^[Пп]лагин\s+на\s+трек\s+",
        r"^[Пп]оставь\s+",
        r"^[Мм]ожно\s+ещ[её]\s+",
        r"^[Мм]ожно\s+",
        r"^[Ии]нструмент\s+",
        r"^[Ии]нструментом\s+",
        r"^[Оо]ткрыть\s+",
        r"^[Вв]\s+н[её]м\s+",
        r"^[Вв]\s+н[её]й\s+",
        r"^[Нн]а\s+н[её]м\s+",
        r"^[Нн]а\s+н[её]й\s+",
        r"^[Нн]а\s+выбранный\s+трек\s+",
        r"^[Нн]а\s+трек\s+",
        r"^[Вв]\s+трек\s+",
        r"^[Нн]овую\s+дорожку\s+с\s+",
        r"^[Нн]овый\s+трек\s+с\s+",
        r"^[Дд]орожку\s+с\s+",
        r"^[Тт]рек\s+с\s+",
        r"^[Ее]ще\s+одну\s+с\s+",
        r"^[Ее]щё\s+одну\s+с\s+",
        r"^[Ее]ще\s+один\s+с\s+",
        r"^[Ее]щё\s+один\s+с\s+",
        r"^[Сс]\s+",
        r"^[Пп]лагин\s+",
        r"\s+[Пп]ожалуйста$",
        r"\s+please$",
    ]
    for pattern in replacements:
        cleaned = re.sub(pattern, "", cleaned)
    return trim(cleaned)


def wants_new_plugin_track(text: str) -> bool:
    normalized = trim(text).lower()
    if any(marker in normalized for marker in ("на выбранный трек", "на этот трек", "в нем", "в ней", "на нем", "на ней")):
        return False
    if any(
        marker in normalized
        for marker in ("новую дорожку с", "новую дорожку with", "новый трек с", "новый трек with", "track with")
    ):
        return True
    if any(marker in normalized for marker in ("еще одну с", "ещё одну с", "еще один с", "ещё один с", "another one with")):
        return True
    if not ("трек" in normalized or "дорож" in normalized):
        return False
    return any(marker in normalized for marker in ("создай", "сделай", "добавь", "еще", "ещё"))


def likely_midi_create_command(text: str) -> bool:
    lowered = text.lower()
    if ("," in lowered or " и " in lowered) and any(
        word in lowered for word in ("добавь", "вставь", "открой", "плагин")
    ):
        return False
    if ("," in lowered or " и " in lowered) and matches_known_plugin(lowered):
        return False
    return ("миди" in lowered or "midi" in lowered) and any(
        word in lowered
        for word in ("сделай", "создай", "добавь", "сгенерируй", "напиши", "парт", "клип")
    )


def likely_plugin_command(text: str, query: str) -> bool:
    normalized = trim(text).lower()
    cleaned_query = trim(query)
    if not cleaned_query:
        return False
    if ("миди" in normalized or "midi" in normalized) and ("," in normalized or " и " in normalized):
        return False
    if likely_midi_create_command(normalized):
        return False
    if wants_new_plugin_track(normalized):
        return True
    if matches_known_plugin(normalized) or matches_known_plugin(cleaned_query):
        return True
    if any(marker in normalized for marker in ("открой", "open", "load", "запусти", "плагин", "plugin", "instrument", "инструмент")):
        return True
    if any(marker in normalized for marker in ("добавь", "вставь", "поставь", "закинь")):
        return not ("трек" in cleaned_query.lower() or "дорож" in cleaned_query.lower())
    return False


def classify(text: str) -> dict:
    query = extract_plugin_query(text)
    if likely_plugin_command(text, query):
        return {
            "route": "plugin_fast",
            "query": query,
            "new_track": wants_new_plugin_track(text),
            "steps": ["create_track", "insert_fx"] if wants_new_plugin_track(text) else ["insert_fx"],
        }
    lowered = text.lower()
    if likely_midi_create_command(text):
        return {"route": "midi_create_fast", "steps": ["create_midi_item", "write_midi_notes"]}
    if any(word in lowered for word in ("измени", "поменяй", "переделай", "квантиз", "подровняй")) and any(word in lowered for word in ("миди", "midi", "парт", "эту")):
        return {"route": "midi_edit_fast", "steps": ["quantize_midi"]}
    return {"route": "planner"}


SCENARIOS = [
    ("создай дорожку с arturia analog lab", "plugin_fast", "arturia analog lab", True),
    ("сделай трек с омнисферой", "plugin_fast", "омнисферой", True),
    ("создай еще одну с омнисферой", "plugin_fast", "омнисферой", True),
    ("еще один с serum", "plugin_fast", "serum", True),
    ("добавь валхаллу на выбранный трек", "plugin_fast", "валхаллу", False),
    ("открой Kontakt", "plugin_fast", "Kontakt", False),
    ("вставь fabfilter pro q 3", "plugin_fast", "fabfilter pro q 3", False),
    ("поставь плагин portal", "plugin_fast", "portal", False),
    ("load pigments", "plugin_fast", "pigments", False),
    ("новую дорожку с pigments пожалуйста", "plugin_fast", "pigments", True),
    ("сделай трек с diva", "plugin_fast", "diva", True),
    ("закинь soothe2 на этот трек", "plugin_fast", "soothe2", False),
    ("поставь на выбранный трек pro q 3", "plugin_fast", "pro q 3", False),
    ("добавь на этот трек valhalla vintageverb", "plugin_fast", "valhalla vintageverb", False),
    ("вставь на выбранный трек autotune", "plugin_fast", "autotune", False),
    ("можно еще одну с kontakt", "plugin_fast", "kontakt", True),
    ("новый трек with massive x", "plugin_fast", "massive x", True),
    ("track with serum please", "plugin_fast", "serum", True),
    ("на выбранный трек поставь pro-l 2", "plugin_fast", "pro-l 2", False),
    ("открой мне омнисферу", "plugin_fast", "мне омнисферу", False),
    ("открой в нем эквалайзер", "plugin_fast", "эквалайзер", False),
    ("сделай простую миди партию для этого трека", "midi_create_fast", None, None),
    ("измени эту партию как-нибудь", "midi_edit_fast", None, None),
    ("подровняй миди", "midi_edit_fast", None, None),
    ("сделай басовую дорожку, добавь serum и напиши midi", "planner", None, None),
    ("создай 3 дорожки: analog lab, kontakt, serum и сделай им midi", "planner", None, None),
    ("сделай интро, куплет, дроп и экспортни стемы", "planner", None, None),
]


def main() -> int:
    failures = []
    rows = []
    for phrase, expected_route, expected_query, expected_new_track in SCENARIOS:
        result = classify(phrase)
        ok = result["route"] == expected_route
        if expected_query is not None:
            ok = ok and result.get("query") == expected_query
        if expected_new_track is not None:
            ok = ok and result.get("new_track") == expected_new_track
        rows.append({"phrase": phrase, "expected": expected_route, "actual": result, "ok": ok})
        if not ok:
            failures.append(rows[-1])

    print(json.dumps({"ok": not failures, "failures": failures, "rows": rows}, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
