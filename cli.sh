#!/bin/bash

# FAO Sale Interactive CLI
# Requires: cast (from foundry), jq

set -e

# Contract addresses on Gnosis Chain
FAO_TOKEN="0xb222e2a6E065c2559a74168eeAbA298af91b84B9"
FAO_SALE="0x460915528ce37EC66A26b98b791Db512BC62DC17"
RPC_URL="https://rpc.gnosischain.com"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    FAO Sale CLI                                ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${YELLOW}─── $1 ───${NC}\n"
}

# Strip cast output format (e.g., "100000000000000 [1e14]" -> "100000000000000")
strip_cast() {
    echo "$1" | awk '{print $1}'
}

wei_to_eth() {
    local val=$(strip_cast "$1")
    echo "scale=18; $val / 1000000000000000000" | bc
}

tokens_to_readable() {
    local val=$(strip_cast "$1")
    echo "scale=2; $val / 1000000000000000000" | bc
}

# View functions
get_sale_info() {
    print_section "Sale Information"

    # Get basic info
    local sale_start=$(cast call $FAO_SALE "saleStart()(uint256)" --rpc-url $RPC_URL)
    local initial_phase_end=$(cast call $FAO_SALE "initialPhaseEnd()(uint256)" --rpc-url $RPC_URL)
    local initial_phase_finalized=$(cast call $FAO_SALE "initialPhaseFinalized()(bool)" --rpc-url $RPC_URL)
    local current_price=$(cast call $FAO_SALE "currentPriceWeiPerToken()(uint256)" --rpc-url $RPC_URL)
    local min_initial_sold=$(cast call $FAO_SALE "minInitialPhaseSold()(uint256)" --rpc-url $RPC_URL)

    # Token sales
    local initial_tokens_sold=$(cast call $FAO_SALE "initialTokensSold()(uint256)" --rpc-url $RPC_URL)
    local total_curve_tokens=$(cast call $FAO_SALE "totalCurveTokensSold()(uint256)" --rpc-url $RPC_URL)
    local total_sale_tokens=$(cast call $FAO_SALE "totalSaleTokens()(uint256)" --rpc-url $RPC_URL)

    # Funds
    local initial_funds=$(cast call $FAO_SALE "initialFundsRaised()(uint256)" --rpc-url $RPC_URL)
    local curve_funds=$(cast call $FAO_SALE "totalCurveFundsRaised()(uint256)" --rpc-url $RPC_URL)
    local total_raised=$(cast call $FAO_SALE "totalAmountRaised()(uint256)" --rpc-url $RPC_URL)

    # Long target
    local long_target_reached=$(cast call $FAO_SALE "longTargetReachedAt()(uint256)" --rpc-url $RPC_URL)

    # Format timestamps
    local now=$(date +%s)

    echo -e "${GREEN}Sale Start:${NC} $(date -r $sale_start 2>/dev/null || date -d @$sale_start 2>/dev/null || echo $sale_start)"
    echo -e "${GREEN}Initial Phase End:${NC} $(date -r $initial_phase_end 2>/dev/null || date -d @$initial_phase_end 2>/dev/null || echo $initial_phase_end)"
    echo -e "${GREEN}Initial Phase Finalized:${NC} $initial_phase_finalized"
    echo -e "${GREEN}Min Initial Phase Sold:${NC} $min_initial_sold FAO"
    echo ""
    echo -e "${GREEN}Current Price:${NC} $(wei_to_eth $current_price) xDAI per FAO"
    echo ""
    echo -e "${BLUE}── Tokens Sold ──${NC}"
    echo -e "  Initial Phase: $initial_tokens_sold FAO"
    echo -e "  Bonding Curve: $total_curve_tokens FAO"
    echo -e "  Total Sold: $total_sale_tokens FAO"
    echo ""
    echo -e "${BLUE}── Funds Raised ──${NC}"
    echo -e "  Initial Phase: $(wei_to_eth $initial_funds) xDAI"
    echo -e "  Bonding Curve: $(wei_to_eth $curve_funds) xDAI"
    echo -e "  Total Raised: $(wei_to_eth $total_raised) xDAI"
    echo ""
    if [ "$long_target_reached" != "0" ]; then
        echo -e "${GREEN}Long Target (200M) Reached:${NC} $(date -r $long_target_reached 2>/dev/null || date -d @$long_target_reached 2>/dev/null || echo $long_target_reached)"
    else
        echo -e "${YELLOW}Long Target (200M):${NC} Not yet reached"
    fi
}

get_token_info() {
    print_section "FAO Token Information"

    local total_supply=$(cast call $FAO_TOKEN "totalSupply()(uint256)" --rpc-url $RPC_URL)
    local name=$(cast call $FAO_TOKEN "name()(string)" --rpc-url $RPC_URL)
    local symbol=$(cast call $FAO_TOKEN "symbol()(string)" --rpc-url $RPC_URL)

    echo -e "${GREEN}Name:${NC} $name"
    echo -e "${GREEN}Symbol:${NC} $symbol"
    echo -e "${GREEN}Total Supply:${NC} $(tokens_to_readable $total_supply) FAO"
}

