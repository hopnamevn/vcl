# Google Calendar Reminder Setup (PowerShell)

This project uses pure PowerShell scripts to connect your Google account and create reminder events.

## 1) Create Google OAuth credentials

1. Open <https://console.cloud.google.com/>.
2. Create/select a project.
3. Enable **Google Calendar API**.
4. Go to **APIs & Services** -> **Credentials**.
5. Create **OAuth client ID**:
   - Application type: **Desktop app** (recommended), or Web app.
6. In OAuth client settings, add this redirect URI:
   - `http://localhost:65001/`
7. Copy your `client_id` and `client_secret`.

## 2) Configure local file

1. Copy:
   - `google-calendar.config.example.json` -> `google-calendar.config.json`
2. Fill:
   - `client_id`
   - `client_secret`
   - optionally `timezone`, `calendar_id`, default minutes

## 3) Connect once (OAuth)

Run:

```powershell
.\Connect-GoogleCalendar.ps1
```

Browser opens for sign-in and consent. On success, token is saved to:

- `google-calendar.token.json`

### Alternative (no localhost callback): Device Code flow

If localhost callback is blocked on your machine, run:

```powershell
.\Connect-GoogleCalendar-Device.ps1
```

It prints a URL + code. Open URL, enter code, approve access. Script then saves token automatically.

## 4) Create reminders

Example:

```powershell
.\Add-CalendarReminder.ps1 -Title "Hop voi team" -StartAt "2026-04-29 09:00" -DurationMinutes 45 -ReminderMinutes 10 -Description "Tong ket sprint"
```

## Notes

- Keep `google-calendar.token.json` and `google-calendar.config.json` private.
- If refresh token stops working, run `.\Connect-GoogleCalendar.ps1` again.
