#!/usr/bin/env python3
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


APP_DIR = Path(__file__).resolve().parent
ROOT_DIR = APP_DIR.parent
LOG_DIR = ROOT_DIR / "runtime"
RESEARCH_LOG = LOG_DIR / "research_tasks.jsonl"
BITRIX_INSTALL_LOG = LOG_DIR / "bitrix_app_install.jsonl"
WEBHOOK_FILE_CANDIDATES = [
    ROOT_DIR / "outputs" / "bitrix24-webhook.txt",
    Path.home() / "Documents" / "Codex" / "outputs" / "bitrix24-webhook.txt",
]
WEBHOOK_SEARCH_ROOT = Path.home() / "Documents" / "Codex"


def load_env(path=ROOT_DIR / ".env"):
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


load_env()

PUBLIC_BASE_URL = os.getenv("CARTE_PUBLIC_BASE_URL", "").strip().rstrip("/")
API_BASE_URL = os.getenv("CARTE_API_BASE_URL", "").strip().rstrip("/")


def runtime_config_payload():
    public_base_url = PUBLIC_BASE_URL or ""
    api_base_url = API_BASE_URL or ""
    return {
        "publicBaseUrl": public_base_url,
        "apiBaseUrl": api_base_url,
        "indexPath": "/index.html",
        "entryPath": "/bitrix-entry.html",
        "mobilePath": "/mobile.html",
        "deploymentMode": "stable" if public_base_url else "local",
        "timestamp": int(time.time()),
    }


DEMO_CONTACTS = [
    {
        "id": "fargo",
        "name": "Fargo",
        "alias": "Fargo",
        "role": "Продюсер / артист",
        "city": "Москва / online",
        "country": "Россия",
        "summary": "Работает на пересечении релизов, продюсирования и коллабораций.",
        "whyFound": "В запросе есть продюсеры и коллаборации; у Fargo много публичных связей.",
        "relevance": 92,
        "importance": 87,
        "usefulness": "Может быть полезен как продюсер, артист и точка входа к смежным людям.",
        "sources": ["demo: public music graph", "demo: release mentions"],
        "links": ["Instagram: @fargo", "Telegram: t.me/fargo", "Spotify artist page"],
        "connections": ["Artem V.", "A&R Studio", "Moskva Live", "Luna Beat"],
        "confidence": 0.74,
        "awaitingReply": False,
        "lastTouchDays": 1,
        "replyDue": "today",
        "stageHint": "active_dialog",
        "responsePriority": 42,
        "nextAction": "держать связь и предлагать коллаборацию",
    },
    {
        "id": "lunabeat",
        "name": "Luna Beat",
        "alias": "Luna Beat",
        "role": "Продюсер / артист",
        "city": "Москва / online",
        "country": "Россия",
        "summary": "Соседняя творческая сущность с сильными коллаборациями.",
        "whyFound": "Похожий продюсерский контур и связи с артистами.",
        "relevance": 81,
        "importance": 73,
        "usefulness": "Подходит для поиска продакшн-цепочки и коллабораций.",
        "sources": ["demo: social links", "demo: collab mentions"],
        "links": ["Instagram: @lunabeat", "Spotify", "Telegram"],
        "connections": ["Fargo", "Artem V."],
        "confidence": 0.62,
        "awaitingReply": True,
        "lastTouchDays": 0,
        "replyDue": "today",
        "stageHint": "waiting_reply",
        "responsePriority": 84,
        "nextAction": "ответить с контекстом и предложить следующий шаг",
    },
    {
        "id": "olegstage",
        "name": "Oleg Stage",
        "alias": "Oleg Stage",
        "role": "Концертный агент",
        "city": "Москва",
        "country": "Россия",
        "summary": "Связующий контур по площадкам и туровой активности.",
        "whyFound": "Может быть маршрутом выхода через концерты и площадки.",
        "relevance": 68,
        "importance": 70,
        "usefulness": "Полезен как путь к артистам через живые события.",
        "sources": ["demo: booking graph"],
        "links": ["Telegram", "VK", "Site"],
        "connections": ["Fargo", "Moskva Live"],
        "confidence": 0.58,
        "awaitingReply": True,
        "lastTouchDays": 3,
        "replyDue": "today",
        "stageHint": "waiting_reply",
        "responsePriority": 91,
        "nextAction": "срочно написать и закрыть вопрос по площадкам",
    },
]

