import { kv } from "@vercel/kv";
import { google } from "googleapis";
import nodemailer from "nodemailer";
import { randomUUID } from "node:crypto";
import { createHmac, timingSafeEqual } from "node:crypto";

const DEFAULT_SETTINGS = {
  groups: ["Sản phẩm", "Cá nhân", "Đào tạo", "Truyền thông", "Đầu tư"],
  collaborators: []
};

const DEFAULT_STORE = {
  tasks: [],
  settings: DEFAULT_SETTINGS
};

const memoryStore = {
  tasks: [],
  settings: { ...DEFAULT_SETTINGS, collaborators: [] }
};

const SESSION_COOKIE = "vcl_session";
const SESSION_TTL_SECONDS = 60 * 60 * 24 * 14;

function getAuthConfig() {
  return {
    username: process.env.AUTH_USERNAME || "admin",
    password: process.env.AUTH_PASSWORD || "change-me-now",
    secret: process.env.AUTH_SECRET || "change-me-session-secret"
  };
}

function toBase64Url(input) {
  return Buffer.from(input, "utf8").toString("base64url");
}

function fromBase64Url(input) {
  return Buffer.from(input, "base64url").toString("utf8");
}

function signPayload(payloadB64, secret) {
  return createHmac("sha256", secret).update(payloadB64).digest("base64url");
}

function createSessionToken(username, secret) {
  const payload = JSON.stringify({
    u: username,
    exp: Date.now() + SESSION_TTL_SECONDS * 1000
  });
  const payloadB64 = toBase64Url(payload);
  const sig = signPayload(payloadB64, secret);
  return `${payloadB64}.${sig}`;
}

function verifySessionToken(token, secret) {
  if (!token || !token.includes(".")) return null;
  const [payloadB64, signature] = token.split(".");
  if (!payloadB64 || !signature) return null;
  const expected = signPayload(payloadB64, secret);
  const sigBuf = Buffer.from(signature);
  const expBuf = Buffer.from(expected);
  if (sigBuf.length !== expBuf.length) return null;
  if (!timingSafeEqual(sigBuf, expBuf)) return null;
  const payload = JSON.parse(fromBase64Url(payloadB64));
  if (!payload?.u || !payload?.exp || Date.now() > Number(payload.exp)) return null;
  return payload;
}

function parseCookies(req) {
  const header = req.headers.cookie || "";
  const cookies = {};
  for (const part of header.split(";")) {
    const [rawKey, ...rawValue] = part.trim().split("=");
    if (!rawKey) continue;
    cookies[rawKey] = decodeURIComponent(rawValue.join("=") || "");
  }
  return cookies;
}

function setSessionCookie(res, token) {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  const cookie = `${SESSION_COOKIE}=${encodeURIComponent(token)}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${SESSION_TTL_SECONDS}${secure}`;
  res.setHeader("Set-Cookie", cookie);
}

function clearSessionCookie(res) {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  const cookie = `${SESSION_COOKIE}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0${secure}`;
  res.setHeader("Set-Cookie", cookie);
}

function getAuthenticatedUser(req) {
  const { secret } = getAuthConfig();
  const cookies = parseCookies(req);
  const token = cookies[SESSION_COOKIE];
  const payload = verifySessionToken(token, secret);
  return payload?.u || null;
}

function hasKvConfig() {
  return Boolean(process.env.KV_REST_API_URL && process.env.KV_REST_API_TOKEN);
}

async function loadStore() {
  if (!hasKvConfig()) return memoryStore;
  const data = await kv.get("vcl:store");
  if (!data || typeof data !== "object") {
    await kv.set("vcl:store", DEFAULT_STORE);
    return { ...DEFAULT_STORE };
  }
  return {
    tasks: Array.isArray(data.tasks) ? data.tasks : [],
    settings: data.settings && typeof data.settings === "object" ? data.settings : DEFAULT_SETTINGS
  };
}

async function saveStore(store) {
  if (!hasKvConfig()) {
    memoryStore.tasks = store.tasks;
    memoryStore.settings = store.settings;
    return;
  }
  await kv.set("vcl:store", store);
}

async function readBody(req) {
  if (req.method === "GET" || req.method === "DELETE") return null;
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return null;
  return JSON.parse(raw);
}

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(payload));
}

/** Route after /api — supports rewrite ?__p=tasks/... and direct /api/... */
function getRouteParts(req) {
  const rawUrl = req.url || "/";
  let url;
  try {
    url = rawUrl.startsWith("http") ? new URL(rawUrl) : new URL(rawUrl, `http://${req.headers?.host || "localhost"}`);
  } catch {
    return [];
  }
  const fromQuery = url.searchParams.get("__p");
  if (fromQuery !== null && fromQuery !== "") {
    return fromQuery.split("/").filter(Boolean);
  }
  let pathname = url.pathname || "";
  pathname = pathname.replace(/^\/api\/gateway\/?/, "").replace(/^\/api\/?/, "");
  return pathname ? pathname.split("/").filter(Boolean) : [];
}

