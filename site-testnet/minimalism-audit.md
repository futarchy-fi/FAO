# Site-Testnet Minimalism Audit

Scope: `site-testnet/tokens.css` and `site-testnet/styles.css`.

## Type Scale

`styles.css` intentionally uses six rendered font-size tokens:

- `var(--fs-xs)`
- `var(--fs-sm)`
- `var(--fs-base)`
- `var(--fs-md)`
- `var(--fs-lg)`
- `var(--fs-xl)`

`tokens.css` remains the source of truth. Larger reserved stops can exist in
the token file for future pages, but this site surface does not consume them.

## Shadow Inventory

Allowed shadow declarations in `styles.css`:

- `box-shadow: none` for live dots and active chips.
- `box-shadow: var(--shadow-card)` for modal and dropdown elevation.

Rationale: page sections, trade panels, tables, and repeated cards rely on
border, spacing, and background tokens rather than stacked elevation levels.

## Gradient Inventory

Allowed gradient declarations in `styles.css`: none.

Rationale: status, progress, wallet, and trade emphasis use semantic flat color
tokens. This keeps the testnet UI scannable and avoids decorative backgrounds
competing with transaction data.

## Literal Color Inventory

`styles.css` should not contain hardcoded hex colors or raw `rgba(...)`
backgrounds. Color intent belongs in `tokens.css`, then surfaces through
semantic variables such as `--accent`, `--warning-bg`, `--surface-wash`,
`--overlay`, and `--shadow-card`.
