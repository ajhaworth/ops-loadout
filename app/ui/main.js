const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { ask } = window.__TAURI__.dialog;

const sectionsEl = document.getElementById("sections");
const searchEl = document.getElementById("search");
const drawerEl = document.getElementById("drawer");
const menuEl = document.getElementById("menu");
const updateAllEl = document.getElementById("update-all");
const tabsEl = document.getElementById("tabs");
const logEl = document.getElementById("log");
const settingsEl = document.getElementById("settings-dialog");

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

// Two top-level tabs: Apps is the grid, Updates is outdated packages plus the
// setup tasks. Within Apps, a category sub-tab narrows the grid. Categories
// are list-file names; the ids are App Store apps that belong with the others.
const TABS = ["Apps", "Updates"];
const CATEGORIES = {
  All: () => true,
  Learning: (a) => a.category === "Learning",
  Creative: (a) => ["Creative", "3D"].includes(a.category) || a.kind === "comfynode",
  Development: (a) => ["Development", "Software Dev", "Devops"].includes(a.category),
};
let tab = "Apps";
let category = "All";

const IS_WINDOWS = navigator.userAgent.includes("Windows");

// Setup tab: sections of non-package tasks (prereqs, dotfiles, defaults, debloat).
const SETUP = [
  { id: "prereq", name: "Prerequisites", desc: "Tools the rest of this page needs: Xcode CLT, Homebrew, mas, git on macOS; winget, git, PowerShell, Developer Mode on Windows.", open: true },
  { id: "dotfiles", name: "Dotfiles", desc: "Symlinks from this repo's config/dotfiles into your home directory. Existing files are backed up to ~/.dotfiles_backup.", open: true },
  { id: "defaults", name: "System defaults", desc: "Finder, Dock, keyboard, screenshot and app preferences. Each row shows the current value against the wanted one.", open: true },
  { id: "debloat", name: "Windows debloat", desc: "Removes preinstalled apps, disables Xbox services and Game DVR. Opt-in via PROFILE_DEBLOAT.", open: false, win: true },
];
// section id -> { loading } | { error } | { items }
const tasks = new Map();
const sectionRunning = new Map(); // section id -> "Running i/n\u2026" label
let everythingLabel = null; // null when idle, else a "Running i/n\u2026" label

function setupSections() {
  return SETUP.filter((s) => !s.win || IS_WINDOWS);
}

// GUI first, then the App Store, then the CLI grab-bag.
const GROUPS = [
  { kinds: ["cask", "installer"], open: true },
  { kinds: ["github"], open: true },
  { kinds: ["mas"], open: true },
  { kinds: ["comfynode"], open: true },
  { kinds: ["formula"], open: false, wrap: "Command line" },
];

// A cask that installed but produced no .app (fuse-t, pkg-only tools) is a
// CLI thing; file it with the formulae rather than among the apps.
const isCli = (a) => a.kind === "formula" || (a.kind === "cask" && a.installed && !a.launchable);

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
  if (app.license) {
    const license = document.createElement("span");
    license.className = "license";
    license.textContent = app.license;
    tile.append(license);
  }
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

// Segmented control; `key` is the localStorage slot the choice persists in.
function segEl(names, current, key, pick) {
  const nav = document.createElement("nav");
  nav.className = "seg";
  nav.append(...names.map((name) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = name;
    b.classList.toggle("on", name === current);
    b.onclick = () => {
      pick(name);
      try { localStorage.setItem(key, name); } catch { /* not persisted */ }
      render();
    };
    return b;
  }));
  return nav;
}

function renderTabs() {
  tabsEl.replaceChildren(segEl(TABS, tab, "tab", (n) => (tab = n)));
}