async function createCalendarEvent(task) {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_REFRESH_TOKEN;
  const calendarId = process.env.GOOGLE_CALENDAR_ID || "primary";
  const timezone = process.env.GOOGLE_TIMEZONE || "Asia/Ho_Chi_Minh";
  const reminderMinutes = Number(process.env.GOOGLE_REMINDER_MINUTES || 10);
  const durationMinutes = Number(process.env.GOOGLE_DURATION_MINUTES || 30);

  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error("Google Calendar env chưa cấu hình đủ.");
  }
  if (!task.deadline) {
    throw new Error("Task chưa có deadline.");
  }

  const oauth2Client = new google.auth.OAuth2(clientId, clientSecret);
  oauth2Client.setCredentials({ refresh_token: refreshToken });
  const calendar = google.calendar({ version: "v3", auth: oauth2Client });

  const start = new Date(task.deadline);
  const end = new Date(start.getTime() + durationMinutes * 60 * 1000);
  const response = await calendar.events.insert({
    calendarId,
    requestBody: {
      summary: task.title || "Task",
      description: task.details || "",
      start: { dateTime: start.toISOString(), timeZone: timezone },
      end: { dateTime: end.toISOString(), timeZone: timezone },
      reminders: {
        useDefault: false,
        overrides: [{ method: "popup", minutes: reminderMinutes }]
      },
      attendees: task.collaboratorEmail ? [{ email: task.collaboratorEmail }] : undefined
    }
  });

  return response.data;
}

async function sendAssignmentMail(task) {
  if (!task.collaboratorEmail) {
    throw new Error("Task chưa có email người phối hợp.");
  }

  const smtpHost = process.env.SMTP_HOST;
  const smtpPort = Number(process.env.SMTP_PORT || 587);
  const smtpUser = process.env.SMTP_USER;
  const smtpPassword = process.env.SMTP_PASSWORD;
  const fromEmail = process.env.SMTP_FROM_EMAIL || smtpUser;
  const useSsl = String(process.env.SMTP_USE_SSL || "true") === "true";

  if (!smtpHost || !smtpUser || !smtpPassword || !fromEmail) {
    throw new Error("SMTP env chưa cấu hình đủ.");
  }

  const transporter = nodemailer.createTransport({
    host: smtpHost,
    port: smtpPort,
    secure: useSsl,
    auth: { user: smtpUser, pass: smtpPassword }
  });

  const deadlineText = task.deadline ? new Date(task.deadline).toLocaleString("vi-VN") : "Chưa đặt";
  const html = `
    <h3>Giao việc mới</h3>
    <p><b>Tiêu đề:</b> ${task.title || ""}</p>
    <p><b>Nhóm:</b> ${task.group || "Chưa phân nhóm"}</p>
    <p><b>Deadline:</b> ${deadlineText}</p>
    <p><b>Chi tiết:</b> ${task.details || "Không có"}</p>
  `;

  await transporter.sendMail({
    from: fromEmail,
    to: task.collaboratorEmail,
    subject: `[VCL] ${task.title || "Nhiệm vụ mới"}`,
    html
  });
}

function upsertTask(baseTask, patch) {
  const next = { ...baseTask };
  for (const key of ["title", "deadline", "group", "collaboratorName", "collaboratorEmail", "details", "notes", "tags", "reminderType", "status"]) {
    if (Object.prototype.hasOwnProperty.call(patch, key)) {
      next[key] = patch[key];
    }
  }
  next.updatedAt = new Date().toISOString();
  return next;
}

