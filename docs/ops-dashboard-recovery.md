---
canonical: docs/ops-dashboard-recovery.md
scope: Recovery + cleanup map for the OLD ops.futarchy.ai dashboard (not the /fao audit dashboard). Identifies what was there, what still runs, what's outdated, and what to clean.
not-scope: The new audit dashboard at ops.futarchy.ai/fao stays as-is (T6 / Phase-6 score tracker, separately deployed via fao-ops Pages project). FAO domain DNS is documented in docs/futarchy-ai-domains.md.
last-rebuilt: 2026-05-25
---

# ops.futarchy.ai — old dashboard recovery + cleanup map

## TL;DR

The "old" ops dashboard is a **React/Vite app** at `/home/kelvin/futarchy/fleet/apps/dashboard/`. Its last build is **March 24** — 2 months stale. It depended on at least **3 Python daemons + 3 cron jobs** that are no longer running. The current `ops.futarchy.ai` is overlaid by the new Cloudflare Pages deploy (`fao-ops`) at root — so the old React shell isn't reachable from the public hostname anymore.

Restoring the old dashboard means: rebuild dist, start daemons, swap DNS path (or carve a sub-path).

## What the old dashboard WAS

| Layer | Where | What |
|---|---|---|
| **Frontend** | `/home/kelvin/futarchy/fleet/apps/dashboard/` | React 19 + Vite 6 + Tailwind 4. **15 page components.** Builds to `dist/` (2 month stale). |
| **Static serving** | Caddy `:8080` | `handle { root * /home/kelvin/fleet/apps/dashboard/dist; ... }` — Caddy serves the SPA at root of ops.futarchy.ai. |
| **Public ingress** | Cloudflare → cloudflared tunnel → farol → Caddy | `*.futarchy.ai → cfargotunnel → farol:8080` (the original pre-Cloudflare-Pages routing). |
| **Auth** | `scripts/auth_gate.py` on `:3100`, cookie-based | Bcrypt(SHA-256(plaintext)) for password verification; HMAC-SHA256 cookie sig. Users in `data/dashboard-users.json` (admin, adriana). |
| **API backend** | 3 services, mounted via Caddy `handle`s | See below. |
| **Data sources** | `/home/kelvin/futarchy/workspace/data/*` | incidents.db, sessions/, cron-heartbeats/, etc. |
| **Cron jobs** | `infra/host/crontab` (now stopped) | `incident_ingest.py` (2min), `session_delivery_guard.py` (5min), `usage_ingest.py` (5min), `claw-idle-killer.sh` (5min), `session_auto_label.py` (2min). |

### React pages (15 total)

```
TreasuryHistory     /treasury-history   FAO treasury chart
Overview            /                   landing
Epics               /epics              epic list
TaskList            /tasks              task table
TaskDetail          /tasks/:id          single task
Live                /fleet              real-time fleet view
Sessions            /sessions           agent sessions
SessionView         /sessions/:agentId/:sessionId   detailed transcript with tokens/cost
Incidents           /incidents          incident log (severity/category/hours filters)
Models              /models             provider health, allocation, 15-min success rates
Comms               /comms              Telegram: DMs, groups, allowlist, pairings
Usage               /usage              quota / token usage
Personal            /personal           private dashboard
LifeQuadrants       /personal/quadrants Eisenhower matrix view
Settings            /settings           prefs
```

### Caddy `ops.futarchy.ai:8080` route map

```
/memory*              → static (/home/kelvin/fleet/apps/memory-dashboard/dist)
/memory/api/*         → :18811 (memory-dashboard sidecar)
/api/taskcore/*       → :18800 (taskcore — NOT RUNNING)
/api/dashboard/*      → :18801 (dashboard sidecar — running)
/api/*                → :3200 (simple-bond API — running?)
/* (default)          → static (/home/kelvin/fleet/apps/dashboard/dist)
```

## What's RUNNING right now on the workspace

| Process | PID | Status | Purpose |
|---|---|---|---|
| `caddy` | 1665 | ✅ running on :8080 | reverse proxy (rootless) |
| `auth_gate.py` | 1644 | ✅ running on :3100 | cookie login |
| node sidecar | 1664 | ✅ running on :18801 | dashboard sidecar (`/api/dashboard/*`) |
| python on :8000 | 531462 | ⚠ runs but returns 404 — purpose unclear, likely stale | unknown |
| `task_dashboard_server.py` | — | ❌ not running | the taskcore API at :18800 |
| `task_state_export_writer.py` | — | ❌ not running | feeds `exporter-heartbeat.json` |
| `incident_ingest.py` (cron 2min) | — | ❌ not scheduled | feeds `/incidents` page |
| `session_delivery_guard.py` (cron 5min) | — | ❌ not scheduled | session health |
| `usage_ingest.py` (cron 5min) | — | ❌ not scheduled | feeds `/usage` page |
| `session_auto_label.py` (cron 2min) | — | ❌ not scheduled | session metadata |

