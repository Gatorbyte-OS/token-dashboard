# token-dashboard — intent layer

Local-first analytics over the JSONL transcripts Claude Code writes to `~/.claude/projects/`:
per-prompt cost, tool/file heatmaps, subagent attribution, cache-hit economics, project
comparisons, a rule-based tips engine — then a **multi-box merge** so BMF, LMF and the VPS all
show the same union of usage instead of three separate views. Forked from
`nateherkai/token-dashboard` (itself inspired by `phuryn/claude-usage`), now maintained by
GatorByte Studios. Serves Kurt: it is his own token/cost visibility across every box he runs
Claude Code on, nothing multi-tenant.

Read `CLAUDE.md` too — it's the conventions file Claude Code auto-loads (stdlib-only, SQL
binding, file-size limit). This file is the architecture and the traps; that one is the style
guide. Don't duplicate between them.

## What it actually is

```
cli.py  →  token_dashboard/scanner.py  →  SQLite (~/.claude/token-dashboard.db)
                                              ↓
                            token_dashboard/server.py  →  /api/* JSON + SSE  →  web/ (vanilla JS)
```

- **`cli.py`** — argparse entry point: `scan · today · stats · tips · dashboard · export · ingest`.
  No third-party deps anywhere in this repo — stdlib Python 3 only, by design (see CLAUDE.md
  Conventions). Arguing for a dependency is a real conversation to have first, not a PR.
- **`token_dashboard/scanner.py`** — parses each session's JSONL incrementally. Tracks
  `(mtime, bytes_read)` per file in the `files` table so re-scans only read new bytes. **Dedup key
  is `(session_id, message_id)`, not `uuid`** — Claude Code snapshots the same streaming assistant
  message to disk 2-3 times as it grows, each with a new `uuid` but the same `message.id`.
  `_evict_prior_snapshots` deletes the earlier partial rows when a newer one for the same
  `message_id` arrives. Get this key wrong and totals over-count by roughly 2-3x.
- **`token_dashboard/db.py`** — schema (`messages`, `tool_calls`, `files`, `plan`,
  `dismissed_tips`) + every query helper the server calls. `plan` is a generic k/v table used both
  for the pricing-plan setting and the export watermark — don't assume it's plan-only.
- **`token_dashboard/pricing.py`** — reads `pricing.json`, maps model ID → $/token, falls back to
  tier-substring pricing (`opus`/`sonnet`/`haiku`) for unlisted model IDs and marks those
  `estimated: true`.
- **`token_dashboard/tips.py`** — rule-based suggestions computed from the DB (repeated file
  reads, oversized tool results, low cache-hit rate). No ML, no external calls.
- **`token_dashboard/skills.py`** — walks `~/.claude/skills/`, `~/.claude/scheduled-tasks/`,
  `~/.claude/plugins/` for `SKILL.md` files to build a slug→size catalog. **This is why the Skills
  tab's token-per-call column is blank for project-local `.claude/skills/` and subagent-dispatched
  invocations** — those aren't under any of the three scanned roots. Known limitation, not a bug;
  see `docs/KNOWN_LIMITATIONS.md`.
- **`token_dashboard/server.py`** — stdlib `http.server.ThreadingHTTPServer`. Serves `/api/*`
  (JSON), `/api/stream` (SSE — pushes on every scan that found new rows), and static files from
  `web/`. Background thread re-scans every 30s and, if `TOKEN_DASHBOARD_INBOX` is set, also sweeps
  that inbox for other boxes' exports (`ingest.sweep_inbox`) in the same loop.
- **`token_dashboard/export.py`** / **`token_dashboard/ingest.py`** — the multi-box merge. See
  below; this is the part a fresh session is most likely to get wrong.
- **`web/`** — vanilla JS, no build step, no framework. Hash router (`app.js`), ECharts vendored
  in-repo (`web/echarts.min.js` — never pull it from a CDN, see Privacy below), one `routes/*.js`
  file per tab (`overview`, `prompts`, `sessions`, `projects`, `skills`, `tips`, `settings`).

## Multi-box: how usage from three boxes becomes one dashboard

Kurt runs Claude Code on BMF (Windows desktop), LMF (POSIX laptop), and the VPS. Each box only
sees its own `~/.claude/projects/`. The dashboard's real value is the union, so:

