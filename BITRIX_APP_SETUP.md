# Bitrix App Setup

This project is ready to be connected as a Bitrix24 app.

Current public test URL:

- `https://ed49cb6ae3530f.lhr.life`

Recommended Bitrix handler URLs:

- Left menu: `https://ed49cb6ae3530f.lhr.life/bitrix-entry.html?placement=LEFT_MENU`
- CRM contact tab: `https://ed49cb6ae3530f.lhr.life/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TAB`
- CRM contact toolbar: `https://ed49cb6ae3530f.lhr.life/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TOOLBAR`

What to register in Bitrix:

- App type: iframe / embedded app
- Main entry: `https://ed49cb6ae3530f.lhr.life/bitrix-entry.html`
- Left menu placement: `LEFT_MENU`
- Optional CRM placements:
  - `CRM_CONTACT_DETAIL_TAB`
  - `CRM_CONTACT_DETAIL_TOOLBAR`

Notes:

- The tunnel URL is temporary and can change if the local tunnel is restarted.
- The app uses `bitrix-entry.html` as the Bitrix-safe entrypoint.
- `index.html` is the main UI shell.
- `bitrix-placement-config.json` contains the intended placements and runtime messages.
