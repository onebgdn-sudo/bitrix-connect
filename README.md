# Bitrix Connect

Рабочее название приложения: **Carte Showbiz / Карта шоубизнеса**.

Цель MVP: чат внутри/рядом с Bitrix24, который помогает искать музыкальные контакты,
собирать досье, видеть связи и сохранять полезных людей в CRM.

## MVP Architecture

- `app/index.html` - фронтенд приложения и Bitrix placement UI.
- `app/bitrix-entry.html` - входная точка для Bitrix24.
- `app/backend.py` - локальный backend для чата, Yandex GPT, журналов и Bitrix REST.
- `runtime/research_tasks.jsonl` - локальный журнал исследовательских запросов.
- `POST /api/research/parse` - отдельный парсер публичных URL для извлечения заголовка, ссылок, контактов и базовых сигналов.

Главная идея: фронтенд остается легким, а секреты Yandex/Bitrix живут на backend,
чтобы не класть ключи в браузерный JavaScript.

## Быстрый запуск MVP

```bash
python3 app/backend.py
```

После запуска открыть:

```text
http://127.0.0.1:8787/index.html
```

Если backend выключен, интерфейс продолжит работать в демо-режиме.

## Bitrix24

Для записи в CRM backend ожидает:

```bash
BITRIX_WEBHOOK_URL=https://your-domain.bitrix24.ru/rest/user_id/webhook_code
```

Если переменная не задана, backend пробует взять уже настроенный локальный webhook из
`bitrix24-webhook.txt`, который использует Bitrix24-плагин Codex.

Парсер сейчас умеет читать публичные страницы по URL и вытаскивать сигналы вроде title,
description, links, emails, phones и тематические маркеры. Это отдельный слой, который потом
можно расширять до очереди URL, краулинга и нормализации в CRM-поля.

Сейчас приложение уже подготовлено для пункта левого меню через placement `LEFT_MENU`.
Код placement лежит в `app/bitrix-placement-config.json`.

## AI Router

- Base URL: `https://vibecode.bitrix24.tech/v1`
- Model: `bitrix/bitrixgpt-5.5-thinking`
- API key: хранится локально в `.env`

VibeCode не обязателен для MVP. Основной LLM-путь сейчас идет через Yandex GPT.

## Быстрая проверка

```bash
python3 vibecode_client.py
```

## Использование

```python
from vibecode_client import ask

answer = ask("Что такое CRM?")
print(answer)
```

## REAPER chat agent

В папке `reaper_agent/` лежит стартовый каркас чата прямо внутри REAPER.
Он подключается к Yandex GPT через локальный Python-скрипт и умеет
выполнять базовые команды в REAPER.

Файлы:

- `reaper_agent/reaper_chat_agent.lua`
- `reaper_agent/reaper_agent_backend.py`

Никаких дополнительных UI-расширений ставить не нужно.

## DaVinci Resolve chat agent

В папке `resolve_agent/` лежит чат прямо внутри DaVinci Resolve Studio.
Он открывает плавающее окно и отправляет сообщения в Yandex GPT.
Backend анализирует запрос на естественном языке и выполняет действия через
официальный Python Scripting API DaVinci Resolve.

Файлы:

- `resolve_agent/resolve_chat_agent.lua`
- `resolve_agent/resolve_agent_backend.py`
- `resolve_agent/resolve_manual.md`

## Bitrix app shell

Локальный каркас приложения лежит в `app/`.

Входы:

- `app/index.html` - основной экран
- `app/mobile.html` - мобильный тест
- `app/bitrix-entry.html` - точка входа для Bitrix placement/handler
- `app/bitrix-placement-config.json` - подсказка по placements и runtime-сообщениям

Поддерживаемые query-параметры:

- `placement` - например `LEFT_MENU` или `CRM_CONTACT_DETAIL_TAB`
- `placement_options` - JSON-строка с данными карточки, например `{"ID":"42"}`
- `member_id` - идентификатор портала/сессии
- `mobile=1` - мобильный режим

Для Bitrix удобнее использовать `app/bitrix-entry.html` как handler URL, а он уже перенаправит в основной экран с сохранением контекста.