1. Every `messages`/`tool_calls` row is stamped with a `box` column (`BMF`/`LMF`/`VPS`/etc, from
   `TOKEN_DASHBOARD_BOX` env or `db.local_box()`'s platform fallback).
2. `launch.ps1` (BMF) and `scripts/export-push.sh` (LMF/POSIX) are fired by the Claude Code
   `SessionEnd` hook on each sending box. They `scan`, then `export --out <spool>/td-<BOX>-<ts>.json.gz`
   — a **delta** since the last export watermark (stored in the `plan` table), replayed with a
   24h overlap window so a lost or duplicate file can never double-count (ingest replays the exact
   same dedupe path as the scanner, so re-ingesting the overlap is a no-op).
3. Export lands in a **local spool dir first**, then `scp`s to the VPS inbox
   (`~/gatorbyte-os/run/token-dashboard-inbox/`, moved there 2026-08-24 — QUEUE `2026-08-23-1830`).
   Files are only deleted from the spool on `scp` success — a dead VPS just means the next
   session's push retries the same files. **Debounced to once per 15 minutes** (a stamp file), so
   don't expect every single session to push.
4. The **VPS** dashboard process sweeps that inbox every 30s (same loop as its own re-scan) via
   `ingest.sweep_inbox`, ingesting and deleting each `*.json.gz`. A file that fails to parse is
   renamed `*.bad` instead of retried forever.
5. **The VPS is the only box meant to show the merged view.** BMF/LMF dashboards (if run locally)
   only ever show that one box's own data — they are senders, not the union.

**If you touch the schema, the export/ingest column lists (`MSG_COLS`/`TOOL_COLS` in export.py,
`INSERT_MSG`/`INSERT_TOOL` in scanner.py) must move together**, or a box on the old schema sends
an export the VPS can't ingest cleanly. `test/test_multibox.py` is the round-trip test — run it
before touching any of scanner/db/export/ingest together.

## Hard constraints

- **Fully local by design, except the deliberate multi-box `scp`.** No telemetry, no third-party
  network calls for user data. `grep -r "https://" token_dashboard/ web/` should find nothing —
  that's a real invariant the README asks people to check, not decoration.
- **`HOST=0.0.0.0` exposes the entire prompt history to the local network.** Default is
  `127.0.0.1`. Never change this default in code; if a task wants LAN exposure, that's the user's
  explicit choice via env var, never a hardcoded default.
- **VPS deploy target:** `token.dashboard.gatorbytestudios.com`, port 8080, behind SSO, systemd
  unit `dashboard-token-dashboard` (`Restart=always`). Shipped via
  `tools/vps-ops/deploy.sh token-dashboard` from the VPS ops tooling (outside this repo) — this
  repo has no deploy script of its own beyond the export-push scripts, which push *data*, not
  *code*. A code change here needs a normal git push + the VPS deploy-pull cron (or manual
  `deploy.sh token-dashboard`) to land — editing the running VPS clone directly is the same
  one-way-deploy violation every other GatorByte repo forbids.
- **Data that lives outside the repo, must survive a redeploy:**
  - `~/.claude/token-dashboard.db` (or `TOKEN_DASHBOARD_DB` override) — the SQLite cache, one per
    box. Never committed, never touched by a deploy.
  - `~/gatorbyte-os/run/token-dashboard-inbox/` on the VPS — the multi-box inbox. A deploy must
    never delete or relocate this without updating every sending box's `INBOX` path in
    `scripts/export-push.*` first (they hardcode it).
  - `~/.claude/projects/` itself — the source data, owned by Claude Code, read-only from this
    repo's perspective. **Never write to it.**
- **SQLite single-writer.** Only run one `dashboard` process against a given DB at a time; two
  fight over the file and produce `database is locked` errors or torn totals.
- **Stdlib only.** No `pip install`, no `requirements.txt`, no Node/npm for the frontend. This is
  a stated project value (CONTRIBUTING.md, CLAUDE.md), not an oversight — don't "fix" it by adding
  a dependency without raising it first.

## Anti-patterns / traps

- **Don't dedupe on `uuid`.** It changes on every streaming snapshot of the same message. The dedupe
  key is `(session_id, message_id)` — see `scanner._evict_prior_snapshots` and
  `db._migrate_add_message_id`. Getting this wrong silently inflates every total by ~2-3x and the
  bug is easy to miss because the numbers still look plausible.
- **Don't assume `box` is always populated.** Pre-multibox DBs get backfilled by
  `db._migrate_add_box` on `init_db`, using the *current* box's name for *all* historical rows —
  correct only because those rows really were all scanned locally before multibox existed. A new
  migration touching `box` needs to account for this backfill semantics, not just add a column.
- **Don't point `TOKEN_DASHBOARD_INBOX` anywhere but the current inbox path.** It moved once
  already (2026-08-24, QUEUE `2026-08-23-1830`) and the old path was left as a symlink specifically
  so boxes that hadn't pulled the change yet didn't silently drop exports. If you move it again,
  leave the same kind of symlink breadcrumb or a sending box on stale code loses its data path
  with no error.
- **Don't run `scan` and `dashboard` (or two `dashboard`s) against the same DB concurrently.**
  Expect lock errors, not a crash — they can look like "data is stale" instead of an obvious
  failure.
- **Don't add a CDN font or CDN script include in `web/`.** ECharts is vendored on purpose
  (`web/echarts.min.js`); the whole privacy pitch depends on nothing calling out from the browser.
- **Don't hand-edit `~/.claude/token-dashboard.db` or the inbox contents.** Both are generated /
  transient; if the numbers look wrong, delete the DB and re-`scan` (README Troubleshooting), don't
  patch rows by hand.
- **Skills tab token counts are known-partial**, not a bug to "fix" reflexively — see
  `docs/KNOWN_LIMITATIONS.md`. Broadening the scan roots is a real backlog item
  (`docs/inspiration.md` / CONTRIBUTING "Ideas that would genuinely help"), just not done yet.
- **Tests:** `python3 -m unittest discover tests` (68 tests, stdlib `unittest`, offline, <5s).
  Run before claiming anything here works — especially anything touching scanner/db/export/ingest,
  which is exactly where the multibox round-trip lives (`tests/test_multibox.py`,
  `tests/test_end_to_end_totals.py`).
