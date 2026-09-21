const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { ask } = window.__TAURI__.dialog;

const sectionsEl = document.getElementById("sections");
const searchEl = document.getElementById("search");
const countEl = document.getElementById("count");
const drawerEl = document.getElementById("drawer");
const menuEl = document.getElementById("menu");
const updateAllEl = document.getElementById("update-all");
const tabsEl = document.getElementById("tabs");
const logEl = document.getElementById("log");

let apps = [];
const lastLog = new Map();
// A job in flight, and the last failure per app. Both keep an uninstalled app
// on the grid so its spinner or red badge has somewhere to live.
const inflight = new Set();
const failed = new Map();
// id -> resolve, so a caller can wait for install-done rather than for the
// invoke that merely starts the job.
const pending = new Map();
let updatingAll = false;

// Workspace tabs: each narrows the grid to the apps it is about. Categories
// are list-file names; the ids are App Store apps that belong with the others.
const DEV_IDS = new Set(["mas:497799835", "mas:899247664"]); // Xcode, TestFlight
const WORKSPACES = {
  All: () => true,
  Learning: (a) => a.category === "Learning",
  Creative: (a) => a.category === "Creative" || a.kind === "comfynode",
  Development: (a) =>
    ["Development", "Software Dev", "Devops"].includes(a.category) || DEV_IDS.has(a.id),
};
let tab = "All";

// GUI first, then the App Store, then the CLI grab-bag.
const GROUPS = [
  { kind: "cask", open: true },
  { kind: "github", open: true },
  { kind: "mas", open: true },
  { kind: "comfynode", open: true },
  { kind: "formula", open: false, wrap: "Command line" },
];

// localStorage throws when storage is disabled or full; a collapsed section is
// not worth losing the render over.
const isOpen = (title, fallback) => {
  try {
    const v = localStorage.getItem("open:" + title);
    return v === null ? fallback : v === "1";
  } catch {
    return fallback;
  }
};
const setOpen = (title, open) => {
  try {
    localStorage.setItem("open:" + title, open ? "1" : "0");
  } catch {
    /* not persisted */
  }
};

function monogram(el, name) {
  const initials = name.replace(/[^\p{L}\p{N} ]/gu, " ").trim().split(/\s+/)
    .slice(0, 2).map((w) => w[0]).join("").toUpperCase() || "?";
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.codePointAt(0)) % 360;
  const mono = document.createElement("span");
  mono.className = "mono fallback";
  mono.style.background = `linear-gradient(160deg, hsl(${hash} 58% 56%), hsl(${(hash + 28) % 360} 58% 42%))`;
  mono.textContent = initials;
  el.append(mono);
}

function iconEl(app) {
  const box = document.createElement("div");
  box.className = "icon";

  const host = app.homepage ? new URL(app.homepage).hostname : null;
  const sources = [];
  // An extracted icon is drawn as-is; a favicon is square and gets the shape.
  if (app.icon) sources.push({ src: app.icon, cls: "extracted" });
  if (host) sources.push({ src: `https://www.google.com/s2/favicons?domain=${host}&sz=128`, cls: "fallback" });

  if (!sources.length) {
    monogram(box, app.name);
    return box;
  }

  const img = document.createElement("img");
  let i = 0;
  const show = () => {
    img.className = sources[i].cls;
    img.src = sources[i].src;
  };
  img.onerror = () => {
    if (++i < sources.length) show();
    else { img.remove(); monogram(box, app.name); }
  };
  img.alt = "";
  box.append(img);
  show();
  return box;
}

function tileEl(app) {
  const tile = document.createElement("button");
  tile.className = "tile";
  tile.dataset.id = app.id;
  tile.title = app.name;

  const icon = iconEl(app);
  if (inflight.has(app.id)) tile.classList.add("busy");

  const why = failed.get(app.id);
  if (why) {
    tile.classList.add("failed");
    tile.title = why;
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "!";
    icon.append(badge);
  } else if (app.outdated) {
    // A failure outranks an update: the user has to deal with it first.
    tile.title = "Update available";
    const badge = document.createElement("span");
    badge.className = "badge update";
    icon.append(badge);
  }

  const label = document.createElement("span");
  label.className = "label";
  label.textContent = app.name;

  tile.append(icon, label);
  // A <button> already activates on Enter and Space.
  tile.onclick = () => {
    if (inflight.has(app.id)) return;
    if (!app.installed) return doJob(app, "install");
    if (app.launchable) return call("launch", app);
    // Installed but no bundle on disk: never silently reinstall.
    const where = app.target ? `/Applications/${app.target}` : "its application bundle";
    logLine(`${app.name} is installed but ${where} is missing - Reinstall from the right-click menu`);
  };
  tile.oncontextmenu = (e) => {
    e.preventDefault();
    showMenu(e, app);
  };
  return tile;
}

