# FAO site (static stub)

This `/site` directory hosts the minimal, static UI for fao.eth. It provides:

- Landing content that summarizes the FAO sale and ragequit mechanics.
- Stubbed buy/redeem inputs to be wired to RPC + wallet connectors later.
- A contract address table with legacy Gnosis deployments and placeholders for new ones.
- Quick-reference docs extracted from the project README.

## Running locally

No build step is required. Open `site/index.html` directly in a browser or serve the folder with any static file server (e.g. `python -m http.server 8080`).

## Next steps

- Hook up read-only contract calls for sale status, balances, and pricing.
- Add wallet connection flows for buy and ragequit actions.
- Keep the contract address table updated with new deployments as they ship.
