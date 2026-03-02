/**
 * Test script to verify subgraph data fetching
 * Run: node scripts/test_subgraph_query.js
 */

const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1718248/fao-interface/0.0.1";

const DASHBOARD_QUERY = `
  query GetDashboardData {
    sale(id: "SALE") {
      id
      token
      saleStart
      initialPhaseEnd
      initialPhaseFinalized
      totalAmountRaised
      totalCurveFundsRaised
      totalCurveTokensSold
      totalSaleTokens
      initialTokensSold
      initialFundsRaised
      initialNetSale
      currentPriceWeiPerToken
      initialPriceWeiPerToken
      longTargetTokens
      longTargetReachedAt
      minInitialPhaseSold
    }
    purchaseEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
      id
      buyer
      numTokens
      costWei
      timestamp
      txHash
    }
    ragequitEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
      id
      user
      faoBurned
      ethReturned
      timestamp
      txHash
    }
  }
`;

function formatWei(weiString, decimals = 6) {
    if (!weiString) return '0';
    const wei = BigInt(weiString);
    const eth = Number(wei) / 1e18;
    return eth.toFixed(decimals);
}

function formatTimestamp(unixTimestamp) {
    if (!unixTimestamp) return 'N/A';
    const date = new Date(Number(unixTimestamp) * 1000);
    return date.toISOString();
}

function getRelativeTime(timestamp) {
    const now = Date.now();
    const then = Number(timestamp) * 1000;
    const diff = now - then;

    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);

    if (days > 0) return `${days} days ago`;
    if (hours > 0) return `${hours} hours ago`;
    if (minutes > 0) return `${minutes} minutes ago`;
    return 'just now';
}