export default async function handler(req, res) {
  try {
    const parts = getRouteParts(req);
    const method = req.method || "GET";
    const isAuthRoute = parts[0] === "auth";

    if (isAuthRoute && parts.length === 2 && parts[1] === "login" && method === "POST") {
      const body = await readBody(req);
      const username = String(body?.username || "").trim();
      const password = String(body?.password || "");
      const auth = getAuthConfig();
      if (username !== auth.username || password !== auth.password) {
        return sendJson(res, 401, { error: "Sai tài khoản hoặc mật khẩu." });
      }
      const token = createSessionToken(auth.username, auth.secret);
      setSessionCookie(res, token);
      return sendJson(res, 200, { ok: true, user: auth.username });
    }

    if (isAuthRoute && parts.length === 2 && parts[1] === "logout" && method === "POST") {
      clearSessionCookie(res);
      return sendJson(res, 200, { ok: true });
    }

    if (isAuthRoute && parts.length === 2 && parts[1] === "me" && method === "GET") {
      const user = getAuthenticatedUser(req);
      if (!user) return sendJson(res, 401, { authenticated: false });
      return sendJson(res, 200, { authenticated: true, user });
    }

    const user = getAuthenticatedUser(req);
    if (!user) {
      return sendJson(res, 401, { error: "unauthorized" });
    }

    const store = await loadStore();

    if (parts.length === 1 && parts[0] === "tasks" && method === "GET") {
      return sendJson(res, 200, store.tasks);
    }
    if (parts.length === 1 && parts[0] === "settings" && method === "GET") {
      return sendJson(res, 200, store.settings);
    }
    if (parts.length === 2 && parts[0] === "settings" && parts[1] === "groups" && method === "PUT") {
      const body = await readBody(req);
      const groups = Array.isArray(body?.groups) ? body.groups.map((x) => String(x).trim()).filter(Boolean) : [];
      store.settings = { ...store.settings, groups };
      await saveStore(store);
      return sendJson(res, 200, store.settings);
    }
    if (parts.length === 1 && parts[0] === "collaborators" && method === "POST") {
      const body = await readBody(req);
      const name = String(body?.name || "").trim();
      const email = String(body?.email || "").trim();
      if (!name || !email) return sendJson(res, 400, { error: "name and email are required" });

      const list = Array.isArray(store.settings.collaborators) ? [...store.settings.collaborators] : [];
      const existing = list.find((c) => c.email === email);
      if (existing) {
        existing.name = name;
      } else {
        list.push({ id: randomUUID(), name, email });
      }
      store.settings = { ...store.settings, collaborators: list };
      await saveStore(store);
      return sendJson(res, 200, store.settings);
    }
    if (parts.length === 2 && parts[0] === "collaborators" && method === "DELETE") {
      const id = parts[1];
      const list = Array.isArray(store.settings.collaborators) ? store.settings.collaborators.filter((c) => c.id !== id) : [];
      store.settings = { ...store.settings, collaborators: list };
      await saveStore(store);
      return sendJson(res, 200, store.settings);
    }
    if (parts.length === 1 && parts[0] === "tasks" && method === "POST") {
      const body = await readBody(req);
      const title = String(body?.title || "").trim();
      if (!title) return sendJson(res, 400, { error: "title is required" });

      const now = new Date().toISOString();
      const task = {
        id: randomUUID(),
        title,
        deadline: body?.deadline || null,
        group: body?.group || "",
        collaboratorName: body?.collaboratorName || "",
        collaboratorEmail: body?.collaboratorEmail || "",
        details: body?.details || body?.notes || "",
        notes: body?.notes || null,
        tags: Array.isArray(body?.tags) ? body.tags : [],
        reminderType: body?.reminderType || "none",
        status: "todo",
        createdAt: now,
        updatedAt: now
      };
      store.tasks = [...store.tasks, task];
      await saveStore(store);
      return sendJson(res, 201, { task, mail: { sent: false, reason: "manual_send_only" } });
    }
    if (parts.length === 2 && parts[0] === "tasks" && method === "PUT") {
      const taskId = parts[1];
      const body = await readBody(req);
      const idx = store.tasks.findIndex((t) => t.id === taskId);
      if (idx < 0) return sendJson(res, 404, { error: "task not found" });

      store.tasks[idx] = upsertTask(store.tasks[idx], body || {});
      await saveStore(store);
      return sendJson(res, 200, { task: store.tasks[idx], mail: { sent: false, reason: "manual_send_only" } });
    }
    if (parts.length === 2 && parts[0] === "tasks" && method === "DELETE") {
      const taskId = parts[1];
      store.tasks = store.tasks.filter((t) => t.id !== taskId);
      await saveStore(store);
      return sendJson(res, 200, { ok: true });
    }
    if (parts.length === 3 && parts[0] === "tasks" && parts[2] === "calendar-sync" && method === "POST") {
      const taskId = parts[1];
      const task = store.tasks.find((t) => t.id === taskId);
      if (!task) return sendJson(res, 404, { error: "task not found" });
      if (!task.deadline) return sendJson(res, 400, { error: "deadline is required before sync" });

      const event = await createCalendarEvent(task);
      return sendJson(res, 200, { ok: true, message: event?.htmlLink || "Calendar event created." });
    }
    if (parts.length === 3 && parts[0] === "tasks" && parts[2] === "send-email" && method === "POST") {
      const taskId = parts[1];
      const task = store.tasks.find((t) => t.id === taskId);
      if (!task) return sendJson(res, 404, { error: "task not found" });

      await sendAssignmentMail(task);
      return sendJson(res, 200, { ok: true, mail: { sent: true, reason: "ok" } });
    }

    return sendJson(res, 404, { error: "not found" });
  } catch (error) {
    return sendJson(res, 500, { error: error?.message || "internal error" });
  }
}