get_contract_balances() {
    print_section "Contract Balances"

    local eth_balance=$(cast balance $FAO_SALE --rpc-url $RPC_URL)
    local fao_balance=$(cast call $FAO_TOKEN "balanceOf(address)(uint256)" $FAO_SALE --rpc-url $RPC_URL)

    echo -e "${GREEN}Sale Contract xDAI:${NC} $(wei_to_eth $eth_balance) xDAI"
    echo -e "${GREEN}Sale Contract FAO (Treasury):${NC} $(tokens_to_readable $fao_balance) FAO"
}

get_user_balance() {
    print_section "Check User Balance"

    read -p "Enter address: " user_address

    if [ -z "$user_address" ]; then
        echo -e "${RED}No address provided${NC}"
        return
    fi

    local eth_balance=$(cast balance $user_address --rpc-url $RPC_URL)
    local fao_balance=$(cast call $FAO_TOKEN "balanceOf(address)(uint256)" $user_address --rpc-url $RPC_URL)
    local allowance=$(cast call $FAO_TOKEN "allowance(address,address)(uint256)" $user_address $FAO_SALE --rpc-url $RPC_URL)

    echo -e "\n${GREEN}Address:${NC} $user_address"
    echo -e "${GREEN}xDAI Balance:${NC} $(wei_to_eth $eth_balance) xDAI"
    echo -e "${GREEN}FAO Balance:${NC} $(tokens_to_readable $fao_balance) FAO"
    echo -e "${GREEN}FAO Allowance for Sale:${NC} $(tokens_to_readable $allowance) FAO"
}

calculate_buy_cost() {
    print_section "Calculate Buy Cost"

    read -p "Number of FAO tokens to buy (whole tokens only): " num_tokens

    if [ -z "$num_tokens" ]; then
        echo -e "${RED}No amount provided${NC}"
        return
    fi

    if ! [[ "$num_tokens" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a whole number (no decimals).${NC}"
        return
    fi

    local current_price=$(strip_cast "$(cast call $FAO_SALE "currentPriceWeiPerToken()(uint256)" --rpc-url $RPC_URL)")
    local cost_wei=$((num_tokens * current_price))

    echo -e "\n${GREEN}Tokens:${NC} $num_tokens FAO"
    echo -e "${GREEN}Price per Token:${NC} $(wei_to_eth $current_price) xDAI"
    echo -e "${GREEN}Total Cost:${NC} $(wei_to_eth $cost_wei) xDAI"
    echo -e "${YELLOW}Cost in Wei:${NC} $cost_wei"
}

# Write functions (require private key)
buy_tokens() {
    print_section "Buy FAO Tokens"

    read -p "Number of FAO tokens to buy (whole tokens only): " num_tokens

    if [ -z "$num_tokens" ]; then
        echo -e "${RED}No amount provided${NC}"
        return
    fi

    if ! [[ "$num_tokens" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a whole number (no decimals).${NC}"
        return
    fi

    local current_price=$(strip_cast "$(cast call $FAO_SALE "currentPriceWeiPerToken()(uint256)" --rpc-url $RPC_URL)")
    local cost_wei=$((num_tokens * current_price))

    echo -e "\n${YELLOW}You will buy $num_tokens FAO for $(wei_to_eth $cost_wei) xDAI${NC}"
    read -p "Confirm? (y/n): " confirm

    if [ "$confirm" != "y" ]; then
        echo -e "${RED}Cancelled${NC}"
        return
    fi

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter private key (or set PRIVATE_KEY env): " PRIVATE_KEY
        echo ""
    fi

    echo -e "\n${BLUE}Sending transaction...${NC}"
    cast send $FAO_SALE "buy(uint256)" $num_tokens \
        --value $cost_wei \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "\n${GREEN}Purchase complete!${NC}"
}

approve_ragequit() {
    print_section "Approve FAO for Ragequit"

    read -p "Amount of FAO to approve (or 'max' for unlimited): " amount

    if [ "$amount" == "max" ]; then
        amount="115792089237316195423570985008687907853269984665640564039457584007913129639935"
    else
        amount=$((amount * 1000000000000000000))
    fi

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter private key (or set PRIVATE_KEY env): " PRIVATE_KEY
        echo ""
    fi

    echo -e "\n${BLUE}Sending approval...${NC}"
    cast send $FAO_TOKEN "approve(address,uint256)" $FAO_SALE $amount \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "\n${GREEN}Approval complete!${NC}"
}

ragequit() {
    print_section "Ragequit (Burn FAO for xDAI)"

    read -p "Number of FAO tokens to burn (whole tokens only): " num_tokens

    if [ -z "$num_tokens" ]; then
        echo -e "${RED}No amount provided${NC}"
        return
    fi

    if ! [[ "$num_tokens" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid amount. Please enter a whole number (no decimals).${NC}"
        return
    fi

    # Calculate approximate return
    local eth_balance=$(strip_cast "$(cast balance $FAO_SALE --rpc-url $RPC_URL)")
    local total_supply=$(strip_cast "$(cast call $FAO_TOKEN "totalSupply()(uint256)" --rpc-url $RPC_URL)")
    local burn_amount=$((num_tokens * 1000000000000000000))

    echo -e "\n${YELLOW}You will burn $num_tokens FAO${NC}"
    echo -e "${YELLOW}Contract has $(wei_to_eth $eth_balance) xDAI${NC}"
    read -p "Confirm ragequit? (y/n): " confirm

    if [ "$confirm" != "y" ]; then
        echo -e "${RED}Cancelled${NC}"
        return
    fi

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter private key (or set PRIVATE_KEY env): " PRIVATE_KEY
        echo ""
    fi

    echo -e "\n${BLUE}Sending ragequit transaction...${NC}"
    cast send $FAO_SALE "ragequit(uint256)" $num_tokens \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "\n${GREEN}Ragequit complete!${NC}"
}

# Admin functions
admin_menu() {
    print_section "Admin Functions"

    echo "1) Set Incentive Contract"
    echo "2) Set Insider Vesting Contract"
    echo "3) Add Ragequit Token"
    echo "4) Remove Ragequit Token"
    echo "5) Withdraw ETH"
    echo "6) Rescue ERC20"
    echo "0) Back"
    echo ""
    read -p "Select: " admin_choice

    case $admin_choice in
        1) set_incentive_contract ;;
        2) set_insider_contract ;;
        3) add_ragequit_token ;;
        4) remove_ragequit_token ;;
        5) admin_withdraw_eth ;;
        6) admin_rescue_token ;;
        0) return ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

