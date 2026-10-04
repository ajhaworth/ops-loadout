// Tray panel: type, arrow, Enter. Presets, a few actions and app launches -
// installs live in the full window, which the actions hand off to.
const { invoke } = window.__TAURI__.core;
const { emit } = window.__TAURI__.event;

const q = document.getElementById("q");
const list = document.getElementById("list");

const IS_MAC = !navigator.userAgent.includes("Windows");

// Every row is { name, label?, icon?, search?, run }; `label` is the small tag after the name.
let presets = [];
let actions = [];
let apps = [];
let sel = 0;

// Actions the main window runs, so their output lands in its log drawer.
const inMain = (event) => async () => {
  await invoke("open_full");
  await emit("quick-action", event);
};

async function load() {
  const all = await invoke("list_apps");
  const has = (id) => all.some((a) => a.id === id && a.installed);
  presets = (await invoke("list_presets").catch(() => [])).map((p) => ({
    name: p.name,
    label: "Preset",
    run: () => invoke("launch_preset", { name: p.name }),
  }));
  actions = [
    all.some((a) => a.outdated) && { name: "Update all", run: inMain("update-all") },
    (has("installer:blender") || has("winget:BlenderFoundation.Blender")) &&
      { name: "Reapply Blender settings", run: inMain("blender-configure") },
    { name: "Pull repo", run: inMain("pull") },
    ...[["installer:fork", "Fork"], ["installer:ghostty", "Ghostty"]].map(([id, name]) =>
      IS_MAC && has(id) && { name: `Open repo in ${name}`, run: () => invoke("open_repo_in", { id }) }),
  ].filter(Boolean).map((a) => ({ ...a, label: "Action" }));
  apps = all
    .filter((a) => a.installed && a.launchable)
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((a) => ({ name: a.name, icon: a.icon, search: a.category, run: () => invoke("launch", { id: a.id }) }));
  render();
}

// Presets and apps always; actions only once something is typed.
function matches() {
  const needle = q.value.trim().toLowerCase();
  if (!needle) return [...presets, ...apps];
  return [...presets, ...actions, ...apps].filter((i) =>
    (i.name + " " + (i.search || i.label)).toLowerCase().includes(needle));
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
  hits.forEach((item, i) => {
    const li = document.createElement("li");
    if (i === sel) li.className = "selected";
    if (item.icon) {
      const img = document.createElement("img");
      img.src = item.icon;
      li.append(img);
    }
    const name = document.createElement("span");
    name.textContent = item.name;
    li.append(name);
    if (item.label) {
      const tag = document.createElement("small");
      tag.textContent = item.label;
      li.append(tag);
    }
    li.onclick = () => go(item);
    list.append(li);
    if (i === sel) li.scrollIntoView({ block: "nearest" });
  });
}

async function go(item) {
  if (!item) return;
  try {
    await item.run();
  } catch (e) {
    console.error(e);
  }
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
