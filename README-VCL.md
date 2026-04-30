# VCL (Viec can lam) - local web app

## Run

```powershell
.\Start-VCLServer.ps1
```

Open:

- <http://localhost:8088>

## Current features

- Purple lightweight UI, centered task board.
- Quick-add task input (Google Keep style).
- Drag-drop between `Can lam` and `Hoan thanh`.
- Inline edit (title, deadline, collaborator email, notes, tags, reminder type).
- Important tasks are auto-sorted to the top.
- One-click sync task with deadline to Google Calendar.
- Data saved locally in `data/tasks.json`.

## Next upgrades (already planned for deployment)

- Real email sender for collaborator (SMTP or provider API).
- Auto reminder worker (daily/weekly/custom time via scheduler).
- Cloud database + authentication.
- Responsive polish for phone/tablet and internet deployment.

## Deploy on Vercel

This repo uses `api/gateway.js` plus a `vercel.json` rewrite so every `/api/*` request hits one Node function (reliable on Vercel). Redeploy after pulling changes.

### 1) Install and run local

```powershell
npm install
npm run dev
```

### 2) Create Vercel KV (required for persistent data)

- In Vercel dashboard, add **KV** storage to this project.
- Vercel will auto-inject:
  - `KV_REST_API_URL`
  - `KV_REST_API_TOKEN`

Without KV, API still runs but data is only in-memory (lost after redeploy/cold start).

### 3) Set project environment variables

For login protection (required):

- `AUTH_USERNAME`
- `AUTH_PASSWORD`
- `AUTH_SECRET`

For email:

- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASSWORD`
- `SMTP_FROM_EMAIL`
- `SMTP_USE_SSL` (`true` or `false`)

For Google Calendar:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REFRESH_TOKEN`
- `GOOGLE_CALENDAR_ID` (default `primary`)
- `GOOGLE_TIMEZONE` (default `Asia/Ho_Chi_Minh`)
- `GOOGLE_REMINDER_MINUTES` (default `10`)
- `GOOGLE_DURATION_MINUTES` (default `30`)

### 4) Deploy

```powershell
npx vercel
```

For production:

```powershell
npx vercel --prod
```

### Deploy qua GitHub (không cần chạy CLI trên máy)

Repo có workflow `.github/workflows/deploy-vercel.yml`: mỗi lần **push lên `main` hoặc `master`** sẽ tự deploy production lên Vercel.

Trên GitHub: **Settings → Secrets and variables → Actions → New repository secret**, thêm:

| Secret | Lấy ở đâu |
|--------|-----------|
| `VERCEL_TOKEN` | [vercel.com/account/tokens](https://vercel.com/account/tokens) |
| `VERCEL_ORG_ID` | Vercel → Project **vcl-viec-can-lam** → Settings → General → **Team ID** (dạng `team_...`) |
| `VERCEL_PROJECT_ID` | Cùng trang → **Project ID** (dạng `prj_...`) |

Sau đó push code lên GitHub; tab **Actions** sẽ hiện bản deploy. Có thể chạy tay: **Actions → Deploy to Vercel → Run workflow**.

### Login flow

- Open app URL -> if not authenticated, you are redirected to `/login.html`.
- Sign in using `AUTH_USERNAME` + `AUTH_PASSWORD`.
- Session is stored in an HttpOnly cookie.

## Security notes

- Do not commit real secrets in:
  - `data/mail-config.json`
  - `google-calendar.config.json`
  - `google-calendar.token.json`
- Rotate any SMTP password, OAuth client secret, and refresh token that were previously committed.
