# Lighthouse Web Vitals Budgets

Lighthouse CI runs the deployed Cloudflare Pages URLs in mobile mode with three
runs per URL. The report script writes one representative JSON report per URL to
`audit/lighthouse/<url-slug>.json` and aggregates the budget status in
`audit/lighthouse/web-vitals.json`.

The workflow also checks that the deployed Pages assets match the checked-out
static output before accepting a run. If Cloudflare is still serving an older
build, the job remains red while still writing the Lighthouse evidence for the
deployed URL.

| Metric | Threshold | Enforcement | Source |
|---|---:|---|---|
| Largest Contentful Paint | <= 2500 ms | `largest-contentful-paint` error | https://web.dev/lcp/ |
| Interaction to Next Paint | <= 200 ms | `scripts/check-inp.mjs` browser interaction check | https://web.dev/inp/ |
| Cumulative Layout Shift | <= 0.1 | `cumulative-layout-shift` error | https://web.dev/cls/ |
| Total Blocking Time | <= 200 ms | `total-blocking-time` error | Lab proxy for interaction latency |
| First Contentful Paint | <= 1800 ms | `first-contentful-paint` error | Lab proxy for early paint speed |

The LCP, INP, and CLS budgets match Google's published "good" Web Vitals
thresholds. TBT is enforced as a lab proxy for interactivity because Lighthouse
navigation runs cannot synthesize all real-user interactions. The INP check
therefore scripts click and keyboard interactions in Chromium and records Event
Timing entries, then `audit/lighthouse/web-vitals.json` merges that value with
the Lighthouse navigation report. FCP is enforced as an early-paint guardrail so
pages do not meet LCP only by delaying all visible content.

Budgets should not be loosened to pass CI. When a URL fails, fix the page,
deployment, or third-party loading behavior and re-run Lighthouse against the
same deployed URL.
