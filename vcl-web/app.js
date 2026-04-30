const todoList = document.getElementById("todoList");
const doneList = document.getElementById("doneList");
const template = document.getElementById("taskTemplate");
const quickInput = document.getElementById("quickInput");
const addBtn = document.getElementById("addBtn");
const toggleManageBtn = document.getElementById("toggleManageBtn");
const managePanel = document.getElementById("managePanel");
const datalist = document.getElementById("collaboratorList");
const groupChips = document.getElementById("groupChips");
const newGroupInput = document.getElementById("newGroupInput");
const addGroupBtn = document.getElementById("addGroupBtn");
const collabNameInput = document.getElementById("collabNameInput");
const collabEmailInput = document.getElementById("collabEmailInput");
const saveCollabBtn = document.getElementById("saveCollabBtn");
const collabList = document.getElementById("collabList");
const logoutBtn = document.getElementById("logoutBtn");

let tasks = [];
let draggingId = null;
let settings = { groups: [], collaborators: [] };
let isAdding = false;
const expandedTaskIds = new Set();

async function api(path, options = {}) {
  const res = await fetch(path, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    ...options
  });
  if (res.status === 401) {
    window.location.href = "/login.html";
    throw new Error("Unauthorized");
  }
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

function normalizeDateInput(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const offset = date.getTimezoneOffset() * 60000;
  return new Date(date - offset).toISOString().slice(0, 16);
}

function sortTasks(items) {
  return [...items].sort((a, b) => {
    const aImp = (a.tags || []).includes("important") ? 1 : 0;
    const bImp = (b.tags || []).includes("important") ? 1 : 0;
    if (aImp !== bImp) return bImp - aImp;
    return new Date(a.createdAt) - new Date(b.createdAt);
  });
}

function renderSettings() {
  groupChips.innerHTML = "";
  datalist.innerHTML = "";

  for (const group of settings.groups || []) {
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.textContent = group;
    const rm = document.createElement("button");
    rm.type = "button";
    rm.textContent = "x";
    rm.addEventListener("click", async () => {
      settings.groups = (settings.groups || []).filter(g => g !== group);
      await api("/api/settings/groups", { method: "PUT", body: JSON.stringify({ groups: settings.groups }) });
      render();
      renderSettings();
    });
    chip.appendChild(rm);
    groupChips.appendChild(chip);
  }

  for (const c of settings.collaborators || []) {
    const option = document.createElement("option");
    option.value = c.name;
    option.label = `${c.name} (${c.email})`;
    datalist.appendChild(option);
  }

  renderCollaboratorsList();
}

function renderCollaboratorsList() {
  collabList.innerHTML = "";
  for (const c of settings.collaborators || []) {
    const row = document.createElement("div");
    row.className = "collab-row";

    const left = document.createElement("div");
    left.className = "left";

    const name = document.createElement("div");
    name.className = "name";
    name.textContent = c.name;

    const email = document.createElement("div");
    email.className = "email";
    email.textContent = c.email;

    left.appendChild(name);
    left.appendChild(email);

    const del = document.createElement("button");
    del.type = "button";
    del.className = "del";
    del.textContent = "Xóa";
    del.addEventListener("click", async () => {
      await api(`/api/collaborators/${c.id}`, { method: "DELETE" });
      settings = await api("/api/settings", { method: "GET" });
      renderSettings();
      render();
    });

    row.appendChild(left);
    row.appendChild(del);
    collabList.appendChild(row);
  }
}

function render() {
  todoList.innerHTML = "";
  doneList.innerHTML = "";

  const todo = sortTasks(tasks.filter(t => t.status !== "done"));
  const done = sortTasks(tasks.filter(t => t.status === "done"));
  todo.forEach(t => todoList.appendChild(renderTask(t)));
  done.forEach(t => doneList.appendChild(renderTask(t)));
}

