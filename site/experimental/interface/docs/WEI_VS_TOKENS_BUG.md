# FAO Token Units: The "Insufficient Balance" Bug Explained

## The Problem

When users tried to **buy** or **sell (ragequit)** FAO tokens, they saw confusing errors:
- `"Insufficient FAO balance"` (even with 26,000+ tokens!)
- `"Incorrect ETH sent"` (even when sending the exact amount!)

---

## Why It Happened: Whole Tokens vs Wei

### Quick Background

Ethereum tokens use **18 decimal places** for precision. This smallest unit is called **Wei**.

| Human Amount | Wei Amount (what contracts see) |
|-------------|--------------------------------|
| 1 token | 1,000,000,000,000,000,000 (1e18) |
| 0.5 tokens | 500,000,000,000,000,000 |
| 0.001 tokens | 1,000,000,000,000,000 |

**Think of it like dollars and cents:**
- $1.00 = 100 cents
- 1 token = 1,000,000,000,000,000,000 wei

---

### What the FAO Contract Expects

The FAO Sale contract is **different from most contracts**. It expects **whole tokens**, not Wei:

```solidity
function buy(uint256 numTokens) {
    // Contract INTERNALLY multiplies by 1e18
    costWei = numTokens * PRICE_PER_TOKEN;
}

function ragequit(uint256 numTokens) {
    // Contract INTERNALLY multiplies by 1e18  
    burnAmount = numTokens * 1e18;
}
```

So if you want to buy/sell **1 token**, you should call:
- ✅ `buy(1)` or `ragequit(1)` — Correct!
- ❌ `buy(1000000000000000000)` — WRONG! Contract thinks you want 1e18 tokens!

---

### What the Frontend Was Doing Wrong

When user typed "1" in the input, the frontend called `parseEther("1")`:

```javascript
// OLD (BROKEN) CODE
const amount = parseEther("1");  // Returns 1,000,000,000,000,000,000 (1e18)
buy(amount);  // Calls buy(1e18) - contract thinks you want 1e18 tokens!
```

**The Math Gone Wrong:**

| Step | What Happened |
|------|--------------|
| User enters | "1" |
| Frontend converts | 1 → 1e18 (Wei format) |
| Contract receives | `buy(1e18)` |
| Contract calculates | `cost = 1e18 × 0.0001` = **1e14 xDAI** = 100,000,000,000,000 xDAI!! |
| User sends | 0.0001 xDAI |
| Result | ❌ "Incorrect ETH sent" |

For ragequit:

| Step | What Happened |
|------|--------------|
| User enters | "1" |
| Frontend converts | 1 → 1e18 (Wei format) |
| Contract receives | `ragequit(1e18)` |
| Contract calculates | `burnAmount = 1e18 × 1e18` = **1e36 tokens** |
| User has | ~26,000e18 tokens |
| Result | ❌ "Insufficient FAO balance" (26,000e18 < 1e36) |

---

## The Fix

Changed the frontend to send **whole numbers**, not Wei:

```javascript
// NEW (FIXED) CODE
const amount = BigInt(Math.floor(parseFloat("1")));  // Returns 1
buy(amount);  // Calls buy(1) - correct!
```

**The Correct Flow:**

| Step | What Happens Now |
|------|-----------------|
| User enters | "1" |
| Frontend uses | 1 (whole number) |
| Contract receives | `buy(1)` |
| Contract calculates | `cost = 1 × 0.0001` = **0.0001 xDAI** ✅ |
| User sends | 0.0001 xDAI |
| Result | ✅ Success! |

---

## Key Takeaway

> **Not all smart contracts use the same unit conventions!**

- Most ERC-20 contracts expect **Wei** (18 decimals)
- FAO Sale contract expects **whole tokens** and handles decimals internally

Always check the contract source to understand what units it expects!

---

## Files Changed

| File | What Changed |
|------|-------------|
| `useFAOQuoter.js` | Returns whole tokens instead of Wei |
| `SwapPanel.js` | Uses `BigInt(Math.floor(...))` instead of `parseEther()` |

