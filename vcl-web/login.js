const form = document.getElementById("loginForm");
const usernameInput = document.getElementById("username");
const passwordInput = document.getElementById("password");
const errorText = document.getElementById("errorText");
const loginBtn = document.getElementById("loginBtn");

async function api(path, options = {}) {
  const res = await fetch(path, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    ...options
  });
  let payload = {};
  try {
    payload = await res.json();
  } catch {
    payload = {};
  }
  if (!res.ok) {
    throw new Error(payload.error || "Đăng nhập thất bại.");
  }
  return payload;
}

async function checkAlreadyLoggedIn() {
  try {
    const me = await api("/api/auth/me", { method: "GET" });
    if (me?.authenticated) {
      window.location.href = "/";
    }
  } catch {
    // Not logged in, keep page.
  }
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  errorText.textContent = "";
  loginBtn.disabled = true;
  try {
    await api("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({
        username: usernameInput.value.trim(),
        password: passwordInput.value
      })
    });
    window.location.href = "/";
  } catch (err) {
    errorText.textContent = err.message;
  } finally {
    loginBtn.disabled = false;
  }
});

checkAlreadyLoggedIn();