SOURCE_LIBRARY = [
    {
        "key": "official_profiles",
        "title": "Официальные профили",
        "priority": "high",
        "yields": ["био", "ссылки", "контактные каналы", "актуальные роли"],
        "examples": ["Instagram bio", "VK profile", "Telegram bio", "site about page"],
    },
    {
        "key": "music_platforms",
        "title": "Музыкальные платформы",
        "priority": "high",
        "yields": ["релизы", "артист-ID", "метрики", "лейблы", "соавторы"],
        "examples": ["Yandex Music", "Spotify", "Apple Music", "Beatport", "SoundCloud"],
    },
    {
        "key": "press_mentions",
        "title": "Пресса и упоминания",
        "priority": "high",
        "yields": ["менеджеры", "цитаты", "контекст", "связи", "география"],
        "examples": ["interviews", "articles", "podcasts", "event announcements"],
    },
    {
        "key": "live_activity",
        "title": "Концерты и афиши",
        "priority": "medium",
        "yields": ["площадки", "туры", "букинг", "ивенты", "организаторы"],
        "examples": ["concert posters", "venue pages", "ticket listings", "tour calendars"],
    },
    {
        "key": "social_graph",
        "title": "Социальный граф",
        "priority": "high",
        "yields": ["общие контакты", "коллаборации", "фиты", "теги", "взаимные связи"],
        "examples": ["tagged posts", "reposts", "mentions", "shared stories"],
    },
    {
        "key": "direct_contacts",
        "title": "Прямые контакты",
        "priority": "high",
        "yields": ["email", "phone", "telegram", "booking channel", "manager contact"],
        "examples": ["bio email", "linked forms", "booking page", "press contact"],
    },
]


def read_raw_body(handler):
    length = int(handler.headers.get("Content-Length") or 0)
    return handler.rfile.read(length).decode("utf-8", errors="replace") if length else ""


def read_json_body(handler):
    raw = read_raw_body(handler) or "{}"
    return json.loads(raw or "{}")


def read_bitrix_body(handler):
    raw = read_raw_body(handler)
    if not raw:
        return {}
    content_type = (handler.headers.get("Content-Type") or "").lower()
    if "application/json" in content_type:
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"_raw": raw}
    parsed = urllib.parse.parse_qs(raw, keep_blank_values=True)
    return {key: values[-1] if values else "" for key, values in parsed.items()}