function onFieldSave(taskId, patch) {
  const idx = tasks.findIndex(t => t.id === taskId);
  if (idx < 0) return;
  tasks[idx] = { ...tasks[idx], ...patch, updatedAt: new Date().toISOString() };
  render();
  api(`/api/tasks/${taskId}`, { method: "PUT", body: JSON.stringify(patch) })
    .then(res => {
      if (res && res.task) {
        const pos = tasks.findIndex(t => t.id === taskId);
        if (pos >= 0) tasks[pos] = res.task;
      }
    })
    .catch(err => alert("Lưu thay đổi lỗi: " + err.message));
}

function renderTask(task) {
  const node = template.content.firstElementChild.cloneNode(true);
  node.dataset.id = task.id;
  node.classList.remove("important", "urgent", "longterm");
  if ((task.tags || []).includes("important")) node.classList.add("important");
  if ((task.tags || []).includes("urgent")) node.classList.add("urgent");
  if ((task.tags || []).includes("longterm")) node.classList.add("longterm");

  const details = node.querySelector(".task-details");
  const expand = node.querySelector(".expand");
  const applyExpandedState = () => {
    const isExpanded = expandedTaskIds.has(task.id);
    details.classList.toggle("hidden", !isExpanded);
    expand.textContent = isExpanded ? "▾" : "▸";
  };
  applyExpandedState();
  expand.addEventListener("click", () => {
    if (expandedTaskIds.has(task.id)) {
      expandedTaskIds.delete(task.id);
    } else {
      expandedTaskIds.add(task.id);
    }
    applyExpandedState();
  });

  const title = node.querySelector(".title");
  title.value = task.title || "";
  title.addEventListener("change", () => onFieldSave(task.id, { title: title.value.trim() }));

  const groupBadge = node.querySelector(".group-badge");
  groupBadge.textContent = task.group || "Chưa nhóm";

  const groupSelect = node.querySelector(".groupSelect");
  groupSelect.innerHTML = "";
  const noneGroup = document.createElement("option");
  noneGroup.value = "";
  noneGroup.textContent = "Chưa chọn nhóm";
  groupSelect.appendChild(noneGroup);
  (settings.groups || []).forEach(g => {
    const op = document.createElement("option");
    op.value = g;
    op.textContent = g;
    groupSelect.appendChild(op);
  });
  groupSelect.value = task.group || "";
  groupSelect.addEventListener("change", () => onFieldSave(task.id, { group: groupSelect.value || "" }));

  const deadline = node.querySelector(".deadline");
  deadline.value = normalizeDateInput(task.deadline);
  deadline.addEventListener("change", () => onFieldSave(task.id, { deadline: deadline.value ? new Date(deadline.value).toISOString() : null }));

  const collaboratorName = node.querySelector(".collaboratorName");
  collaboratorName.value = task.collaboratorName || "";
  collaboratorName.addEventListener("change", () => {
    const selected = (settings.collaborators || []).find(c => c.name.toLowerCase() === collaboratorName.value.trim().toLowerCase());
    if (selected) {
      email.value = selected.email;
      onFieldSave(task.id, { collaboratorName: selected.name, collaboratorEmail: selected.email });
    } else {
      onFieldSave(task.id, { collaboratorName: collaboratorName.value.trim() });
    }
  });

  const email = node.querySelector(".email");
  email.value = task.collaboratorEmail || "";
  email.addEventListener("change", () => onFieldSave(task.id, { collaboratorEmail: email.value.trim() }));

  const detailsInput = node.querySelector(".details");
  detailsInput.value = task.details || task.notes || "";
  detailsInput.addEventListener("change", () => onFieldSave(task.id, { details: detailsInput.value }));

  const reminderType = node.querySelector(".reminderType");
  reminderType.value = task.reminderType || "none";
  reminderType.addEventListener("change", () => onFieldSave(task.id, { reminderType: reminderType.value }));

  node.querySelectorAll(".tag").forEach(chk => {
    chk.checked = (task.tags || []).includes(chk.value);
    chk.addEventListener("change", () => {
      const tags = Array.from(node.querySelectorAll(".tag")).filter(x => x.checked).map(x => x.value);
      onFieldSave(task.id, { tags });
    });
  });

  node.querySelector(".delete").addEventListener("click", async () => {
    await api(`/api/tasks/${task.id}`, { method: "DELETE" });
    tasks = tasks.filter(t => t.id !== task.id);
    render();
  });

  node.querySelector(".sync").addEventListener("click", async () => {
    if (!task.deadline) {
      alert("Cần đặt deadline trước khi đẩy lên Google Calendar.");
      return;
    }
    try {
      const result = await api(`/api/tasks/${task.id}/calendar-sync`, { method: "POST" });
      alert("Đã đồng bộ lịch.\n" + (result.message || ""));
    } catch (err) {
      alert("Đẩy lịch lỗi: " + err.message);
    }
  });

  node.querySelector(".send-mail").addEventListener("click", async () => {
    try {
      await api(`/api/tasks/${task.id}/send-email`, { method: "POST", body: "{}" });
      alert("Đã gửi email cho người phối hợp.");
    } catch (err) {
      alert("Gửi email lỗi: " + err.message);
    }
  });

  node.addEventListener("dragstart", () => { draggingId = task.id; });
  node.addEventListener("dragend", () => { draggingId = null; });
  return node;
}