// The app grid, grouped by kind then category, for `shown`.
function appSectionEls(shown, q) {
  const out = [];
  for (const group of GROUPS) {
    const mine = shown.filter((a) => group.wrap ? isCli(a) : group.kinds.includes(a.kind) && !isCli(a));
    if (!mine.length) continue;
    const categories = [...new Set(mine.map((a) => a.category))];
    const built = categories.map((c) =>
      sectionEl(c, mine.filter((a) => a.category === c), isOpen(c, group.open) || !!q));

    if (group.wrap) {
      built.forEach((d) => d.classList.add("nested"));
      const outer = sectionEl(group.wrap, mine, isOpen(group.wrap, group.open) || !!q);
      outer.lastChild.replaceWith(...built);
      out.push(outer);
    } else {
      out.push(...built);
    }
  }
  return out;
}

const matchesApp = (a, q) => (a.name + " " + a.id + " " + a.category).toLowerCase().includes(q);

function render() {
  renderTabs();
  const q = searchEl.value.trim().toLowerCase();
  sectionsEl.replaceChildren();

  if (q) {
    // A search spans both tabs: every matching app, then every matching task.
    sectionsEl.append(...appSectionEls(apps.filter((a) => matchesApp(a, q)), q), ...setupEls(q));
  } else if (tab === "Apps") {
    sectionsEl.append(segEl(Object.keys(CATEGORIES), category, "category", (n) => (category = n)));
    sectionsEl.append(...appSectionEls(apps.filter(CATEGORIES[category]), q));
  } else {
    const outdated = apps.filter((a) => a.outdated);
    if (outdated.length) sectionsEl.append(sectionEl("App updates", outdated, true));
    sectionsEl.append(...setupEls(q));
  }

  if (!sectionsEl.querySelector("details, .setup-section")) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = apps.length ? "Nothing matches." : "No packages found.";
    sectionsEl.append(p);
  }
  const updates = apps.filter((a) => a.outdated).length;

  // Stays put while a run is in progress even as the count drains.
  updateAllEl.hidden = !updates && !updatingAll;
  updateAllEl.lastChild.textContent = updates;
  if (!updatingAll) updateAllEl.title = `Update all (${updates})`;
}

function countStates(items) {
  const state = (t) => (failed.has(t.id) ? "failed" : t.state);
  return {
    applied: items.filter((t) => state(t) === "applied").length,
    pending: items.filter((t) => state(t) === "pending").length,
    failed: items.filter((t) => state(t) === "failed").length,
  };
}

// "3 applied", "1 failed", ... for the nonzero states only.
function summaryText(c) {
  return [
    c.applied && `${c.applied} applied`,
    c.pending && `${c.pending} pending`,
    c.failed && `${c.failed} failed`,
  ].filter(Boolean);
}

// Small tinted pills for a state breakdown; only nonzero states render.
function countPills(items) {
  return summaryText(countStates(items)).map((text) => {
    const span = document.createElement("span");
    span.className = `pill pill-${text.split(" ")[1]}`;
    span.textContent = text;
    return span;
  });
}

const GLYPHS = { applied: "\u2713", pending: "\u25cf", failed: "!", needs_admin: "\ud83d\udd12", unknown: "\u25cb" };

function stateGlyph(state) {
  const span = document.createElement("span");
  span.className = `task-glyph state-${state}`;
  span.textContent = GLYPHS[state] || GLYPHS.unknown;
  return span;
}

function taskRowEl(t) {
  const row = document.createElement("div");
  row.className = "task";
  const state = failed.has(t.id) ? "failed" : t.state;
  const busy = inflight.has(t.id);
  if (busy) row.classList.add("busy");

  row.append(stateGlyph(state));

  const main = document.createElement("div");
  main.className = "task-main";
  const title = document.createElement("div");
  title.className = "task-title";
  title.textContent = t.name;
  title.title = t.name;
  main.append(title);

  const detailText = failed.get(t.id) || t.detail;
  if (detailText) {
    const sub = document.createElement("div");
    sub.className = "task-sub";
    sub.textContent = detailText;
    sub.title = detailText;
    main.append(sub);
  }
  row.append(main);

  const right = document.createElement("div");
  right.className = "task-right";
  if (busy) {
    const spin = document.createElement("span");
    spin.className = "task-spinner";
    right.append(spin);
  } else if (state === "applied") {
    const applied = document.createElement("span");
    applied.className = "task-applied";
    applied.textContent = "Applied";
    right.append(applied);
  } else if (state === "needs_admin") {
    const admin = document.createElement("span");
    admin.className = "task-needs-admin";
    admin.textContent = "Needs admin";
    admin.title = "Run the launcher as Administrator to apply this";
    right.append(admin);
  } else {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "task-apply pill-btn primary";
    btn.textContent = "Apply";
    btn.onclick = () => doTask(t);
    right.append(btn);
  }
  row.append(right);

  return row;
}

