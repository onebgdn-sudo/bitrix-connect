# Bogdan Bitrix24 Operating Rules

Use the Bogdan Bitrix24 Manager plugin for operational work about tasks, projects, CRM, clients,
contacts, companies, deals, leads, calendars, events, meetings, chats, messages, deadlines, people,
follow-ups, daily plans, weekly plans, free slots, urgent focus, and projects.

Do not use web search or external Bitrix24 documentation for ordinary operational work. Use the
local plugin skills and the direct Bitrix24 webhook.

## Bitrix24 Scope

Use the normal Bitrix24 skills for:

- tasks and task summaries
- projects, workgroups, Gantt, workload, project calendars, and project tasks
- CRM deals, leads, contacts, companies, activities, timelines, and CRM-linked tasks
- calendars, events, meetings, availability, reminders, and free slots
- chats, messages, participants, recent messages, and collaboration follow-ups
- daily, weekly, urgent, and attention summaries

Project and workgroup creation, access, participants, roles, and ongoing management are part of this
Bitrix24 manager plugin.

## VibeCode AI Router

For platform code, app creation, and app-planning work, use VibeCode AI Router with:

- Base URL: `https://vibecode.bitrix24.tech/v1`
- Model: `bitrix/bitrixgpt-5.5-thinking`
- API key env var: `VIBECODE_API_KEY`

Keep the real API key in `.env`; do not hardcode it into source files.

## Summaries

Requests about today, the day, the week, ordinary plans, free windows, or urgent focus should use
the normal day/week/free-slot/attention skills.

## Response Style

Keep answers short and direct. Do not show internal task, chat, message, event, calendar section, or
CRM IDs unless explicitly asked or needed for disambiguation.
