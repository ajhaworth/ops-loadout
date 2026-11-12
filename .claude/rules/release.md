---
paths:
  - ".github/workflows/**"
  - "Makefile"
  - "app/src-tauri/tauri.conf.json"
  - "app/src-tauri/Cargo.toml"
  - "app/package.json"
---

# Release workflow

Moved out of the root `CLAUDE.md`; loads when you touch the workflow, the
Makefile or the files that carry the version. The versioning rules and the
release procedure (bump, commit format, tag, push) are in
`.claude/bindings/ship.md`.

`.github/workflows/release.yml` builds Loadout for every `v*` tag - the
macOS dmg on a macOS runner and the Windows installer on a Windows runner - and
attaches both to a GitHub Release (`tauri-apps/tauri-action`).
Its `verify` job runs `make verify` first and both builds wait on it (`needs:`),
so a tag whose checks fail publishes nothing; keep that job in step with the
`Makefile`.
It is unsigned, so README tells downloaders to use Open Anyway or clear the
quarantine flag. The app bundles the repo content, so it runs without a
checkout (see "A release ships the repo content" in `app/CLAUDE.md`).
