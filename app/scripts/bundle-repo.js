#!/usr/bin/env node
// Stages a clean copy of the tracked repo content into src-tauri/bundled/, so a
// downloaded release works with no git checkout on the machine. `git archive`
// plus an overlay of tracked working files means gitignored extensions and `*.local`
// credentials can never ship. Runs before every build via the npm pre-hooks.
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");

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
  // Include edits to already tracked files in local builds; never copy ignored
  // extensions, credentials, or other untracked runtime data.
  const tracked = spawnSync("git", ["-C", root, "ls-tree", "-r", "--name-only", "-z", "HEAD", "config", "lib", "platforms"], { encoding: "utf8" });
  if (tracked.error || tracked.status !== 0) throw tracked.error || new Error("git ls-tree failed");
  const hash = crypto.createHash("sha256");
  for (const name of tracked.stdout.split("\0").filter(Boolean).sort()) {
    const source = path.join(root, name);
    const target = path.join(dest, name);
    fs.rmSync(target, { force: true });
    if (!fs.existsSync(source)) continue;
    fs.cpSync(source, target, { verbatimSymlinks: true });
    const stat = fs.lstatSync(target);
    hash.update(name).update("\0").update(String(stat.mode)).update("\0");
    hash.update(stat.isSymbolicLink() ? fs.readlinkSync(target) : fs.readFileSync(target));
  }
  // Same-version rebuilds must refresh the writable runtime scripts too.
  fs.writeFileSync(path.join(dest, ".bundle-revision"), hash.digest("hex"));
} finally {
  fs.rmSync(tarball, { force: true });
}
console.log(`bundled ${fs.readdirSync(dest).sort().join(", ")} -> ${dest}`);
