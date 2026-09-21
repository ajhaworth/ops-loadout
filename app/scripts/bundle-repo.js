#!/usr/bin/env node
// Stages a clean copy of the tracked repo content into src-tauri/bundled/, so a
// downloaded release works with no git checkout on the machine. `git archive`
// means tracked files only - gitignored Blender extensions and `*.local`
// credentials can never ship. Runs before every build via the npm pre-hooks.
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "../..");
const dest = path.join(root, "app/src-tauri/bundled");
const tarball = path.join(os.tmpdir(), `ops-bundled-${process.pid}.tar`);

const run = (cmd, args) => {
  const r = spawnSync(cmd, args, { stdio: ["ignore", "inherit", "inherit"] });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`${cmd} exited ${r.status}`);
};

fs.rmSync(dest, { recursive: true, force: true });
fs.mkdirSync(dest, { recursive: true });
try {
  run("git", ["-C", root, "archive", "-o", tarball, "HEAD", "config", "lib", "platforms"]);
  run("tar", ["-xf", tarball, "-C", dest]);
} finally {
  fs.rmSync(tarball, { force: true });
}
console.log(`bundled ${fs.readdirSync(dest).sort().join(", ")} -> ${dest}`);