## What's OUTDATED (the cleanup list)

### Build artifacts

| Item | Where | Age | Action |
|---|---|---|---|
| **Vite build `dist/`** | `/home/kelvin/futarchy/fleet/apps/dashboard/dist/` | **2 months** (Mar 24) | Rebuild: `cd /home/kelvin/futarchy/fleet/apps/dashboard && npm run build` |
| Duplicate source tree | `/home/kelvin/futarchy/workspace/apps/dashboard/` | Older copy (Apr 8) — likely fork/staging | **Delete** OR merge — choose one |
| Old taskcore worktree | `/home/kelvin/archive/taskcore/T2680_worktree/apps/dashboard/` | Archived | Already in archive/ — fine to leave |

### Source code (likely stale, but page-by-page)

| Page | Last edit | Likely needs update? |
|---|---|---|
| `Live.tsx` | Apr 15 (newest) | Probably fine |
| `Usage.tsx` | Apr 15 | Probably fine — but its data source (`usage_ingest.py`) isn't running |
| `LifeQuadrants.tsx` | Apr 15 | Personal/private — review |
| `TreasuryHistory.tsx` | Apr 12 | FAO treasury — may need v5 contract address update |
| `Overview.tsx` | Mar 24 | Review |
| `Epics.tsx`, `Incidents.tsx`, `Models.tsx`, `Comms.tsx`, `Sessions.tsx`, `SessionView.tsx`, `Settings.tsx`, `TaskDetail.tsx`, `TaskList.tsx`, `Personal.tsx` | Mar 23 | Likely stale assumptions about backend APIs |

### Data sources

