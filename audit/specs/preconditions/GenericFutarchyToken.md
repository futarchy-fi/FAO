---
canonical: src/GenericFutarchyToken.sol
scope: Per-function PRE/POST/FRAME for GenericFutarchyToken — the per-instance ERC20 with MINTER_ROLE-gated mint and ERC20Burnable burn.
not-scope: FAOToken (the bootstrap instance's token, separate file) — uses an identical role model but is a distinct contract.
last-rebuilt: 2026-05-22
---

# Preconditions — `GenericFutarchyToken`

Each `FutarchyRegistry` instance deploys a `GenericFutarchyToken`. Total supply changes only via mint (gated) and burn — `INV-TOKEN-001`.

## Inherited from OpenZeppelin

- `ERC20`: `balanceOf`, `totalSupply`, `transfer`, `transferFrom`, `approve`, `allowance`, the `Transfer` / `Approval` events. Standard ERC20 semantics; specced by ERC-20.
- `ERC20Burnable`: `burn(uint256)` (caller burns from their own balance) and `burnFrom(address, uint256)` (caller burns from an approved address). Both decrement `totalSupply`.
- `AccessControl`: `grantRole`, `revokeRole`, `renounceRole`, `hasRole`, `DEFAULT_ADMIN_ROLE`. Admin can grant `MINTER_ROLE` to additional accounts or renounce both roles to lock the supply.

## State-mutating functions defined here

### `mint(address to, uint256 amount) external onlyRole(MINTER_ROLE)`

| | |
|---|---|
| **PRE** | `hasRole(MINTER_ROLE, msg.sender) == true`. `to != address(0)` (enforced by OpenZeppelin's `_mint`). |
| **POST** | `balanceOf(to) += amount`. `totalSupply += amount`. Emits `Transfer(0x0, to, amount)`. |
| **FRAME** | All other balances. Allowances. Role assignments. |
| **REVERTS** | `AccessControl: account is missing role MINTER_ROLE` if caller lacks role. ERC20 standard reverts (to=0x0 — unreachable in this contract). |
| **EVENTS** | `Transfer(address(0), to, amount)`. |
| **Invariants touched** | INV-TOKEN-001 — totalSupply changes only via mint/burn. |

### Inherited `burn(uint256 amount)` and `burnFrom(address account, uint256 amount)`

(Inherited from `ERC20Burnable`. Listed for completeness.)

| | `burn` | `burnFrom` |
|---|---|---|
| **PRE** | `balanceOf(msg.sender) >= amount` | `balanceOf(account) >= amount ∧ allowance(account, msg.sender) >= amount` |
| **POST** | `balanceOf(msg.sender) -= amount ∧ totalSupply -= amount` | `balanceOf(account) -= amount ∧ allowance(account, msg.sender) -= amount ∧ totalSupply -= amount` |

Both are the **only** paths that decrement `totalSupply`, satisfying `INV-TOKEN-001`. `InstanceSale.ragequit` uses this path via `TOKEN.transferFrom(user, sale, amt)` then `TOKEN.burn(amt)`.

### Inherited `grantRole(role, account)` / `revokeRole(role, account)` / `renounceRole(role, account)`

| | |
|---|---|
| **PRE** | For `grant` / `revoke`: `hasRole(getRoleAdmin(role), msg.sender) == true`. For `renounce`: `msg.sender == account`. |
| **POST** | The role assignment changes. Emits `RoleGranted` / `RoleRevoked`. |
| **REVERTS** | `AccessControl: account is missing role <admin>` for grant/revoke when caller lacks admin role. `AccessControl: can only renounce roles for self` for the renounce mismatch case. |
| **Invariants touched** | Indirect to INV-TOKEN-001 (whoever holds MINTER_ROLE controls the mint path; this is the access boundary). |

## Constructor

| | |
|---|---|
| **Args** | `(string name, string symbol, address admin, uint256 initialSupply)`. |
| **PRE** | `admin != address(0)`. |
| **POST** | ERC20 name/symbol set. `_grantRole(DEFAULT_ADMIN_ROLE, admin)` ∧ `_grantRole(MINTER_ROLE, admin)`. If `initialSupply != 0`: `_mint(admin, initialSupply)`. |
| **REVERTS** | OZ AccessControl reverts on `admin == 0x0`. |

In `FutarchyRegistry` v5, `initialSupply` is **always 0** (the sale mints supply on demand). The constructor's mint branch is dead code in the v5 path but kept for the bootstrap `FAOToken` historical compat.

## Modifier

### `onlyRole(role)` (inherited)

Reverts if `msg.sender` lacks `role`. Used to gate `mint`. The sale holds `MINTER_ROLE` post-Part1, granted by the `TokenAndArbitrationDeployer` then renounced by the deployer itself.

## How this might be wrong

- `INV-TOKEN-001` says totalSupply changes only via mint and burn. That holds *iff* no other contract inherits from this and adds a path. Per v5, no inheritor exists; if `GenericFutarchyToken` is ever subclassed, the invariant must be re-checked.
- The "deployer renounces MINTER_ROLE" step happens in `TokenAndArbitrationDeployer.deployTokenAndSale` — if the deployer code changes to skip the renounce, the deployer keeps mint authority post-deploy, which would surface as a deviation from the SECURITY.md per-instance permissions table.
- `ERC20Burnable`'s `burnFrom` uses `_spendAllowance` (OZ 4.x convention), which can revert if the allowance has been concurrently reduced. The sale's `ragequit` explicitly approves before calling so this is non-issue in the canonical path.
