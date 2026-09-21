// Tray panel: type, arrow, Enter. Launch-only - installs live in the full window.
const { invoke } = window.__TAURI__.core;

const q = document.getElementById("q");
const list = document.getElementById("list");

let apps = [];
let sel = 0;

async function load() {
  apps = (await invoke("list_apps"))
    .filter((a) => a.installed && a.launchable)
    .sort((a, b) => a.name.localeCompare(b.name));
  render();
}

function matches() {
  const needle = q.value.trim().toLowerCase();
  if (!needle) return apps;
  return apps.filter((a) => (a.name + " " + a.category).toLowerCase().includes(needle));
}

function render() {
  const hits = matches();
  sel = Math.max(0, Math.min(sel, hits.length - 1));
  list.textContent = "";
  if (!hits.length) {
    const li = document.createElement("li");
    li.id = "empty";
    li.textContent = "No matches";
    list.append(li);
    return;
  }
  hits.forEach((app, i) => {
    const li = document.createElement("li");
    if (i === sel) li.className = "selected";
    if (app.icon) {
      const img = document.createElement("img");
      img.src = app.icon;
      li.append(img);
    }
    const name = document.createElement("span");
    name.textContent = app.name;
    li.append(name);
    li.onclick = () => go(app);
    list.append(li);
    if (i === sel) li.scrollIntoView({ block: "nearest" });
  });
}

async function go(app) {
  if (!app) return;
  await invoke("launch", { id: app.id });
  invoke("hide_quick");
}

q.oninput = () => {
  sel = 0;
  render();
};

q.onkeydown = (e) => {
  const hits = matches();
  if (e.key === "ArrowDown") {
    sel = Math.min(sel + 1, hits.length - 1);
  } else if (e.key === "ArrowUp") {
    sel = Math.max(sel - 1, 0);
  } else if (e.key === "Enter") {
    go(hits[sel]);
    return;
  } else if (e.key === "Escape") {
    invoke("hide_quick");
    return;
  } else {
    return;
  }
  e.preventDefault();
  render();
};

document.getElementById("open-full").onclick = () => invoke("open_full");

// Reopened from the tray: start from a clean search every time.
window.onfocus = () => {
  q.value = "";
  sel = 0;
  q.focus();
  load();
};

load();
q.focus();
