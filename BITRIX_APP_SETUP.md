# Bitrix App Setup

This project is ready to be connected as a Bitrix24 app.

Current public URL:

- `https://YOUR_STABLE_DOMAIN`

Recommended Bitrix handler URLs:

- Left menu: `https://YOUR_STABLE_DOMAIN/bitrix-entry.html?placement=LEFT_MENU`
- CRM contact tab: `https://YOUR_STABLE_DOMAIN/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TAB`
- CRM contact toolbar: `https://YOUR_STABLE_DOMAIN/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TOOLBAR`

What to register in Bitrix:

- App type: iframe / embedded app
- Main entry: `https://YOUR_STABLE_DOMAIN/bitrix-entry.html`
- Left menu placement: `LEFT_MENU`
- Optional CRM placements:
  - `CRM_CONTACT_DETAIL_TAB`
  - `CRM_CONTACT_DETAIL_TOOLBAR`

Notes:

- Do not use temporary tunnels for production. A stable domain is required.
- The app uses `bitrix-entry.html` as the Bitrix-safe entrypoint.
- The backend exposes `GET /runtime-config.json` and `GET /healthz` so the front-end can discover its host and show a basic health signal.
- `index.html` is the main UI shell.
- `bitrix-placement-config.json` contains the intended placements and runtime messages.
