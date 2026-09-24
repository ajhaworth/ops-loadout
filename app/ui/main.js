const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const { ask } = window.__TAURI__.dialog;

const sectionsEl = document.getElementById("sections");
const searchEl = document.getElementById("search");
const drawerEl = document.getElementById("drawer");
const menuEl = document.getElementById("menu");
const tabsEl = document.getElementById("tabs");
const logEl = document.getElementById("log");
const settingsEl = document.getElementById("settings-dialog");
const statusTextEl = document.getElementById("status-text");
const statusDotEl = document.getElementById("status-dot");

let apps = [];
let scanning = false;
const lastLog = new Map();
// A job in flight (id -> action), and the last failure per app. Both keep an
// uninstalled app on the grid so its spinner or red badge has somewhere to live.
const inflight = new Map();
const failed = new Map();
// id -> resolve, so a caller can wait for install-done rather than for the
// invoke that merely starts the job.
const pending = new Map();
let updatingAll = false;
let updateAllLabel = null; // "Updating i/n…" while updateAll runs

// "update" -> "Updating", matching the "$ updating X" log line.
const ing = (action) => action[0].toUpperCase() + action.slice(1).replace(/e$/, "") + "ing";

// Inline stroke icons, 16-unit viewBox; style.css sets the stroke.
const ICONS = {
  chev: '<path d="M6.25 4.5 9.75 8l-3.5 3.5"/>',
  plus: '<path d="M8 3.5v9M3.5 8h9"/>',
  up: '<path d="M8 12.5v-9M4.5 7 8 3.5 11.5 7"/>',
  check: '<path d="m4.5 8.25 2.25 2.25 4.75-5"/>',
  lock: '<rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5.25a2.5 2.5 0 0 1 5 0V7"/>',
};
function svgEl(name, size, cls = "") {
  const t = document.createElement("template");
  t.innerHTML = `<svg class="${cls}" width="${size}" height="${size}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;
  return t.content.firstChild;
}

const KIND_LABELS = {
  cask: "Homebrew cask", formula: "Homebrew formula", mas: "App Store",
  installer: "Loadout installer", github: "GitHub release", comfynode: "ComfyUI node",
};

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
  // An extracted icon is drawn as-is; a favicon is square and gets the shape,
  // as does App Store artwork served as jpg (opaque, so full-bleed square).
  if (app.icon) sources.push({ src: app.icon, cls: app.icon.endsWith(".jpg") ? "fallback" : "extracted" });
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
  tile.title = app.license ? `${app.name} · ${app.license}` : app.name;

  const icon = iconEl(app);
  const label = document.createElement("span");
  label.className = "label";
  label.textContent = app.name;
  tile.append(icon, label);

  const caption = (text) => {
    const c = document.createElement("span");
    c.className = "caption";
    c.textContent = text;
    tile.append(c);
  };

  const why = failed.get(app.id);
  if (inflight.has(app.id)) {
    tile.classList.add("busy");
    const spin = document.createElement("span");
    spin.className = "spin";
    icon.append(spin);
    caption(`${ing(inflight.get(app.id))}…`);
  } else if (why) {
    tile.classList.add("failed");
    tile.title = why;
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "!";
    icon.append(badge);
    caption("Failed");
  } else if (app.outdated) {
    // A failure outranks an update: the user has to deal with it first.
    tile.title = "Update available";
    const badge = document.createElement("span");
    badge.className = "badge update";
    badge.append(svgEl("up", 11));
    icon.append(badge);
    caption("Update");
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

// A collapsible card: chevron, title, then whatever `extra` nodes follow it.
function cardEl(key, title, open, extra = []) {
  const details = document.createElement("details");
  details.className = "card";
  details.open = open;
  // A search forces sections open; that must not overwrite the saved state.
  details.ontoggle = () => { if (!searchEl.value.trim()) setOpen(key, details.open); };

  const summary = document.createElement("summary");
  summary.append(svgEl("chev", 12, "chev"), title, ...extra);
  details.append(summary);
  return details;
}

function sectionEl(title, list, open) {
  const n = document.createElement("span");
  n.className = "n";
  n.textContent = `${list.filter((a) => a.installed).length} of ${list.length}`;

  const busy = (a) => inflight.has(a.id) || failed.has(a.id);
  const missing = list.filter((a) => !a.installed && !busy(a));
  const extra = [n];
  if (missing.length) {
    const more = document.createElement("button");
    more.type = "button";
    more.className = "more";
    more.title = `${missing.length} not installed`;
    more.append(svgEl("plus", 12), `${missing.length} more`);
    more.onclick = (e) => {
      // Not a toggle of the <details>, and the window-level click handler
      // must not close the popover we open.
      e.preventDefault();
      e.stopPropagation();
      showAddMenu(more, missing);
    };
    extra.push(more);
  }
  const details = cardEl(title, title, open, extra);

  const grid = document.createElement("div");
  grid.className = "grid";
  list.filter((a) => a.installed || busy(a)).forEach((a) => grid.append(tileEl(a)));
  details.append(grid);
  return details;
}

// Segmented control or chip row; `key` is the localStorage slot the choice persists in.
function segEl(names, current, key, pick, cls = "seg") {
  const nav = document.createElement("nav");
  nav.className = cls;
  nav.append(...names.map((name) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = name;
    b.setAttribute("aria-pressed", name === current);
    b.onclick = () => {
      pick(name);
      try { localStorage.setItem(key, name); } catch { /* not persisted */ }
      render();
    };
    return b;
  }));
  return nav;
}

function renderTabs(updates) {
  const nav = segEl(TABS, tab, "tab", (n) => (tab = n));
  nav.setAttribute("aria-label", "Views");
  if (updates) {
    const badge = document.createElement("span");
    badge.className = "count";
    badge.textContent = updates;
    badge.setAttribute("aria-label", `${updates} updates`);
    nav.lastChild.append(badge);
  }
  tabsEl.replaceChildren(nav);
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
      // Each nested category offers its own "+ more"; the wrapper's would repeat them all.
      outer.querySelector(":scope > summary .more")?.remove();
      out.push(outer);
    } else {
      out.push(...built);
    }
  }
  return out;
}

const matchesApp = (a, q) => (a.name + " " + a.id + " " + a.category).toLowerCase().includes(q);

function render() {
  const outdated = apps.filter((a) => a.outdated);
  renderTabs(outdated.length);
  const q = searchEl.value.trim().toLowerCase();
  sectionsEl.replaceChildren();

  if (q) {
    // A search spans both tabs: every matching app, then every matching task.
    sectionsEl.append(...appSectionEls(apps.filter((a) => matchesApp(a, q)), q), ...setupEls(q));
  } else if (tab === "Apps") {
    // Only categories the profile leaves apps in; a saved one that emptied falls back to All.
    const cats = Object.keys(CATEGORIES).filter((c) => c === "All" || apps.some(CATEGORIES[c]));
    const cat = cats.includes(category) ? category : "All";
    sectionsEl.append(segEl(cats, cat, "category", (n) => (category = n), "chips"));
    sectionsEl.append(...appSectionEls(apps.filter(CATEGORIES[cat]), q));
  } else {
    sectionsEl.append(...updatesEls(outdated), ...setupEls(q));
  }

  if (!sectionsEl.querySelector("details, .hero")) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = apps.length ? "Nothing matches." : "No packages found.";
    sectionsEl.append(p);
  }
  renderStatus();
}

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

function labelRowEl(text, ...right) {
  const row = document.createElement("div");
  row.className = "label-row";
  const h = document.createElement("h2");
  h.textContent = text;
  row.append(h, ...right);
  return row;
}

// The Updates tab's app half: the summary card, then a row per outdated app.
function updatesEls(outdated) {
  const setupN = setupSections().flatMap((s) => tasks.get(s.id)?.items || []).filter(runnable).length;
  const total = outdated.length + setupN;

  const hero = document.createElement("section");
  hero.className = "hero";
  const mark = document.createElement("span");
  mark.className = "hero-mark";
  mark.append(svgEl(total ? "up" : "check", 18));
  const text = document.createElement("div");
  text.className = "hero-text";
  const h = document.createElement("h1");
  h.textContent = total ? `${plural(total, "update")} ready` : "Everything is up to date";
  text.append(h);
  if (total) {
    const sub = document.createElement("div");
    sub.className = "hero-sub";
    sub.textContent = `${plural(outdated.length, "app")} and ${plural(setupN, "setup task")}`;
    text.append(sub);
  }
  hero.append(mark, text);
  // Stays put while a run is in progress even as the count drains.
  if (outdated.length || updatingAll) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pill-btn primary";
    btn.textContent = updateAllLabel || "Update All";
    btn.title = updateAllLabel || `Update all (${outdated.length})`;
    btn.disabled = updatingAll;
    btn.onclick = updateAll;
    hero.append(btn);
  }
  if (!outdated.length) return [hero];

  const count = document.createElement("span");
  count.className = "aside";
  count.textContent = outdated.length;
  const card = document.createElement("section");
  card.className = "card";
  card.append(...outdated.map(appRowEl));
  return [hero, labelRowEl("Apps", count), card];
}

function appRowEl(app) {
  const row = document.createElement("div");
  row.className = "row-item app";
  const icon = iconEl(app);
  icon.classList.add("row-icon");

  const main = document.createElement("div");
  main.className = "row-main";
  const title = document.createElement("div");
  title.className = "row-title";
  title.textContent = app.name;
  const sub = document.createElement("div");
  const why = failed.get(app.id);
  sub.className = why ? "row-sub bad" : "row-sub";
  sub.textContent = why || `${KIND_LABELS[app.kind] || app.kind} · ${app.category}`;
  sub.title = sub.textContent;
  main.append(title, sub);

  const right = document.createElement("div");
  right.className = "row-right";
  if (inflight.has(app.id)) {
    const spin = document.createElement("span");
    spin.className = "row-spinner";
    spin.setAttribute("role", "img");
    spin.setAttribute("aria-label", `${ing(inflight.get(app.id))}…`);
    right.append(spin);
  } else {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pill-btn";
    btn.textContent = "Update";
    btn.onclick = () => doJob(app, "update");
    right.append(btn);
  }
  row.append(icon, main, right);
  row.oncontextmenu = (e) => {
    e.preventDefault();
    showMenu(e, app);
  };
  return row;
}

// Footer: the job in flight, else the update count.
function renderStatus() {
  const updates = apps.filter((a) => a.outdated).length;
  const [id, action] = inflight.entries().next().value || [];
  let text = "";
  let cls = "";
  if (id) {
    const all = [...tasks.values()].flatMap((b) => b.items || []);
    const name = apps.find((a) => a.id === id)?.name || all.find((t) => t.id === id)?.name || id;
    text = `${ing(action)} ${name}` + (inflight.size > 1 ? ` + ${inflight.size - 1} more` : "");
    cls = "busy";
  } else if (scanning) {
    text = "Scanning…";
  } else if (updates) {
    text = `${plural(updates, "update")} available`;
    cls = "updates";
  } else if (apps.length) {
    text = "Up to date";
    cls = "ok";
  }
  statusTextEl.textContent = text;
  statusDotEl.className = `dot ${cls}`;
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

// Tinted pills for what still needs doing, or "All applied" when nothing does.
function statePills(items) {
  const c = countStates(items);
  const pill = (kind, text) => {
    const span = document.createElement("span");
    span.className = `pill pill-${kind}`;
    span.textContent = text;
    return span;
  };
  const out = [];
  if (c.failed) out.push(pill("failed", `${c.failed} failed`));
  if (c.pending) out.push(pill("pending", `${c.pending} pending`));
  if (!out.length && items.length && c.applied === items.length) out.push(pill("applied", "All applied"));
  return out;
}

function stateGlyph(state) {
  const span = document.createElement("span");
  span.className = `task-glyph state-${state}`;
  if (state === "applied") span.append(svgEl("check", 12));
  else if (state === "needs_admin") span.append(svgEl("lock", 11));
  else if (state === "failed") span.textContent = "!";
  // pending draws its dot in CSS; unknown is an empty ring.
  return span;
}

function taskRowEl(t) {
  const row = document.createElement("div");
  row.className = "row-item";
  const state = failed.has(t.id) ? "failed" : t.state;
  const busy = inflight.has(t.id);

  row.append(stateGlyph(state));

  const main = document.createElement("div");
  main.className = "row-main";
  const title = document.createElement("div");
  title.className = "row-title";
  title.textContent = t.name;
  title.title = t.name;
  main.append(title);

  const detailText = failed.get(t.id) || t.detail;
  if (detailText) {
    const sub = document.createElement("div");
    sub.className = failed.has(t.id) ? "row-sub bad" : "row-sub";
    sub.textContent = detailText;
    sub.title = detailText;
    main.append(sub);
  }
  row.append(main);

  const right = document.createElement("div");
  right.className = "row-right";
  if (busy) {
    const spin = document.createElement("span");
    spin.className = "row-spinner";
    spin.setAttribute("role", "img");
    spin.setAttribute("aria-label", "Applying…");
    right.append(spin);
  } else if (state === "applied") {
    const applied = document.createElement("span");
    applied.className = "row-note";
    applied.textContent = "Applied";
    right.append(applied);
  } else if (state === "needs_admin") {
    const admin = document.createElement("span");
    admin.className = "row-note";
    admin.textContent = "Needs admin";
    admin.title = "Run Loadout as Administrator to apply this";
    right.append(admin);
  } else {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pill-btn accent";
    btn.textContent = "Apply";
    btn.onclick = () => doTask(t);
    right.append(btn);
  }
  row.append(right);

  return row;
}

// One collapsible card per section. A section with several groups (Finder,
// Dock, ...) gets a sub-label per group inside it.
function setupSectionEl(sec, q) {
  const bucket = tasks.get(sec.id);
  const extra = [];
  if (bucket?.items) {
    extra.push(...statePills(bucket.items));
    const runLabel = sectionRunning.get(sec.id);
    if (runLabel || bucket.items.some(runnable)) {
      const runBtn = document.createElement("button");
      runBtn.type = "button";
      runBtn.className = "link-btn";
      runBtn.textContent = runLabel || "Run all";
      runBtn.disabled = !!runLabel;
      runBtn.onclick = (e) => {
        e.preventDefault(); // not a toggle of the card
        runAll(sec.id);
      };
      extra.push(runBtn);
    }
  }
  const title = document.createElement("span");
  title.className = "grow";
  title.textContent = sec.name;
  const wrap = cardEl("setup:" + sec.id, title, isOpen("setup:" + sec.id, sec.open) || !!q, extra);

  const desc = document.createElement("p");
  desc.className = "setup-desc";
  desc.textContent = sec.desc;
  wrap.append(desc);

  if (!bucket || bucket.loading) {
    const p = document.createElement("p");
    p.className = "setup-desc";
    p.textContent = "Checking…";
    wrap.append(p);
  } else if (bucket.error) {
    const p = document.createElement("p");
    p.className = "setup-error";
    p.textContent = bucket.error;
    wrap.append(p);
    const retry = document.createElement("button");
    retry.type = "button";
    retry.className = "pill-btn setup-retry";
    retry.textContent = "Retry";
    retry.onclick = () => loadSection(sec.id);
    wrap.append(retry);
  } else {
    const items = q
      ? bucket.items.filter((t) => (t.name + " " + t.group + " " + t.detail).toLowerCase().includes(q))
      : bucket.items;
    const groups = [...new Set(items.map((t) => t.group))];
    for (const g of groups) {
      const mine = items.filter((t) => t.group === g);
      if (groups.length > 1) {
        const label = document.createElement("div");
        label.className = "sub-label";
        label.append(g, ...statePills(mine));
        wrap.append(label);
      }
      wrap.append(...mine.map(taskRowEl));
    }
  }

  return wrap;
}

// The Updates tab's task half: a SETUP label with Run all, then one card per
// section. With a query, only sections that match are returned, unlabelled.
function setupEls(q) {
  const sections = setupSections();
  if (tasks.size === 0) sections.forEach((s) => loadSection(s.id));

  if (q) {
    const hit = (s) => (tasks.get(s.id)?.items || [])
      .some((t) => (t.name + " " + t.group + " " + t.detail).toLowerCase().includes(q));
    return sections.filter(hit).map((sec) => setupSectionEl(sec, q));
  }

  const all = sections.flatMap((s) => tasks.get(s.id)?.items || []);
  const summary = document.createElement("span");
  summary.className = "aside";
  summary.textContent = summaryText(countStates(all)).join(" · ");

  const runEverythingBtn = document.createElement("button");
  runEverythingBtn.type = "button";
  runEverythingBtn.className = "link-btn";
  runEverythingBtn.textContent = everythingLabel || "Run all";
  runEverythingBtn.title = "Apply every pending task in every section";
  runEverythingBtn.disabled = !!everythingLabel;
  runEverythingBtn.onclick = () => runEverything();

  return [labelRowEl("Setup", summary, runEverythingBtn), ...sections.map((sec) => setupSectionEl(sec, q))];
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

// Shared bookkeeping for a package job or a Setup task: inflight guard,
// clearing any earlier failure, and resolving `pending` once the job
// finishes (not once it starts).
function startJob(id, kind, line, call) {
  if (inflight.has(id)) return Promise.resolve(false);
  failed.delete(id);
  inflight.set(id, kind);
  render();
  logLine(line);

  return new Promise((resolve) => {
    pending.set(id, resolve);
    call().catch((e) => {
      // Rejected before the job started, so no install-done is coming.
      pending.delete(id);
      inflight.delete(id);
      failed.set(id, String(e));
      logLine(String(e));
      render();
      resolve(false);
    });
  });
}

/// Same shape as doJob, but for a Setup task rather than a package.
function doTask(task) {
  return startJob(task.id, "apply", `$ applying ${task.name}`, () =>
    invoke("run_task", { id: task.id, section: task.section }));
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
  scanning = true;
  renderStatus();
  try {
    apps = await invoke(command);
  } catch (e) {
    apps = [];
    logLine(String(e));
  }
  scanning = false;
  render();
}

const logToggleEl = document.getElementById("log-toggle");
function setDrawer(open) {
  drawerEl.hidden = !open;
  logToggleEl.title = open ? "Hide log" : "Show log";
  logToggleEl.classList.toggle("on", open);
}
logToggleEl.onclick = () => setDrawer(drawerEl.hidden);
document.getElementById("log-close").onclick = () => setDrawer(false);

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
  return startJob(app.id, action, `$ ${action.replace(/e$/, "")}ing ${app.name}`, () =>
    invoke(action, { id: app.id }));
}

async function updateAll() {
  if (updatingAll) return;
  const queue = apps.filter((a) => a.outdated);
  if (!queue.length) return;

  updatingAll = true;
  // Strictly serial: brew holds a lock, and mas is happier one at a time. A
  // failure resolves like any other result, so the rest still run.
  for (const [i, app] of queue.entries()) {
    updateAllLabel = `Updating ${i + 1}/${queue.length}\u2026`;
    await doJob(app, "update");
  }

  updatingAll = false;
  updateAllLabel = null;
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
    if (app.id === "installer:blender") {
      items.push({
        label: "Keymap",
        run: () =>
          invoke("open_page", { path: "dcc/blender/keymap.html" }).catch((e) => logLine(String(e))),
      });
      // Re-runs setup.py and the extension checks without looking for a new Blender.
      items.push({ label: "Reapply Settings", run: job("configure") });
    }
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
        const go = await ask(`Uninstall ${app.name}?`, { title: "Loadout", kind: "warning" });
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

function showAddMenu(anchor, missing) {
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

  const head = document.createElement("div");
  head.className = "menu-label";
  head.textContent = "Not installed";
  const at = anchor.getBoundingClientRect();
  showPopover([head, ...rows], at.left, at.bottom + 6, "list");
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
// A borderless window has no close button, so the menu's Close Window
// (performClose:) is a no-op; close from here, which the backend turns into hide.
addEventListener("keydown", (e) => {
  if (e.metaKey && e.key === "w") {
    e.preventDefault();
    window.__TAURI__.window.getCurrentWindow().close();
  } else if (e.metaKey && e.key === "," && !settingsEl.open) {
    e.preventDefault();
    document.getElementById("settings").click();
  }
});
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
  const btn = e.currentTarget;
  await navigator.clipboard.writeText(logEl.textContent);
  btn.classList.add("copied");
  btn.title = "Copied";
  setTimeout(() => { btn.classList.remove("copied"); btn.title = "Copy log"; }, 1200);
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
