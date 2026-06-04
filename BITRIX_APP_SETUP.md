# Bitrix App Setup

This project is ready to be connected as a Bitrix24 app.

Current public test URL:

- `https://bitrixconnectbogdan3.loca.lt`

Recommended Bitrix handler URLs:

- Left menu: `https://bitrixconnectbogdan3.loca.lt/bitrix-entry.html?placement=LEFT_MENU`
- CRM contact tab: `https://bitrixconnectbogdan3.loca.lt/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TAB`
- CRM contact toolbar: `https://bitrixconnectbogdan3.loca.lt/bitrix-entry.html?placement=CRM_CONTACT_DETAIL_TOOLBAR`

What to register in Bitrix:

- App type: iframe / embedded app
- Main entry: `https://bitrixconnectbogdan3.loca.lt/bitrix-entry.html`
- Left menu placement: `LEFT_MENU`
- Optional CRM placements:
  - `CRM_CONTACT_DETAIL_TAB`
  - `CRM_CONTACT_DETAIL_TOOLBAR`

Notes:

- The tunnel URL is temporary and can change if the local tunnel is restarted.
- The app uses `bitrix-entry.html` as the Bitrix-safe entrypoint.
- `index.html` is the main UI shell.
- `bitrix-placement-config.json` contains the intended placements and runtime messages.