// One card per group. `name` is null for a section with a single group, in
// which case the card has no header row.
function groupEl(name, items) {
  const card = document.createElement("div");
  card.className = "card";
  if (name) {
    const header = document.createElement("div");
    header.className = "card-header";
    const title = document.createElement("span");
    title.className = "card-title";
    title.textContent = name;
    header.append(title, ...countPills(items));
    card.append(header);
  }
  items.forEach((t) => card.append(taskRowEl(t)));
  return card;
}

function setupSectionEl(sec, q) {
  const bucket = tasks.get(sec.id);
  const wrap = document.createElement("div");
  wrap.className = "setup-section";

  const label = document.createElement("div");
  label.className = "setup-label";
  const labelText = document.createElement("span");
  labelText.textContent = sec.name;
  label.append(labelText);

  const labelRight = document.createElement("div");
  labelRight.className = "setup-label-right";
  if (bucket?.items) {
    labelRight.append(...countPills(bucket.items));
    const runBtn = document.createElement("button");
    runBtn.type = "button";
    runBtn.className = "pill-btn";
    const runLabel = sectionRunning.get(sec.id);
    runBtn.textContent = runLabel || "Run all";
    runBtn.disabled = !!runLabel;
    runBtn.onclick = () => runAll(sec.id);
    labelRight.append(runBtn);
  }
  label.append(labelRight);
  wrap.append(label);

  const desc = document.createElement("p");
  desc.className = "setup-desc";
  desc.textContent = sec.desc;
  wrap.append(desc);

  if (!bucket || bucket.loading) {
    const p = document.createElement("p");
    p.className = "setup-desc";
    p.textContent = "Checking\u2026";
    wrap.append(p);
  } else if (bucket.error) {
    const p = document.createElement("p");
    p.className = "setup-error";
    p.textContent = bucket.error;
    wrap.append(p);
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "pill-btn";
    retry.textContent = "Retry";
    retry.onclick = () => loadSection(sec.id);
    wrap.append(retry);
  } else {
    const items = q
      ? bucket.items.filter((t) => (t.name + " " + t.group + " " + t.detail).toLowerCase().includes(q))
      : bucket.items;
    const groups = [...new Set(items.map((t) => t.group))];
    if (groups.length > 1) {
      groups.forEach((g) => wrap.append(groupEl(g, items.filter((t) => t.group === g))));
    } else {
      wrap.append(groupEl(null, items));
    }
  }

  return wrap;
}

// The Updates tab's task half: summary bar plus one block per section. With a
// query, only sections that match are returned and the bar is left out.
function setupEls(q) {
  const sections = setupSections();
  if (tasks.size === 0) sections.forEach((s) => loadSection(s.id));

  if (q) {
    const hit = (s) => (tasks.get(s.id)?.items || [])
      .some((t) => (t.name + " " + t.group + " " + t.detail).toLowerCase().includes(q));
    return sections.filter(hit).map((sec) => setupSectionEl(sec, q));
  }

  const bar = document.createElement("div");
  bar.className = "setup-bar";

  const all = sections.flatMap((s) => tasks.get(s.id)?.items || []);
  const summary = document.createElement("span");
  summary.className = "setup-summary";
  summary.textContent = summaryText(countStates(all)).join(" \u00b7 ");
  bar.append(summary);

  const runEverythingBtn = document.createElement("button");
  runEverythingBtn.type = "button";
  runEverythingBtn.className = "pill-btn primary";
  runEverythingBtn.textContent = everythingLabel || "Run everything";
  runEverythingBtn.disabled = !!everythingLabel;
  runEverythingBtn.onclick = () => runEverything();
  bar.append(runEverythingBtn);

  return [bar, ...sections.map((sec) => setupSectionEl(sec, q))];
}

