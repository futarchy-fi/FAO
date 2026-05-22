# FAO Ops Portal

Static Cloudflare Pages deploy for `ops.futarchy.ai`.

## Cloudflare Pages

- Project name: `fao-ops`
- Build command: none
- Build output directory: `site-ops`
- Custom domain: `ops.futarchy.ai`

DNS is a human-operator step. After the Pages project exists, set:

```text
ops.futarchy.ai CNAME -> fao-ops.pages.dev
```

If Cloudflare reports a CNAME conflict or Pages project/domain limit, leave the
existing DNS untouched and resolve that in the Cloudflare dashboard before
retrying the custom domain attachment.

## Data Flow

The canonical dashboard data lives in:

```text
audit/evaluations/topic-{1..6}-evals.jsonl
```

Run:

```sh
bash scripts/sync-ops-dashboard.sh
```

That copies the files into:

```text
site-ops/fao/evaluations/topic-{1..6}-evals.jsonl
```

The ops dashboard is served at `/fao/`, and `site-ops/fao/dashboard.js` fetches
`evaluations/topic-N-evals.jsonl` relative to that page. Keeping the copied data
under `site-ops/fao/evaluations/` makes the deployed browser URL:

```text
https://ops.futarchy.ai/fao/evaluations/topic-N-evals.jsonl
```

The deploy workflow runs the sync script before uploading `site-ops/` so pushes
that update `audit/evaluations/**` publish fresh dashboard data.

## Local Verification

```sh
bash scripts/sync-ops-dashboard.sh
python3 -m http.server 8768 --bind 127.0.0.1 --directory site-ops
```

Then open `http://127.0.0.1:8768/fao/`.