| File / dir | State | Action |
|---|---|---|
| `data/incidents/` (jsonl per day) | Files up to **today** (2026-05-25.jsonl exists) — but `incidents.db` may be stale | Check `sqlite3 incidents.db 'select max(timestamp) from incidents'` |
| `data/sessions/` | Active (Hermes/Telegram bots write) | Probably OK |
| `data/cron-heartbeats/` | Files mtime-updated by running daemons (3 files modified during today's session: `incident_ingest`, `session_delivery_guard`, `usage_ingest`) — but the daemons themselves may have stopped | Verify with `find data/cron-heartbeats -mmin -10` |
| `data/dashboard-epics.json` | 215 bytes, last touched Apr 8 | Probably stale |
| `data/dashboard-users.json` | 334 bytes, last touched Apr 8 | Still relevant (admin + adriana users) |
| `data/cron-health.json` | Apr — and showed 8 erroring jobs at last update | Re-check after cron restart |
| `data/usage/disabled-profiles.json` | Used by quota_monitor.py | Review for stale entries |

### Network / DNS

| Domain | Old behavior | Current behavior |
|---|---|---|
| `ops.futarchy.ai` | Cloudflare → cfargotunnel → farol → Caddy → React SPA at `/` | Cloudflare Pages (`fao-ops`) serving static portal at `/`, /fao subpath has audit dashboard, /wiki subpath has the wiki |

**The old React dashboard is no longer reachable via ops.futarchy.ai.** The new Pages deploy I set up earlier this session took over the root. The Caddy + tunnel path still works internally but isn't routed externally.

## Recovery options — three paths

### Path A — Restore via Cloudflare tunnel (resurrect the old path)

Keep the new Pages deploy on a sub-path (e.g. `ops.futarchy.ai/fao` and `ops.futarchy.ai/wiki` — they already work), repoint the apex to cfargotunnel → farol → Caddy. This restores the original architecture, but it requires:
1. Tunnel `8e5ae8e1-42db-4dbd-86e7-cefb1f78251f` must be active and exposing `:8080`.
2. Cloudflare DNS for `ops.futarchy.ai` swapped from CNAME → fao-ops.pages.dev back to CNAME → `8e5ae8e1….cfargotunnel.com`.
3. The new portal / fao / wiki content moved into farol so Caddy can serve it at `/fao`, `/wiki`.
4. All the Python daemons need to be running for the React pages to render data.

**Effort:** medium. Risk: 5 days of cleanup work for ~3 pages of "live data" that may be stale anyway.

### Path B — Rebuild the React dashboard as a Pages site (with stale-data caveats)

`npm run build` in `/home/kelvin/futarchy/fleet/apps/dashboard`, deploy `dist/` to a new Pages project, point `dashboard.futarchy.ai` (or `ops.futarchy.ai/legacy`) at it. **The frontend works**, but every API call 404s without the Python backend.

**Useful for:** snapshot view only — TreasuryHistory is data-baked (Python script generates the JSON at build time), so that page would work standalone.

### Path C — Cherry-pick the pages that still matter and rewrite them as static Pages additions

Most of the old dashboard's value is operator-internal (Sessions, Incidents, Comms, Models, Live). Those are NOT public-internet content. They probably should stay on the farol tunnel with auth, NOT on Cloudflare Pages.

The pages that ARE public-friendly and could move to Pages:
- TreasuryHistory (already static-baked)
- Overview (could be static)

**Recommendation:** keep the new public surface (portal + /fao + /wiki) on Cloudflare Pages. Treat the old React dashboard as **operator-internal** and run it via the tunnel only — restore the tunnel + Caddy + daemons under a different subdomain (`fleet.futarchy.ai` or `internal.ops.futarchy.ai`), gated behind auth.

## Cleanup checklist (for your review)

### Delete or archive

- [ ] `/home/kelvin/futarchy/workspace/apps/dashboard/` — duplicate / staging copy of the React app, older than fleet's version. Confirm fleet's is canonical, then archive or delete.
- [ ] `/home/kelvin/archive/taskcore/T2680_worktree/apps/dashboard/` — already in archive, no action needed.
- [ ] Stale `data/dashboard-epics.json` — review if epics are still tracked here.
- [ ] `data/usage/disabled-profiles.json` — re-verify each entry's reason for disablement.

### Restart or remove

- [ ] **`incident_ingest.py` cron** — restart if you want `/incidents` data, OR remove the page if no longer useful.
- [ ] **`session_delivery_guard.py` cron** — same.
- [ ] **`usage_ingest.py` cron** — feeds `/usage`. Restart or remove the page.
- [ ] **`session_auto_label.py` cron** — labels sessions for the dashboard.
- [ ] **`task_dashboard_server.py` (port 18800)** — required by `/tasks`, `/epics`. Restart or remove.
- [ ] **Python on `:8000`** — purpose unclear, returns 404 on healthz. Identify and either restart properly or kill.

### Rebuild

- [ ] **Vite build** the React app (`npm run build` in fleet/apps/dashboard) — current dist is 2 months stale.
- [ ] **Re-source data** the TreasuryHistory page (`npm run build:treasury-history` regenerates the static JSON from blockchain data).

### Decide architecture

- [ ] Public Pages portal (current at ops.futarchy.ai) vs operator-internal React dashboard (was at ops.futarchy.ai, now shadowed) — pick one **canonical** ops surface.
- [ ] Where does FAO live in the new architecture? Currently `ops.futarchy.ai/fao` works; `fao.futarchy.ai` also works. Consolidate.
- [ ] Is `auth_gate.py` still the right gate or should everything move to Cloudflare Access?

### Confirm what's still relevant

- [ ] **TreasuryHistory** — likely useful, FAO-adjacent. Migrate to Pages.
- [ ] **Incidents, Sessions, Models, Comms, Live, Usage** — all openclaw/Farol internal. Decide if they're needed at all.
- [ ] **Personal / LifeQuadrants** — private. Probably move out of ops domain.
- [ ] **Epics, Tasks** — likely managed elsewhere now (Linear? Notion?). Confirm + retire if so.

## How this might be wrong

- I assumed the React dashboard "is" the canonical old ops view. If there's another dashboard (e.g. the Python `/scripts/task_dashboard_server.py` page) that was the user-facing one, this map is off.
- Cron schedules listed are from `infrastructure-manifest.yaml` — they may not match the actual host crontab today.
- "Stopped" daemons may be intentionally stopped because the user retired the feature. Need to confirm each retirement vs accidental stop.
- The tunnel ID `8e5ae8e1-42db-4dbd-86e7-cefb1f78251f` may have been rotated.
- Two `apps/dashboard/` copies — workspace's might actually be the live one for some other reason. Need user confirmation.

## See also

- `docs/futarchy-ai-domains.md` — current DNS / Cloudflare Pages map
- `audit/state/RUNBOOK.md` — FAO operator runbook (this dashboard is broader)
- `/home/kelvin/futarchy/fleet/infra/farol/caddy/Caddyfile.rootless` — Caddy config that routes everything
- `/home/kelvin/futarchy/workspace/data/` — all the live data sources