async function loadSection(id) {
  tasks.set(id, { loading: true });
  render();
  try {
    const items = await invoke("tasks_status", { section: id });
    tasks.set(id, { items });
  } catch (e) {
    tasks.set(id, { error: String(e) });
  }
  render();
}

function refreshSetup() {
  setupSections().forEach((s) => loadSection(s.id));
}

/// Same shape as doJob, but for a Setup task rather than a package.
function doTask(task) {
  if (inflight.has(task.id)) return Promise.resolve(false);
  failed.delete(task.id);
  inflight.add(task.id);
  render();
  logLine(`$ applying ${task.name}`);

  return new Promise((resolve) => {
    pending.set(task.id, resolve);
    invoke("run_task", { id: task.id, section: task.section }).catch((e) => {
      pending.delete(task.id);
      inflight.delete(task.id);
      failed.set(task.id, String(e));
      logLine(String(e));
      render();
      resolve(false);
    });
  });
}

function runnable(t) {
  return t.state !== "needs_admin" && (t.state === "pending" || t.state === "failed" || failed.has(t.id));
}

async function runAll(sectionId) {
  if (sectionRunning.has(sectionId)) return;
  const queue = (tasks.get(sectionId)?.items || []).filter(runnable);
  if (!queue.length) return;
  for (const [i, t] of queue.entries()) {
    sectionRunning.set(sectionId, `Running ${i + 1}/${queue.length}\u2026`);
    render();
    await doTask(t);
  }
  sectionRunning.delete(sectionId);
  render();
}

async function runEverything() {
  if (everythingLabel) return;
  const queue = setupSections().flatMap((s) => tasks.get(s.id)?.items || []).filter(runnable);
  if (!queue.length) return;
  for (const [i, t] of queue.entries()) {
    everythingLabel = `Running ${i + 1}/${queue.length}\u2026`;
    render();
    await doTask(t);
  }
  everythingLabel = null;
  render();
}

async function load(command) {
  try {
    apps = await invoke(command);
  } catch (e) {
    apps = [];
    logLine(String(e));
  }
  render();
}

const logToggleEl = document.getElementById("log-toggle");
function setDrawer(open) {
  drawerEl.hidden = !open;
  logToggleEl.title = open ? "Hide log" : "Show log";
  logToggleEl.classList.toggle("on", open);
}
logToggleEl.onclick = () => setDrawer(drawerEl.hidden);