/// The one tile that stands for everything this section could still install.
function plusTile(missing) {
  const tile = document.createElement("button");
  tile.className = "tile add";
  tile.title = `${missing.length} not installed`;

  const icon = document.createElement("div");
  icon.className = "icon";
  const plus = document.createElement("span");
  plus.className = "plus fallback";
  icon.append(plus);

  const label = document.createElement("span");
  label.className = "label";
  label.textContent = "Add";

  tile.append(icon, label);
  // Without this the window-level click handler closes the popover we open.
  tile.onclick = (e) => {
    e.stopPropagation();
    showAddMenu(tile, missing);
  };
  return tile;
}

function sectionEl(title, list, open) {
  const details = document.createElement("details");
  details.open = open;
  // A search forces sections open; that must not overwrite the saved state.
  details.ontoggle = () => { if (!searchEl.value.trim()) setOpen(title, details.open); };

  const summary = document.createElement("summary");
  summary.append(title);
  const n = document.createElement("span");
  n.className = "n";
  n.textContent = `${list.filter((a) => a.installed).length}/${list.length}`;
  summary.append(n);

  const grid = document.createElement("div");
  grid.className = "grid";
  const busy = (a) => inflight.has(a.id) || failed.has(a.id);
  list.filter((a) => a.installed || busy(a)).forEach((a) => grid.append(tileEl(a)));

  const missing = list.filter((a) => !a.installed && !busy(a));
  if (missing.length) grid.append(plusTile(missing));

  details.append(summary, grid);
  return details;
}

function renderTabs() {
  tabsEl.replaceChildren(...Object.keys(WORKSPACES).map((name) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = name;
    b.classList.toggle("on", name === tab);
    b.onclick = () => {
      tab = name;
      try { localStorage.setItem("tab", name); } catch { /* not persisted */ }
      render();
    };
    return b;
  }));
}

function render() {
  renderTabs();
  const q = searchEl.value.trim().toLowerCase();
  const inTab = WORKSPACES[tab];
  const shown = apps.filter((a) =>
    inTab(a) && (!q || (a.name + " " + a.id + " " + a.category).toLowerCase().includes(q)));
  sectionsEl.replaceChildren();

  for (const group of GROUPS) {
    const mine = shown.filter((a) => a.kind === group.kind);
    if (!mine.length) continue;
    const categories = [...new Set(mine.map((a) => a.category))];
    const built = categories.map((c) =>
      sectionEl(c, mine.filter((a) => a.category === c), isOpen(c, group.open) || !!q));

    if (group.wrap) {
      built.forEach((d) => d.classList.add("nested"));
      const outer = sectionEl(group.wrap, mine, isOpen(group.wrap, group.open) || !!q);
      outer.lastChild.replaceWith(...built);
      sectionsEl.append(outer);
    } else {
      sectionsEl.append(...built);
    }
  }

  if (!sectionsEl.children.length) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = apps.length ? "Nothing matches." : "No packages found.";
    sectionsEl.append(p);
  }
  const updates = apps.filter((a) => a.outdated).length;
  countEl.textContent = `${apps.filter((a) => a.installed).length}/${apps.length}`;

  // Stays put while a run is in progress even as the count drains.
  updateAllEl.hidden = !updates && !updatingAll;
  updateAllEl.lastChild.textContent = updates;
  if (!updatingAll) updateAllEl.title = `Update all (${updates})`;
}

async function load(command) {
  countEl.textContent = "\u2026";
  try {
    apps = await invoke(command);
  } catch (e) {
    apps = [];
    logLine(String(e));
  }
  render();
}

function logLine(line) {
  drawerEl.hidden = false;
  logEl.textContent = (logEl.textContent + line + "\n").split("\n").slice(-200).join("\n");
  logEl.scrollTop = logEl.scrollHeight;
}

async function call(command, app) {
  try {
    await invoke(command, { id: app.id });
  } catch (e) {
    logLine(String(e));
  }
}

/// Resolves true/false when the job finishes, not when it starts.
function doJob(app, action) {
  if (inflight.has(app.id)) return Promise.resolve(false); // one job per app
  failed.delete(app.id);
  inflight.add(app.id);
  render();
  logLine(`$ ${action.replace(/e$/, "")}ing ${app.name}`);

  return new Promise((resolve) => {
    pending.set(app.id, resolve);
    invoke(action, { id: app.id }).catch((e) => {
      // Rejected before the job started, so no install-done is coming.
      pending.delete(app.id);
      inflight.delete(app.id);
      failed.set(app.id, String(e));
      logLine(String(e));
      render();
      resolve(false);
    });
  });
}