function setupDropZone(zone, status) {
  zone.addEventListener("dragover", e => {
    e.preventDefault();
    zone.classList.add("dragover");
  });
  zone.addEventListener("dragleave", () => zone.classList.remove("dragover"));
  zone.addEventListener("drop", e => {
    e.preventDefault();
    zone.classList.remove("dragover");
    if (!draggingId) return;
    onFieldSave(draggingId, { status });
  });
}

addBtn.addEventListener("click", async () => {
  if (isAdding) return;
  const title = quickInput.value.trim();
  if (!title) return;
  try {
    isAdding = true;
    addBtn.disabled = true;
    const nowIso = new Date().toISOString();
    const created = await api("/api/tasks", {
      method: "POST",
      body: JSON.stringify({ title, deadline: nowIso, group: "", collaboratorName: "", collaboratorEmail: "" })
    });
    tasks.push(created.task || created);
    quickInput.value = "";
    render();
    quickInput.focus();
  } catch (err) {
    alert("Thêm công việc lỗi: " + err.message);
  } finally {
    isAdding = false;
    addBtn.disabled = false;
  }
});

quickInput.addEventListener("keydown", e => {
  if (e.key === "Enter") {
    e.preventDefault();
    addBtn.click();
  }
});

setupDropZone(todoList, "todo");
setupDropZone(doneList, "done");

addGroupBtn.addEventListener("click", async () => {
  const name = newGroupInput.value.trim();
  if (!name) return;
  if (!(settings.groups || []).includes(name)) settings.groups.push(name);
  await api("/api/settings/groups", { method: "PUT", body: JSON.stringify({ groups: settings.groups }) });
  newGroupInput.value = "";
  renderSettings();
  render();
});

saveCollabBtn.addEventListener("click", async () => {
  const name = collabNameInput.value.trim();
  const email = collabEmailInput.value.trim();
  if (!name || !email) return;
  const updated = await api("/api/collaborators", {
    method: "POST",
    body: JSON.stringify({ name, email })
  });
  settings = updated;
  collabNameInput.value = "";
  collabEmailInput.value = "";
  renderSettings();
});

toggleManageBtn.addEventListener("click", () => {
  const isHidden = managePanel.classList.contains("hidden");
  managePanel.classList.toggle("hidden");
  toggleManageBtn.textContent = isHidden ? "Ẩn quản lý" : "Quản lý";
});

logoutBtn.addEventListener("click", async () => {
  try {
    await api("/api/auth/logout", { method: "POST", body: "{}" });
  } catch {
    // Ignore and continue redirect to login page.
  }
  window.location.href = "/login.html";
});

async function boot() {
  const shell = document.querySelector("main.app");
  shell?.classList.add("auth-pending");
  try {
    await api("/api/auth/me");
    const [taskData, settingsData] = await Promise.all([
      api("/api/tasks"),
      api("/api/settings")
    ]);
    tasks = taskData;
    settings = settingsData;
    renderSettings();
    render();
  } finally {
    shell?.classList.remove("auth-pending");
  }
}

boot().catch(err => alert("Không tải được danh sách công việc: " + err.message));