set_incentive_contract() {
    read -p "Enter incentive contract address: " addr

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "setIncentiveContract(address)" $addr \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}Incentive contract set!${NC}"
}

set_insider_contract() {
    read -p "Enter insider vesting contract address: " addr

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "setInsiderVestingContract(address)" $addr \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}Insider vesting contract set!${NC}"
}

add_ragequit_token() {
    read -p "Enter ERC20 token address to add: " addr

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "addRagequitToken(address)" $addr \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}Ragequit token added!${NC}"
}

remove_ragequit_token() {
    read -p "Enter ERC20 token address to remove: " addr

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "removeRagequitToken(address)" $addr \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}Ragequit token removed!${NC}"
}

admin_withdraw_eth() {
    read -p "Amount in xDAI to withdraw: " amount
    read -p "Recipient address: " recipient

    local amount_wei=$(echo "$amount * 1000000000000000000" | bc | cut -d. -f1)

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "adminWithdrawEth(uint256,address)" $amount_wei $recipient \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}ETH withdrawn!${NC}"
}

admin_rescue_token() {
    read -p "ERC20 token address: " token
    read -p "Amount (in token units): " amount
    read -p "Recipient address: " recipient

    if [ -z "$PRIVATE_KEY" ]; then
        read -sp "Enter admin private key: " PRIVATE_KEY
        echo ""
    fi

    cast send $FAO_SALE "adminRescueToken(address,uint256,address)" $token $amount $recipient \
        --private-key $PRIVATE_KEY \
        --rpc-url $RPC_URL

    echo -e "${GREEN}Token rescued!${NC}"
}

# Main menu
main_menu() {
    while true; do
        print_header
        echo -e "${BLUE}Contract Addresses:${NC}"
        echo -e "  FAO Token: $FAO_TOKEN"
        echo -e "  FAO Sale:  $FAO_SALE"
        echo ""
        echo -e "${YELLOW}═══ View Functions ═══${NC}"
        echo "1) Sale Info"
        echo "2) Token Info"
        echo "3) Contract Balances"
        echo "4) Check User Balance"
        echo "5) Calculate Buy Cost"
        echo ""
        echo -e "${YELLOW}═══ Write Functions ═══${NC}"
        echo "6) Buy Tokens"
        echo "7) Approve FAO for Ragequit"
        echo "8) Ragequit"
        echo ""
        echo -e "${YELLOW}═══ Admin ═══${NC}"
        echo "9) Admin Menu"
        echo ""
        echo "0) Exit"
        echo ""
        read -p "Select option: " choice

        case $choice in
            1) get_sale_info ;;
            2) get_token_info ;;
            3) get_contract_balances ;;
            4) get_user_balance ;;
            5) calculate_buy_cost ;;
            6) buy_tokens ;;
            7) approve_ragequit ;;
            8) ragequit ;;
            9) admin_menu ;;
            0) echo -e "\n${GREEN}Goodbye!${NC}\n"; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run
main_menu