def write_json(handler, payload, status=200):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def log_research(entry):
    LOG_DIR.mkdir(exist_ok=True)
    payload = {"createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **entry}
    with RESEARCH_LOG.open("a", encoding="utf-8") as log_file:
        log_file.write(json.dumps(payload, ensure_ascii=False) + "\n")


def log_bitrix_install(payload):
    LOG_DIR.mkdir(exist_ok=True)
    safe_payload = dict(payload)
    for key in list(safe_payload):
        if any(part in key.lower() for part in ["auth", "token", "secret", "refresh"]):
            safe_payload[key] = "[stored locally]"
    with BITRIX_INSTALL_LOG.open("a", encoding="utf-8") as log_file:
        log_file.write(json.dumps({"createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "payload": safe_payload}, ensure_ascii=False) + "\n")


def is_bitrix_entry_path(path):
    clean_path = urllib.parse.urlparse(path).path
    return clean_path in {"/", "/index.html", "/bitrix-entry.html", "/mobile.html"}


def classify_request(prompt):
    lower = prompt.lower()
    if any(word in lower for word in ["сроч", "urgent", "кто требует ответа", "кому написать", "кто ждет", "кто ждёт", "надо ответить", "требует ответа", "важно ответить"]):
        return "attention"
    if any(word in lower for word in ["вериф", "подтвер", "провер"]):
        return "verification"
    if any(word in lower for word in ["контакт", "email", "почт", "телефон", "whatsapp", "telegram"]):
        return "contact_search"
    if any(word in lower for word in ["анализ", "досье", "разбери"]):
        return "analysis"
    if any(word in lower for word in ["найди", "покажи", "собери", "поиск"]):
        return "discovery"
    return "general"


def build_source_queries(prompt, candidates):
    lower = prompt.lower()
    query_fragments = []
    if "релиз" in lower:
        query_fragments.append("release discography")
    if "фит" in lower or "feat" in lower or "collab" in lower:
        query_fragments.append("collaboration credits")
    if "контакт" in lower or "email" in lower or "телефон" in lower:
        query_fragments.append("contact bio booking press")
    if "площад" in lower or "ивент" in lower or "концерт" in lower:
        query_fragments.append("event venue booking")
    if "продюсер" in lower or "producer" in lower:
        query_fragments.append("producer network")
    if not query_fragments:
        query_fragments.append("public music footprint")

    sources = []
    for candidate in candidates[:5]:
        base = candidate.get("name") or candidate.get("alias") or "unknown"
        sources.extend([
            f'{base} {fragment}' for fragment in query_fragments
        ])
        sources.extend([
            f'{base} {link.split(":")[0].strip() if ":" in link else link} profile'
            for link in (candidate.get("links") or [])[:3]
        ])
    return list(dict.fromkeys(sources))[:12]


def build_source_targets(prompt, candidates):
    intent = classify_request(prompt)
    lower = prompt.lower()
    selected = []
    for source in SOURCE_LIBRARY:
        priority = source["priority"]
        boost = 0
        if intent == "contact_search" and source["key"] in {"direct_contacts", "official_profiles", "social_graph"}:
            boost += 2
        if intent == "verification" and source["key"] in {"official_profiles", "music_platforms", "press_mentions"}:
            boost += 2
        if intent == "discovery" and source["key"] in {"social_graph", "press_mentions", "music_platforms"}:
            boost += 1
        if any(word in lower for word in ["релиз", "release", "трек"]):
            if source["key"] == "music_platforms":
                boost += 2
        if any(word in lower for word in ["контакт", "email", "телефон", "telegram"]):
            if source["key"] == "direct_contacts":
                boost += 2
        selected.append({
            "key": source["key"],
            "title": source["title"],
            "priority": priority,
            "why": "Подходит под запрос и обычно даёт самый полезный сигнал.",
            "yields": source["yields"],
            "examples": source["examples"],
            "score": 10 if priority == "high" else 6,
            "boost": boost,
        })
    selected.sort(key=lambda item: (item["boost"], item["score"]), reverse=True)
    return selected[:5]


def build_candidate_facts(candidate):
    links = candidate.get("links") or []
    connections = candidate.get("connections") or []
    confidence = float(candidate.get("confidence") or 0.5)
    awaiting_reply = bool(candidate.get("awaitingReply"))
    last_touch_days = candidate.get("lastTouchDays")
    if last_touch_days is None:
        last_touch_days = 999
    response_priority = int(candidate.get("responsePriority") or 0)
    stage_hint = candidate.get("stageHint") or ("waiting_reply" if awaiting_reply else "active_dialog")
    reply_due = candidate.get("replyDue") or ("today" if awaiting_reply else "not urgent")
    next_action = candidate.get("nextAction") or (
        "срочно написать и проверить статус ответа" if awaiting_reply else "поддерживать контакт"
    )
    urgency_score = response_priority
    if awaiting_reply:
        urgency_score += 40
    if int(last_touch_days) == 0:
        urgency_score += 10
    elif int(last_touch_days) <= 2:
        urgency_score += 6
    if "waiting" in stage_hint:
        urgency_score += 10
    if "today" in str(reply_due).lower():
        urgency_score += 8
    if "сроч" in str(next_action).lower():
        urgency_score += 6
    urgency_score = min(100, urgency_score)
    return {
        "name": candidate.get("name") or candidate.get("alias") or "Unknown",
        "role": candidate.get("role") or "Музыкальный контакт",
        "city": candidate.get("city") or "—",
        "country": candidate.get("country") or "—",
        "summary": candidate.get("summary") or "",
        "whyFound": candidate.get("whyFound") or "",
        "links": links,
        "connections": connections,
        "confidence": confidence,
        "confidencePercent": round(confidence * 100),
        "sources": candidate.get("sources") or [],
        "signals": {
            "relevance": candidate.get("relevance") or 60,
            "importance": candidate.get("importance") or 50,
            "usefulness": candidate.get("usefulness") or "",
        },
        "communication": {
            "awaitingReply": awaiting_reply,
            "lastTouchDays": int(last_touch_days),
            "replyDue": reply_due,
            "stageHint": stage_hint,
            "nextAction": next_action,
            "responsePriority": response_priority,
            "urgencyScore": urgency_score,
        },
        "missing": [
            item for item in [
                "email" if not any("@" in link for link in links) else None,
                "phone" if not any(re.search(r"\+?\d[\d\s()-]{7,}", link) for link in links) else None,
                "direct intro" if len(connections) < 2 else None,
            ] if item
        ],
    }


def build_bitrix_field_preview(candidate):
    facts = build_candidate_facts(candidate)
    role = facts["role"]
    kind = "artist" if "артист" in role.lower() else "producer" if "продюсер" in role.lower() else "contact"
    methods = facts["links"][:3]
    communication = facts["communication"]
    field_groups = [
        {
            "title": "Профиль",
            "meta": "ядро досье",
            "items": [
                ["NAME", facts["name"]],
                ["UF_CRM_MUSIC_ENTITY_KIND", kind],
                ["UF_CRM_MUSIC_CITY", facts["city"]],
                ["UF_CRM_MUSIC_COUNTRY", facts["country"]],
                ["UF_CRM_MUSIC_ROLE", role],
            ],
        },
        {
            "title": "Выводы",
            "meta": "то, что важно",
            "items": [
                ["UF_CRM_MUSIC_SUMMARY", facts["summary"] or "—"],
                ["UF_CRM_MUSIC_WHY_FOUND", facts["whyFound"] or "—"],
                ["UF_CRM_MUSIC_CONFIDENCE", f"{facts['confidencePercent']}%"],
                ["UF_CRM_MUSIC_RELEVANCE", str(facts["signals"]["relevance"])],
                ["UF_CRM_MUSIC_IMPORTANCE", str(facts["signals"]["importance"])],
            ],
        },
        {
            "title": "Контакты и связи",
            "meta": "что можно использовать",
            "items": [
                ["UF_CRM_MUSIC_CONTACT_METHODS", "<br>".join(methods) or "—"],
                ["UF_CRM_MUSIC_RELATIONS", ", ".join(facts["connections"][:6]) or "—"],
                ["UF_CRM_MUSIC_MISSING_DATA", ", ".join(facts["missing"]) or "—"],
                ["UF_CRM_MUSIC_SOURCES", ", ".join(facts["sources"]) or "—"],
            ],
        },
        {
            "title": "Коммуникация",
            "meta": "кому писать сейчас",
            "items": [
                ["UF_CRM_MUSIC_RESPONSE_STATUS", "waiting_reply" if communication["awaitingReply"] else "active_dialog"],
                ["UF_CRM_MUSIC_RESPONSE_PRIORITY", str(communication["responsePriority"])],
                ["UF_CRM_MUSIC_REPLY_REQUIRED", "Yes" if communication["awaitingReply"] else "No"],
                ["UF_CRM_MUSIC_REPLY_DEADLINE", communication["replyDue"]],
                ["UF_CRM_MUSIC_LAST_TOUCH", f"{communication['lastTouchDays']}d ago" if communication["lastTouchDays"] != 0 else "today"],
                ["UF_CRM_MUSIC_STAGE_HINT", communication["stageHint"]],
                ["UF_CRM_MUSIC_NEXT_ACTION", communication["nextAction"]],
                ["UF_CRM_MUSIC_URGENCY_SCORE", str(communication["urgencyScore"])],
            ],
        },
    ]
    return {
        "entityKind": kind,
        "coreFields": {
            "NAME": facts["name"],
            "COMMENTS": "\n".join([
                facts["summary"],
                f"Роль: {role}",
                f"Почему найден: {facts['whyFound']}",
                f"Уверенность: {facts['confidencePercent']}%",
                f"Источники: {', '.join(facts['sources']) or '—'}",
            ]).strip(),
        },
        "signals": {
            "confidence": facts["confidencePercent"],
            "relevance": facts["signals"]["relevance"],
            "importance": facts["signals"]["importance"],
            "city": facts["city"],
            "country": facts["country"],
            "contactMethods": methods,
            "missing": facts["missing"],
            "communication": communication,
        },
        "fieldGroups": field_groups,
    }


def build_research_report(prompt, candidates):
    intent = classify_request(prompt)
    source_targets = build_source_targets(prompt, candidates)
    search_queries = build_source_queries(prompt, candidates)
    candidate_reports = []
    missing_union = []

    for candidate in candidates:
        facts = build_candidate_facts(candidate)
        bitrix_preview = build_bitrix_field_preview(candidate)
        candidate_reports.append({
            "id": candidate.get("id"),
            "name": facts["name"],
            "role": facts["role"],
            "confidence": facts["confidencePercent"],
            "signals": facts["signals"],
            "connections": facts["connections"][:6],
            "links": facts["links"][:5],
            "whyFound": facts["whyFound"],
            "summary": facts["summary"],
            "missing": facts["missing"],
            "bitrixPreview": bitrix_preview,
            "dossier": {
                "summary": facts["summary"],
                "insight": facts["signals"]["usefulness"] or facts["summary"],
                "sourceSignals": facts["sources"],
                "fieldGroups": bitrix_preview.get("fieldGroups") or [],
                "bitrixFields": bitrix_preview.get("coreFields") or {},
                "relations": facts["connections"][:6],
                "contactMethods": facts["links"][:3],
                "readyForOutreach": "phone" not in facts["missing"] and len(facts["connections"]) >= 2,
                "missing": facts["missing"],
            },
        })
        missing_union.extend(facts["missing"])

    missing_union = list(dict.fromkeys(missing_union))
    return {
        "intent": intent,
        "pipeline": [
            "1. Разобрать запрос и понять цель.",
            "2. Собрать public source targets по роли, каналам и связям.",
            "3. Пылесосить сигналы из соцсетей, платформ, прессы и афиш.",
            "4. Нормализовать факты, убрать мусор и дубли.",
            "5. Разделить подтвержденное, вероятное и неподтвержденное.",
            "6. Подготовить поля для Bitrix и короткий вывод для карточки.",
        ],
        "sourceTargets": source_targets,
        "searchQueries": search_queries,
        "candidateReports": candidate_reports,
        "missingUnion": missing_union,
        "summary": (
            "Система должна пылесосить публичные источники, потом складывать не сырье, а "
            "нормализованный досье-пакет: факты, связи, контакты, сигналы и поля для Bitrix."
        ),
        "nextActions": [
            "Сначала добрать public sources и ссылки.",
            "Потом извлечь прямые контакты и тёплые входы.",
            "После этого записать только очищенные поля в CRM.",
        ],
    }


def build_attention_report(prompt, contacts):
    scored = []
    for candidate in contacts:
        facts = build_candidate_facts(candidate)
        communication = facts["communication"]
        score = communication["urgencyScore"]
        if candidate.get("id") == "olegstage":
            score += 4
        if candidate.get("id") == "lunabeat":
            score += 2
        if candidate.get("id") == "fargo":
            score -= 10
        scored.append({
            "id": candidate.get("id"),
            "name": facts["name"],
            "role": facts["role"],
            "score": min(100, max(0, score)),
            "status": "needs_reply" if communication["awaitingReply"] else "active",
            "replyDue": communication["replyDue"],
            "lastTouch": communication["lastTouchDays"],
            "stageHint": communication["stageHint"],
            "nextAction": communication["nextAction"],
            "reason": (
                f"Ждёт ответа: {communication['awaitingReply']}. "
                f"Последний контакт: {communication['lastTouchDays']} дн. назад. "
                f"Стадия: {communication['stageHint']}."
            ),
            "bitrixFields": build_bitrix_field_preview(candidate).get("fieldGroups") or [],
        })
    scored.sort(key=lambda item: item["score"], reverse=True)
    top = scored[:4]
    return {
        "title": "Кому писать сейчас",
        "summary": "Я выделил людей, у которых уже есть ожидание ответа или накапливается пауза в коммуникации.",
        "top": top,
        "message": (
            "Сначала отвечаем тем, кто ждёт ответа или завис в коммуникации. "
            "Это должно отражаться как отдельная стадия и отдельный статус в досье CRM."
        ),
        "crmStageModel": {
            "needs_reply": "WAITING_FOR_REPLY",
            "active": "ACTIVE_DIALOG",
            "cold": "NEEDS_REACTIVATION",
        },
    }


def build_attention_answer(attention):
    top_names = ", ".join(item["name"] for item in (attention or {}).get("top", [])[:3]) or "никого"
    lines = [f"Сейчас в первую очередь: {top_names}."]
    for item in (attention or {}).get("top", [])[:3]:
        lines.append(
            f"{item['name']}: стадия {item['stageHint']}, приоритет {item['score']}/100, следующий шаг: {item['nextAction']}."
        )
    return "\n".join(lines)


def call_yandex(prompt, candidates, research=None):
    api_key = os.getenv("YANDEX_API_KEY", "").strip()
    iam_token = os.getenv("YANDEX_IAM_TOKEN", "").strip()
    model_uri = os.getenv("YANDEX_MODEL_URI", "").strip()
    api_url = os.getenv(
        "YANDEX_API_URL",
        "https://llm.api.cloud.yandex.net/foundationModels/v1/completion",
    ).strip()

    if not model_uri or not (api_key or iam_token):
        return None

    system = (
        "Ты помощник CRM-разведки музыкального рынка. "
        "Отвечай коротко, прикладно, отмечай подтвержденные данные и предположения. "
        "Не выдумывай приватные данные."
    )
    user = (
        f"Запрос пользователя: {prompt}\n\n"
        f"Кандидаты из текущей базы/демо-исследования:\n"
        f"{json.dumps(candidates, ensure_ascii=False)}\n\n"
        f"План и структура парсинга:\n"
        f"{json.dumps(research or {}, ensure_ascii=False)}\n\n"
        "Сформулируй короткий ответ: что найдено, почему это полезно, что делать дальше."
    )
    payload = {
        "modelUri": model_uri,
        "completionOptions": {"stream": False, "temperature": 0.2, "maxTokens": "700"},
        "messages": [
            {"role": "system", "text": system},
            {"role": "user", "text": user},
        ],
    }
    headers = {"Content-Type": "application/json"}
    headers["Authorization"] = f"Api-Key {api_key}" if api_key else f"Bearer {iam_token}"
    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.loads(response.read().decode("utf-8"))
    alternatives = (data.get("result") or {}).get("alternatives") or data.get("alternatives") or []
    if not alternatives:
        return None
    message = alternatives[0].get("message") or {}
    return (message.get("text") or message.get("content") or "").strip() or None


def select_candidates(prompt):
    lower = prompt.lower()
    tokens = set(re.findall(r"[a-zа-яё0-9@._-]{3,}", lower))
    matches = []
    for contact in DEMO_CONTACTS:
        haystack = " ".join(
            [
                contact["name"],
                contact["role"],
                contact["summary"],
                " ".join(contact["connections"]),
                " ".join(contact["links"]),
            ]
        ).lower()
        if not tokens or any(token in haystack for token in tokens):
            matches.append(contact)
    if "продюсер" in lower or "producer" in lower:
        matches = [c for c in DEMO_CONTACTS if "продюсер" in c["role"].lower()] or matches
    return matches or DEMO_CONTACTS[:2]


def get_bitrix_webhook_url():
    env_url = os.getenv("BITRIX_WEBHOOK_URL", "").strip()
    if env_url:
        return env_url.rstrip("/")

    for path in WEBHOOK_FILE_CANDIDATES:
        if path.exists():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value.rstrip("/")

    if WEBHOOK_SEARCH_ROOT.exists():
        webhook_files = sorted(
            WEBHOOK_SEARCH_ROOT.glob("**/bitrix24-webhook.txt"),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        for path in webhook_files:
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value.rstrip("/")

    return ""


def bitrix_call(method, params):
    webhook_url = get_bitrix_webhook_url()
    if not webhook_url:
        raise RuntimeError("Bitrix webhook is not configured")
    url = f"{webhook_url}/{method}.json"
    request = urllib.request.Request(
        url,
        data=json.dumps(params, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Bitrix REST error {exc.code}: {raw[:500]}") from exc


def bitrix_contact_fields(candidate):
    fields = {
        "NAME": candidate.get("name") or candidate.get("alias") or "Unknown",
        "COMMENTS": "\n".join(
            [
                candidate.get("summary", ""),
                f"Роль: {candidate.get('role', '')}",
                f"Почему найден: {candidate.get('whyFound', '')}",
                f"Уверенность: {candidate.get('confidence', '')}",
                f"Источники: {', '.join(candidate.get('sources') or [])}",
            ]
        ),
    }
    if candidate.get("city"):
        fields["ADDRESS_CITY"] = candidate["city"]
    return fields


def _html_to_text(html):
    text = re.sub(r"(?is)<(script|style|noscript).*?>.*?</\\1>", " ", html)
    text = re.sub(r"(?is)<br\\s*/?>", "\n", text)
    text = re.sub(r"(?is)</p\\s*>", "\n", text)
    text = re.sub(r"(?is)<[^>]+>", " ", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _extract_first(pattern, text, flags=0):
    match = re.search(pattern, text, flags)
    return match.group(1).strip() if match else ""


def _extract_all(pattern, text, flags=0):
    return list(dict.fromkeys(
        item.strip() for item in re.findall(pattern, text, flags)
        if item and item.strip()
    ))


def _fetch_public_page(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise RuntimeError("Only http and https URLs are supported")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 CarteShowbiz/1.0"},
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        content_type = response.headers.get_content_type()
        charset = response.headers.get_content_charset() or "utf-8"
        raw = response.read().decode(charset, errors="replace")

    if content_type not in {"text/html", "application/xhtml+xml", "text/plain"}:
        return {
            "url": url,
            "contentType": content_type,
            "title": "",
            "description": "",
            "emails": [],
            "phones": [],
            "links": [],
            "signals": [],
            "textSample": "",
            "status": "unsupported_content_type",
        }

    title = _extract_first(r"(?is)<title[^>]*>(.*?)</title>", raw)
    description = _extract_first(
        r'(?is)<meta[^>]+name=["\']description["\'][^>]+content=["\']([^"\']+)["\']',
        raw,
    )
    text = _html_to_text(raw)
    emails = _extract_all(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})", raw)
    phones = _extract_all(r"(\+?\d[\d\s().-]{7,}\d)", raw)
    hrefs = _extract_all(r'href=["\']([^"\']+)["\']', raw)
    links = []
    for href in hrefs:
        if href.startswith(("mailto:", "tel:", "#", "javascript:")):
            continue
        links.append(urllib.parse.urljoin(url, href))
    links = list(dict.fromkeys(links))[:20]

    lower = f"{title}\n{description}\n{text}".lower()
    signals = []
    for key, markers in [
        ("booking", ["booking", "book", "booking@", "manager"]),
        ("press", ["press", "pr@", "media"]),
        ("social", ["instagram", "telegram", "vk", "youtube", "tiktok"]),
        ("music", ["release", "track", "album", "single", "feat"]),
        ("events", ["tour", "gig", "concert", "show", "live"]),
    ]:
        if any(marker in lower for marker in markers):
            signals.append(key)

    return {
        "url": url,
        "contentType": content_type,
        "title": title,
        "description": description,
        "emails": emails,
        "phones": phones,
        "links": links,
        "signals": signals,
        "textSample": text[:800],
        "status": "ok",
    }


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(APP_DIR), **kwargs)

    def do_GET(self):
        clean_path = urllib.parse.urlparse(self.path).path
        if clean_path in {"/runtime-config.json", "/api/runtime-config"}:
            write_json(self, runtime_config_payload())
            return
        if clean_path in {"/healthz", "/api/healthz"}:
            write_json(
                self,
                {
                    "ok": True,
                    "service": "Carte Showbiz",
                    "mode": runtime_config_payload()["deploymentMode"],
                    "publicBaseUrl": runtime_config_payload()["publicBaseUrl"],
                },
            )
            return
        super().do_GET()

    def do_POST(self):
        try:
            clean_path = urllib.parse.urlparse(self.path).path

            if clean_path == "/api/chat":
                body = read_json_body(self)
                prompt = (body.get("message") or "").strip()
                candidates = select_candidates(prompt)
                research = build_research_report(prompt, candidates)
                attention = build_attention_report(prompt, DEMO_CONTACTS) if research.get("intent") == "attention" else None
                answer = call_yandex(prompt, candidates, research)
                if attention:
                    answer = build_attention_answer(attention)
                elif not answer:
                    answer = (
                        f"Нашел {len(candidates)} кандидатов. "
                        "Показываю тех, у кого есть роль, связи, польза и источники. "
                        "Неподтвержденные данные помечены уровнем уверенности."
                    )
                log_research({
                    "type": "chat",
                    "prompt": prompt,
                    "candidateCount": len(candidates),
                    "intent": research.get("intent"),
                    "sourceTargetCount": len(research.get("sourceTargets") or []),
                })
                write_json(self, {"answer": answer, "candidates": candidates, "research": research, "attention": attention})
                return

            if clean_path == "/api/bitrix/add-contact":
                body = read_json_body(self)
                candidate = body.get("candidate") or {}
                result = bitrix_call("crm.contact.add", {"fields": bitrix_contact_fields(candidate)})
                write_json(self, {"ok": True, "result": result})
                return

            if clean_path == "/api/bitrix/status":
                result = bitrix_call("user.current", {})
                write_json(
                    self,
                    {
                        "ok": True,
                        "connected": True,
                        "user": {
                            "name": result.get("result", {}).get("NAME"),
                            "lastName": result.get("result", {}).get("LAST_NAME"),
                        },
                    },
                )
                return

            if clean_path == "/api/follow-up":
                body = read_json_body(self)
                title = body.get("title") or "Follow-up по музыкальному контакту"
                description = body.get("description") or ""
                result = bitrix_call("tasks.task.add", {"fields": {"TITLE": title, "DESCRIPTION": description}})
                write_json(self, {"ok": True, "result": result})
                return

            if clean_path == "/api/research/parse":
                body = read_json_body(self)
                urls = [str(url).strip() for url in (body.get("urls") or []) if str(url).strip()]
                focus = (body.get("focus") or "").strip()
                reports = []
                for url in urls[:10]:
                    try:
                        reports.append(_fetch_public_page(url))
                    except Exception as exc:
                        reports.append({
                            "url": url,
                            "status": "error",
                            "error": str(exc),
                            "title": "",
                            "description": "",
                            "emails": [],
                            "phones": [],
                            "links": [],
                            "signals": [],
                            "textSample": "",
                        })
                write_json(
                    self,
                    {
                        "ok": True,
                        "focus": focus,
                        "count": len(reports),
                        "reports": reports,
                        "summary": "Парсер собрал публичные страницы и вытащил сигналы, которые можно нормализовать в CRM.",
                    },
                )
                return

            if is_bitrix_entry_path(self.path):
                payload = read_bitrix_body(self)
                if payload:
                    log_bitrix_install(payload)
                self.do_GET()
                return

            write_json(self, {"error": "Unknown endpoint"}, status=404)
        except Exception as exc:
            write_json(self, {"error": str(exc)}, status=500)


def main():
    port = int(os.getenv("CARTE_PORT", "8787"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Carte Showbiz backend: http://127.0.0.1:{port}/index.html")
    server.serve_forever()


if __name__ == "__main__":
    main()
