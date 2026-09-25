# DISCOVERY.md — Claude Science status droplet ("Science Status")

Tested against: `claude-science 0.1.53 (release, public)`, daemon running as
`serve --app --port 8765`, 2026-09-24.

Rules followed: read-only. No writes to Claude Science data, no settings changes,
no message/payload bodies copied here. Secrets never copied (token files listed by
name only).

## 1. Process & paths

- Daemon: `~/.claude-science/bin/claude-science serve --app --port 8765 ...`
  (`~/.local/bin/claude-science` is a symlink to it)
- Listens: `127.0.0.1:8765` + `[::1]:8765` (also `8766` + ephemeral lanes)
- Unix socket: `~/.claude-science/daemon.sock`
- Data dir: `~/.claude-science` (default; `--data-dir` overrides)
- Org DB: `~/.claude-science/orgs/<org-uuid>/operon-cli.db` (+ `-wal`/`-shm` siblings)
  - Around 1 GB. Open read-only, never hold open between polls.
- Logs: `~/.claude-science/logs/server-YYYYMMDD.log`, `spawn.log`, `app.log`,
  `health-report-*.log`. `claude-science logs` prints newest server log; `--tail` follows (don't use in scripts).
- Auth material (names only, never read into repo): `.oauth-tokens/*.enc`,
  `.oauth-tokens/*.refresh-journal`, `encryption.key`, `active-org.json`
  (org_uuid, account_uuid, login_owner_data_dir), `config.toml` (sandbox paths only).
- UI: browser page on `http://localhost:8765`; a session's URL is
  `http://localhost:8765/projects/proj_<id>/frames/<uuid>`.

## 2. Documented CLI (daemon health)

`claude-science status` — documented in `--help`, always exits 0, prints JSON:
`running, pid, version, port, started_at` + `daemon` payload including:

- `active_frames`, `active_conversations` (in-memory counts; `active_frames`
  includes every sub-agent, so it is not a session count)
- `require_token: true`, `boot: "serving"`, `data_dir`, `uptime_ms`, `health.*`
  (rss/heap/lag/db_pool), `compute_poller`, `sandbox_active`, `watchdog`

Other CLI: `serve/open/url/status/logs/stop/update/import/sandbox/install/uninstall`,
`mcp-env-check`. No `list-sessions` command. `url` prints single-use login link (~3 min).

## 3. SQLite (sessions and their states)

Open: `sqlite3 'file:<db>?mode=ro'`. Schema only below.

Tables (77): `frames`, `frame_blobs`, `projects`, `frame_messages`, `notifications`,
`events` (empty), `queued_user_messages`, `host_call_log`, `verification_checks`,
`session_concurrency`, `frame_read_cursors`, `compute_pending_terminate`,
`host_grants`, `credential_ask_decisions`, plus agents/artifacts/compute/memory/mcp tables.

Key columns:

- `frames(id, parent_frame_id, root_frame_id, agent_name, status, model, effort,
  input/output_tokens, total_cost, created_at, updated_at, completed_at,
  project_id, name, conversation_type, artifact_id, is_hidden, status_description,
  compute_enabled, delegate_name, last_user_message_at, root_seq, starred_at, ...)`
  - Times are ms epoch ints. Never select `input_data/output_data/task_summary` (research).
  - A session is a root: `parent_frame_id IS NULL`, `root_frame_id = id`.
    Sub-agents are children, almost all `is_hidden = 1` (about 90% of all rows).
- `frame_blobs(frame_id, kind, body)` — `kind` is `input` / `output` / `context`.
  Current builds keep `output_data` NULL and put the output JSON here.
- `projects(id, name, description, context, created_at, updated_at, user_id,
  uploads_frame_id, memory_enabled, archived_at, artifacts_rev, ...)`
  - Only `id, name, archived_at` are safe to read for display. Never `description/context`.
- `notifications(id, sender_frame_id, recipient_frame_id, root_frame_id,
  notification_type, payload, read_at, created_at)` — payload keys vary, never dump
  payload values.

### `frames.status`, from the daemon itself

The daemon defines the enum in its own code (strings in the 0.1.53 binary):

- `processing` — working. (Its Python host API aliases `running` to it.)
- `awaiting_user_response`, `awaiting_plan_approval` — parked on an input or
  approval card; will not progress until the user answers.
- Terminal: `completed`, `success`, `failed`, `cancelled`, `replaced`.
  Older rows also carry `error`.

### What the daemon's dashboard calls a session, and "needs input"

From its `getDashboardData` query:

- Sessions: roots in a project, `is_hidden` not true, `conversation_type != 'uploads'`,
  `agent_name NOT IN ('CONCIERGE','CANVAS_CONCIERGE')`.
- Needs input: status is `awaiting_*`, **or** status is `processing` and either
  the session's output has a non-empty `pending_input_requests` array, or a
  visible (non-hidden) child is `awaiting_*` or is `processing` with pending
  input requests.
- Processing: `processing` and not needs input.
- Last activity: the latest `updated_at` of the root or its children.

The droplet runs the same test. The one look at an output is
`json_array_length(<output>, '$.pending_input_requests')` inside SQLite: a
count, never the body.

## 4. HTTP API (not used)

- Unauthenticated `GET /` and `/api/status` → `401 {"detail":"invalid bearer token"}`.
- `status.require_token: true`; UI behind single-use login URL + encrypted OAuth tokens.
- Would cost the `networkClient` capability and token handling. Not needed now
  that SQLite carries every state.

## 5. Safari tab title (not used)

- Bulk Apple Events read works. Whether a title tracks state: unverified, not needed.

## 6. Notifications source

- The daemon writes `notifications` rows (`cell_result`, `completion`, `compute_done`).
  Not needed for state: `frames.status` carries it.
- There is no public macOS API to read another app's delivered notifications.

## 7. Signal mapping (v1)

- Daemon up, version, port: `claude-science status`.
- Sessions: the dashboard's session filter above, working and waiting sessions
  sorted first, then by last activity; 25 at most.
- running: `processing` without pending input.
- needs_input: the dashboard's needs-input test above.
- finished: `completed`, `success`, `cancelled`, `replaced`.
- error: `failed`, `error`.
- Anything else: `unknown`, shown as "Unknown", never announced.
- Pill count: sessions running or needing input, counted from those rows.
- Session length for the short-session threshold: from the latest turn's start
  (`last_user_message_at`, else `created_at`) to this turn's `completed_at`.
- Activity graph: sessions (same filter) grouped by
  `date(created_at / 1000, 'unixepoch', 'localtime')` over the last 53 weeks.
  One grouped count per day; read at activation, every 10 minutes, and when a
  session starts or finishes.

## 8. Source & adapter

`ScienceSource` protocol → `[SessionStatus]` (id, project name, session title,
state, started/updated times, deep-link localhost URL on the daemon's port).
CLI `status` (no auth, no capability) + read-only SQLite (no auth, no capability).
`FakeScienceSource` fixtures for tests and the harness; the harness uses them
unless `SCIENCE_STATUS_LIVE=1`. Poll 2–5 s running, 30 s idle; open DB read-only
per poll; all timers stop in `deactivate()`. Fail visibly ("can't read Claude
Science status"), never show stale/wrong state. Re-test after every Claude Science
update: this is an undocumented interface, and it ships several times a week.

## 9. Still to confirm live

The states above come from the daemon's own definitions, not from watching a
session. Worth one pass with a real session: start one, trigger an approval card,
let it finish, and check the pill, the card and the shelf at each step.