async function updateAll() {
  if (updatingAll) return;
  const queue = apps.filter((a) => a.outdated);
  if (!queue.length) return;

  updatingAll = true;
  updateAllEl.disabled = true;
  // Strictly serial: brew holds a lock, and mas is happier one at a time. A
  // failure resolves like any other result, so the rest still run.
  for (const [i, app] of queue.entries()) {
    updateAllEl.title = `Updating ${i + 1}/${queue.length}\u2026`;
    await doJob(app, "update");
  }

  updatingAll = false;
  updateAllEl.disabled = false;
  render();
}

const REVEAL = navigator.userAgent.includes("Windows") ? "Show in Explorer" : "Reveal in Finder";

function menuItems(app) {
  const job = (action) => () => doJob(app, action);
  const items = [];

  if (!app.installed) {
    items.push({ label: "Install", run: job("install") });
  } else {
    // An update waiting is the reason the user opened this menu, so it leads.
    const update = { label: "Update", run: job("update"), strong: app.outdated };
    if (app.outdated) items.push(update);
    if (app.launchable) items.push({ label: "Open", run: () => call("launch", app) });
    if (!app.outdated) items.push(update);
    if (app.kind !== "mas") items.push({ label: "Reinstall", run: job("reinstall") });
    if (app.launchable) items.push({ label: REVEAL, run: () => call("reveal", app) });
  }

  if (app.homepage) items.push({ label: "Homepage", run: () => call("open_homepage", app) });

  if (app.installed) {
    items.push({ sep: true });
    items.push({
      label: "Uninstall",
      danger: true,
      run: async () => {
        // Destructive, so confirm before the package manager is touched.
        const go = await ask(`Uninstall ${app.name}?`, { title: "Ops Launcher", kind: "warning" });
        if (go) doJob(app, "uninstall");
      },
    });
  }
  return items;
}

function showPopover(children, x, y, cls = "") {
  menuEl.className = cls;
  menuEl.replaceChildren(...children);
  menuEl.hidden = false;
  menuEl.style.left = `${Math.max(8, Math.min(x, innerWidth - menuEl.offsetWidth - 8))}px`;
  menuEl.style.top = `${Math.max(8, Math.min(y, innerHeight - menuEl.offsetHeight - 8))}px`;
}

function showMenu(e, app) {
  const nodes = menuItems(app).map((item) => {
    if (item.sep) return document.createElement("hr");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = item.label;
    if (item.danger) button.className = "danger";
    if (item.strong) button.className = "strong";
    if (item.why) {
      button.disabled = true;
      button.title = item.why;
    } else {
      button.onclick = () => { hideMenu(); item.run(); };
    }
    return button;
  });
  showPopover(nodes, e.clientX, e.clientY);
}

function showAddMenu(tile, missing) {
  const rows = missing.map((app) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "row";

    const icon = iconEl(app);
    icon.classList.add("mini");
    const name = document.createElement("span");
    name.textContent = app.name;
    row.append(icon, name);

    if (app.homepage) {
      const host = document.createElement("span");
      host.className = "row-host";
      host.textContent = new URL(app.homepage).hostname.replace(/^www\./, "");
      row.append(host);
    }

    row.onclick = () => { hideMenu(); doJob(app, "install"); };
    return row;
  });

  const at = tile.getBoundingClientRect();
  showPopover(rows, at.left, at.bottom + 6, "list");
}

function hideMenu() {
  menuEl.hidden = true;
}

listen("install-log", ({ payload }) => {
  lastLog.set(payload.id, payload.line);
  logLine(payload.line);
});

listen("install-done", async ({ payload }) => {
  inflight.delete(payload.id);
  const settle = pending.get(payload.id);
  pending.delete(payload.id);

  if (payload.ok) {
    failed.delete(payload.id);
    await load("list_apps");
  } else {
    const last = lastLog.get(payload.id) || `${payload.action} failed`;
    // Declining the admin prompt is a choice, not a failure.
    if (!/cancell?ed/i.test(last)) failed.set(payload.id, last);
    render();
  }
  settle?.(payload.ok);
});

addEventListener("click", hideMenu);
addEventListener("keydown", (e) => e.key === "Escape" && hideMenu());
sectionsEl.addEventListener("scroll", hideMenu);
// Nothing here wants the webview's own context menu.
addEventListener("contextmenu", (e) => e.preventDefault());

try { if (localStorage.getItem("tab") in WORKSPACES) tab = localStorage.getItem("tab"); } catch { /* default */ }
searchEl.oninput = render;
updateAllEl.onclick = updateAll;
document.getElementById("refresh").onclick = () => load("refresh");
document.getElementById("copy").onclick = async (e) => {
  await navigator.clipboard.writeText(logEl.textContent);
  e.target.textContent = "Copied";
  setTimeout(() => (e.target.textContent = "Copy"), 1200);
};
load("list_apps");
