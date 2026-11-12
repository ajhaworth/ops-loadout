# ops-loadout bindings for dev:ship

Read by the generic `dev:ship` skill in step 0; where a step is given here, do it instead of the generic one.

This repo uses the **main-checkout** flow: no feature branches, worktrees or
merge commits. Work is committed straight to `main`, so there is no merge step
and no worktree to clean up. Shipping is: commit, gate, bump, push, tag, verify.

## 1. Commit

Commit on `main` in the main checkout, only your own paths:
`git commit -m "<what>" -- <paths>` (`git add <exact path>` first for a new
file). Never `git add -A`, `git stash`, or a checkout of files you didn't touch.
Before committing, grep the diff for domains, IPs and emails (the repo is public;
see "Security Considerations" in `CLAUDE.md`).

## 2. Gate

`make verify` on `main` (bash smoke, the Python suites, `smoke.ps1`, `cargo test`
for `app/src-tauri` and `wm`). Red gate: stop, report the first real error, push
nothing. `NO_RUST=1`/`NO_PWSH=1` only when the change cannot reach that side, and
say so in the report; the release workflow runs the full gate regardless.

## 3. Merge

None. Skip it.

## 4. Push: version bump, then main and the tag

**Does it need a release?** Every change that reaches main and touches something
a release ships gets a version bump: `app/`, `config/`, `lib/`, `platforms/` (the
bundle), plus `setup.sh`/`setup.ps1`. That includes package-list edits,
installer scripts, DCC configs, keymaps and `.blend` prefs - a downloaded app
sees none of it until a new version exists. No bump for docs (`README`,
`CLAUDE.md`), `tests/`, or CI-only changes (`.github/`, `Makefile`, `.claude/`).
One bump per push to main, not per commit: bump as the last commit before the
push.

**Which bump:**

- **patch** (0.4.1 -> 0.4.2): fixes and tweaks to existing things - a bug fix, a
  package added to or removed from a list, a changed default, keymap or prefs
  edits, installer script fixes.
- **minor** (0.4.x -> 0.5.0): something new the user can see or do - a new
  installer app, tab, setting, task section, package kind or platform
  capability. While on 0.x, breaking changes also go here (as the Launchbay ->
  Loadout rename did in 0.4.0).
- **major**: reserved. 1.0.0 is cut deliberately when the user declares it
  stable; after that, major means a change that needs manual action on existing
  machines (an identifier rename stranding the install, a profile format
  change, a repo layout the seeded copy can't follow).

**Procedure:**

1. Bump the same version in `app/src-tauri/tauri.conf.json`,
   `app/src-tauri/Cargo.toml` and `app/package.json` (let `cargo` refresh
   `Cargo.lock`).
2. Commit those files as `release: X.Y.Z (<summary>)`
   (e.g. `release: 0.30.5 (drop GameTrack)`).
3. `git push origin main`, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
   The tag push is the release: it runs `.github/workflows/release.yml`.

Once a shipped change is done and verified, push main and the tag without
asking. A docs/tests/CI-only change is pushed to main with no bump and no tag.
Never `--force`. A rejected push of main: `git fetch && git rebase origin/main`
(this repo takes no merge commits), re-run the gate, push again, and only then
create and push the tag.

## 5. Clean up

None (no worktree, no branch).

## 6. Deploy and verify it landed

The tag push starts the deploy; don't start one by hand. Without a tag (no bump
needed), there is no deploy step: say so.

1. `gh run list --workflow release.yml --limit 5`, find the run for `vX.Y.Z`,
   then `gh run watch <id> --exit-status`. The `verify` job runs first; a red
   `verify` means nothing was built or published.
2. `gh release view vX.Y.Z --json tagName,assets -q '.tagName, .assets[].name'`
   must list `Loadout_X.Y.Z_aarch64.dmg`, `Loadout_X.Y.Z_x64-setup.exe`,
   `loadout-wm-macos.zip` and `loadout-wm-windows.zip`.
3. `gh release list` shows only `vX.Y.Z` once the `prune` job has run (it deletes
   every older release and tag).

A red run, or a release missing any of the four assets, is a failed deploy:
report the run URL and the failing job.