function logLine(line) {
  setDrawer(true);
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
    // ponytail: hardcoded; add a page column to installers/*.txt when a second DCC needs one.
    if (app.id === "installer:blender")
      items.push({
        label: "Keymap",
        run: () =>
          invoke("open_page", { path: "dcc/blender/keymap.html" }).catch((e) => logLine(String(e))),
      });
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
        const go = await ask(`Uninstall ${app.name}?`, { title: "Launchbay", kind: "warning" });
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

  // Task ids are namespaced by section (prereq:homebrew, dotfiles:~/.zshrc);
  // run_task always emits action "apply", which no package job ever does.
  if (payload.action === "apply") {
    if (payload.ok) {
      failed.delete(payload.id);
    } else {
      const last = lastLog.get(payload.id) || "apply failed";
      if (!/cancell?ed/i.test(last)) failed.set(payload.id, last);
    }
    await loadSection(payload.id.split(":")[0]);
    settle?.(payload.ok);
    return;
  }

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
// Text fields keep the native menu so a secret can be right-click pasted.
addEventListener("contextmenu", (e) => {
  if (!e.target.matches("input, textarea")) e.preventDefault();
});

try {
  if (TABS.includes(localStorage.getItem("tab"))) tab = localStorage.getItem("tab");
  if (localStorage.getItem("category") in CATEGORIES) category = localStorage.getItem("category");
} catch { /* default */ }
searchEl.oninput = render;
updateAllEl.onclick = updateAll;
async function doRefresh() {
  await load("refresh");
  if (tasks.size) refreshSetup();
}
document.getElementById("refresh").onclick = doRefresh;

// The profile value in effect when the dialog was last opened, so onclose can
// tell whether the user actually changed it.
let profileAtOpen = "";

// Shared by the toolbar button and the first-launch prompt. Accepts an
// already-fetched settings object to avoid a redundant invoke on startup.
async function openSettingsDialog(settings) {
  settings ??= await invoke("get_settings");
  document.getElementById("sidefx-id").value = settings.sidefx_client_id;
  document.getElementById("sidefx-secret").value = settings.sidefx_client_secret;
  const profileEl = document.getElementById("profile");
  profileEl.replaceChildren(new Option("None (everything enabled)", ""));
  settings.profiles.forEach((p) => profileEl.append(new Option(p, p)));
  profileEl.value = settings.profile;
  profileAtOpen = profileEl.value;
  // The plugin owns this one; it is not part of get_settings.
  try {
    document.getElementById("autostart").checked = await invoke("plugin:autostart|is_enabled");
  } catch (e) {
    logLine(String(e));
  }
  // Escape leaves the previous value in place, which would re-save on close.
  settingsEl.returnValue = "";
  settingsEl.showModal();
}

document.getElementById("settings").onclick = () =>
  openSettingsDialog().catch((e) => logLine(String(e)));
document.getElementById("sidefx-open").onclick = () =>
  invoke("open_url", { url: "https://www.sidefx.com/oauth2/applications/" })
    .catch((e) => logLine(String(e)));
// init() awaits this so the first catalog load cannot race the save/refresh.
let settingsClosing = Promise.resolve(false);
settingsEl.onclose = () => { settingsClosing = handleSettingsClose(); };
// Resolves true when it already refreshed the catalog.
async function handleSettingsClose() {
  // A deliberate close (Save or Cancel) counts as having made a choice, so a
  // personal Mac that picks "None" is not prompted again on the next launch.
  try { localStorage.setItem("profileChosen", "1"); } catch { /* not persisted */ }
  if (settingsEl.returnValue !== "save") return false;
  try {
    const profile = document.getElementById("profile").value;
    await invoke("set_settings", {
      sidefxClientId: document.getElementById("sidefx-id").value,
      sidefxClientSecret: document.getElementById("sidefx-secret").value,
      profile,
    });
    // Separate from set_settings, so a failure here still saves the rest.
    try {
      const on = document.getElementById("autostart").checked;
      await invoke(on ? "plugin:autostart|enable" : "plugin:autostart|disable");
    } catch (e) {
      logLine(String(e));
    }
    logLine("Settings saved");
    // A profile change re-filters the catalog; otherwise just re-check tasks.
    if (profile !== profileAtOpen) { await doRefresh(); return true; }
    if (tasks.size) refreshSetup();
  } catch (e) {
    logLine(String(e));
  }
  return false;
}
document.getElementById("copy").onclick = async (e) => {
  await navigator.clipboard.writeText(logEl.textContent);
  e.target.textContent = "Copied";
  setTimeout(() => (e.target.textContent = "Copy"), 1200);
};

// First launch: no saved profile and the picker has never been dismissed
// before, so ask before showing the (unfiltered) catalog.
async function init() {
  try {
    const settings = await invoke("get_settings");
    let chosen = false;
    try { chosen = localStorage.getItem("profileChosen") === "1"; } catch { /* default */ }
    if (!settings.profile && !chosen) {
      await openSettingsDialog(settings);
      await new Promise((resolve) => settingsEl.addEventListener("close", resolve, { once: true }));
      if (await settingsClosing) return; // Save with a profile already refreshed
    }
  } catch (e) {
    logLine(String(e));
  }
  load("list_apps");
}
init();
