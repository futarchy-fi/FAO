# Deployment Guide

This project uses GitHub Actions for automated IPFS deployment and ENS updates.

## Overview

```
┌─────────────────────┐     ┌─────────────────────┐
│  Deploy to Pinata   │     │  Update ENS         │
│  (automatic/manual) │────▶│  (manual trigger)   │
│                     │ CID │                     │
└─────────────────────┘     └─────────────────────┘
```

## Workflows

### 1. Deploy to Pinata IPFS
**File:** `.github/workflows/deploy-pinata.yml`

| Trigger | Description |
|---------|-------------|
| Push to `main` | Automatic deployment |
| Manual | Actions → Run workflow |

**What it does:**
1. Builds the Next.js static site (`npm run build`)
2. Uploads `out/` folder to Pinata IPFS
3. Outputs the **IPFS CID** in the job summary

### 2. Update ENS Contenthash
**File:** `.github/workflows/update-ens.yml`

| Trigger | Description |
|---------|-------------|
| Manual only | Actions → Run workflow → Enter CID |

**What it does:**
1. Takes IPFS CID as input
2. Sends `setContenthash` transaction on Gnosis Chain
3. Updates ENS domain to point to new IPFS content

---

## Required Secrets

Add these in **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Description | How to Get |
|--------|-------------|------------|
| `PINATA_API_KEY` | Pinata API Key | [Pinata Dashboard](https://app.pinata.cloud/developers/api-keys) |
| `PINATA_SECRET_KEY` | Pinata Secret Key | Same as above |
| `ENS_UPDATER_PRIVATE_KEY` | Wallet private key (with ETH for gas) | Export from MetaMask |

> ⚠️ **Security:** The ENS updater wallet only needs ~0.001 ETH for gas. Don't store large amounts.

---

## ENS Configuration

The ENS update workflow is pre-configured with:

| Setting | Value |
|---------|-------|
| **Chain** | Ethereum Mainnet |
| **Resolver** | `0xF29100983E058B709F3D539b0c765937B804AC15` |
| **Node** | `0x4c08ce1d7e01a0b96e63e3ad40b7180df55e1cdac821f99c5cca0b0a1e5fdbb0` |
| **Wallet** | `0x645A3D9208523bbFEE980f7269ac72C61Dd3b552` |

To change the ENS domain, update the `ENS_NODE` in `.github/workflows/update-ens.yml`.

---

## Step-by-Step Usage

### First Time Setup

1. **Get Pinata Keys**
   - Go to [Pinata](https://app.pinata.cloud/developers/api-keys)
   - Create new key with `pinFileToIPFS` permission
   - Copy API Key and Secret

2. **Get Wallet Private Key**
   - In MetaMask: Account → Export Private Key
   - Fund with ~0.001 ETH for gas

3. **Add Secrets to GitHub**
   - Go to repo Settings → Secrets → Actions
   - Add all 3 secrets listed above

### Deploying

1. **Push to main** or manually trigger "Deploy to Pinata IPFS"
2. Go to **Actions** tab → click the workflow run
3. Copy the **IPFS CID** from the job summary
4. Go to **Actions** → **Update ENS Contenthash** → **Run workflow**
5. Paste the CID and click **Run**
6. ✅ Done! ENS now points to new deployment

---

## Accessing Your Site

After deployment, your site is available at:

| Method | URL |
|--------|-----|
| **Pinata Gateway** | `https://gateway.pinata.cloud/ipfs/<CID>` |
| **IPFS Gateway** | `https://ipfs.io/ipfs/<CID>` |
| **ENS Domain** | `https://<your-ens>.eth.limo` |

---

## Local Development

```bash
# Install dependencies
npm install

# Run dev server
npm run dev

# Build static site
npm run build

# Test static build locally
npm run serve
```

---

## Troubleshooting

### Build fails
- Check Node.js version (requires 20+)
- Run `npm ci` to clean install dependencies

### Pinata upload fails
- Verify `PINATA_API_KEY` and `PINATA_SECRET_KEY` are set
- Check Pinata dashboard for API key permissions

### ENS update fails
- Ensure wallet has ETH for gas
- Verify private key format (with or without `0x` prefix)
- Check transaction on [Etherscan](https://etherscan.io)