async function testQuery() {
    console.log("═".repeat(60));
    console.log("🧪 FAO SUBGRAPH DATA TEST");
    console.log("═".repeat(60));
    console.log(`📍 Endpoint: ${SUBGRAPH_URL}`);
    console.log(`🕐 Test time: ${new Date().toISOString()}\n`);

    try {
        const response = await fetch(SUBGRAPH_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: DASHBOARD_QUERY }),
        });

        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();

        if (result.errors) {
            console.error("❌ GraphQL Errors:", result.errors);
            return;
        }

        const { sale, purchaseEvents, ragequitEvents } = result.data;

        // ═══════════════════════════════════════════════════════════
        // SALE DATA
        // ═══════════════════════════════════════════════════════════
        console.log("📊 SALE ENTITY DATA");
        console.log("─".repeat(60));

        if (sale) {
            console.log(`  Token Address:         ${sale.token}`);
            console.log("");

            console.log("  ⏰ TIMING:");
            console.log(`     Sale Start:         ${formatTimestamp(sale.saleStart)}`);
            console.log(`     Initial Phase End:  ${formatTimestamp(sale.initialPhaseEnd)}`);
            console.log(`     Phase Finalized:    ${sale.initialPhaseFinalized ? 'YES' : 'NO'}`);

            // Calculate countdown
            if (sale.initialPhaseEnd) {
                const endTime = Number(sale.initialPhaseEnd) * 1000;
                const now = Date.now();
                const remaining = endTime - now;

                if (remaining > 0) {
                    const days = Math.floor(remaining / 86400000);
                    const hours = Math.floor((remaining % 86400000) / 3600000);
                    const minutes = Math.floor((remaining % 3600000) / 60000);
                    console.log(`     ⏳ COUNTDOWN:       ${days}D ${hours}H ${minutes}M remaining`);
                } else {
                    console.log(`     ⏳ COUNTDOWN:       PHASE 1 ENDED`);
                }
            }
            console.log("");

            console.log("  💰 FUNDS:");
            console.log(`     Total Raised:       ${formatWei(sale.totalAmountRaised)} xDAI`);
            console.log(`     Initial Raised:     ${formatWei(sale.initialFundsRaised)} xDAI`);
            console.log(`     Curve Raised:       ${formatWei(sale.totalCurveFundsRaised)} xDAI`);
            console.log(`     Initial Net Sale:   ${formatWei(sale.initialNetSale)} xDAI`);
            console.log("");

            console.log("  🪙 TOKENS:");
            console.log(`     Total Sale Tokens:  ${sale.totalSaleTokens}`);
            console.log(`     Initial Sold:       ${sale.initialTokensSold}`);
            console.log(`     Curve Sold:         ${sale.totalCurveTokensSold}`);
            const circulating = BigInt(sale.initialTokensSold || 0) + BigInt(sale.totalCurveTokensSold || 0);
            console.log(`     Circulating:        ${circulating.toString()} FAO`);
            console.log("");

            console.log("  📈 PRICE:");
            console.log(`     Initial Price:      ${formatWei(sale.initialPriceWeiPerToken)} xDAI/token`);
            console.log(`     Current Price:      ${formatWei(sale.currentPriceWeiPerToken)} xDAI/token`);
            console.log("");

            console.log("  🎯 TARGETS:");
            console.log(`     Long Target:        ${sale.longTargetTokens} tokens`);
            console.log(`     Min Initial Sold:   ${sale.minInitialPhaseSold}`);
            console.log(`     Long Target Reached: ${sale.longTargetReachedAt ? formatTimestamp(sale.longTargetReachedAt) : 'NOT YET'}`);
        } else {
            console.log("  ⚠️ No sale data found!");
        }

        // ═══════════════════════════════════════════════════════════
        // PURCHASE EVENTS
        // ═══════════════════════════════════════════════════════════
        console.log("\n" + "═".repeat(60));
        console.log("🛒 PURCHASE EVENTS (Recent " + purchaseEvents.length + ")");
        console.log("─".repeat(60));

        if (purchaseEvents.length === 0) {
            console.log("  No purchase events found.");
        } else {
            purchaseEvents.forEach((e, i) => {
                console.log(`  ${i + 1}. BUY: ${e.numTokens} FAO for ${formatWei(e.costWei)} xDAI`);
                console.log(`     Buyer: ${e.buyer}`);
                console.log(`     Time:  ${getRelativeTime(e.timestamp)} (${formatTimestamp(e.timestamp)})`);
                console.log(`     Tx:    ${e.txHash}`);
                console.log("");
            });
        }

        // ═══════════════════════════════════════════════════════════
        // RAGEQUIT EVENTS
        // ═══════════════════════════════════════════════════════════
        console.log("═".repeat(60));
        console.log("🔥 RAGEQUIT EVENTS (Recent " + ragequitEvents.length + ")");
        console.log("─".repeat(60));

        if (ragequitEvents.length === 0) {
            console.log("  No ragequit events found.");
        } else {
            ragequitEvents.forEach((e, i) => {
                console.log(`  ${i + 1}. RAGEQUIT: Burned ${e.faoBurned} FAO, returned ${formatWei(e.ethReturned)} xDAI`);
                console.log(`     User: ${e.user}`);
                console.log(`     Time: ${getRelativeTime(e.timestamp)} (${formatTimestamp(e.timestamp)})`);
                console.log(`     Tx:   ${e.txHash}`);
                console.log("");
            });
        }

        // ═══════════════════════════════════════════════════════════
        // SUMMARY
        // ═══════════════════════════════════════════════════════════
        console.log("═".repeat(60));
        console.log("✅ TEST COMPLETE");
        console.log("═".repeat(60));
        console.log("\n📋 DATA AVAILABLE FOR DASHBOARD:");
        console.log("  ✓ Phase 1 countdown (initialPhaseEnd)");
        console.log("  ✓ Total Value Locked (totalAmountRaised)");
        console.log("  ✓ Circulating supply (initialTokensSold + totalCurveTokensSold)");
        console.log("  ✓ Current price");
        console.log("  ✓ Transaction history (purchases + ragequits)");
        console.log("  ✓ All timestamps for relative time display");

    } catch (error) {
        console.error("❌ Error:", error.message);
    }
}

testQuery();
