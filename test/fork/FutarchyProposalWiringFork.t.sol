// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IFutarchyProposalLike {
    function collateralToken1() external view returns (address);
    function collateralToken2() external view returns (address);
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

contract FutarchyProposalWiringForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant DEFAULT_TEST_FAO = 0x9494C281a02c9ae5f72b224B514793ad2DD8cA17;
    address internal constant DEFAULT_TEST_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;

    function testFork_proposal_uses_expected_fao_yes_no_tokens() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        address proposalAddress = vm.envOr("TEST_FAO_PROPOSAL", DEFAULT_TEST_PROPOSAL);
        address expectedFao = vm.envOr("TEST_FAO_TOKEN", DEFAULT_TEST_FAO);
        address expectedCollateral = vm.envOr("TEST_COLLATERAL_TOKEN", GNOSIS_WXDAI);

        IFutarchyProposalLike proposal = IFutarchyProposalLike(proposalAddress);

        assertEq(proposal.collateralToken1(), expectedFao, "proposal token mismatch");
        assertEq(proposal.collateralToken2(), expectedCollateral, "collateral token mismatch");

        (address yesCompany,) = proposal.wrappedOutcome(0);
        (address noCompany,) = proposal.wrappedOutcome(1);
        (address yesCurrency,) = proposal.wrappedOutcome(2);
        (address noCurrency,) = proposal.wrappedOutcome(3);

        assertTrue(yesCompany != address(0) && noCompany != address(0), "company outcomes missing");
        assertTrue(
            yesCurrency != address(0) && noCurrency != address(0), "currency outcomes missing"
        );
        assertTrue(yesCompany != noCompany, "YES/NO company outcomes identical");
        assertTrue(yesCurrency != noCurrency, "YES/NO currency outcomes identical");

        string memory faoSymbol = IERC20Metadata(expectedFao).symbol();
        string memory collateralSymbol = IERC20Metadata(expectedCollateral).symbol();

        string memory yesCompanySymbol = IERC20Metadata(yesCompany).symbol();
        string memory noCompanySymbol = IERC20Metadata(noCompany).symbol();
        string memory yesCurrencySymbol = IERC20Metadata(yesCurrency).symbol();
        string memory noCurrencySymbol = IERC20Metadata(noCurrency).symbol();

        assertTrue(_startsWith(yesCompanySymbol, "YES_"), "YES company symbol prefix mismatch");
        assertTrue(_startsWith(noCompanySymbol, "NO_"), "NO company symbol prefix mismatch");
        assertTrue(_contains(yesCompanySymbol, faoSymbol), "YES company symbol missing FAO");
        assertTrue(_contains(noCompanySymbol, faoSymbol), "NO company symbol missing FAO");

        assertTrue(_startsWith(yesCurrencySymbol, "YES_"), "YES currency symbol prefix mismatch");
        assertTrue(_startsWith(noCurrencySymbol, "NO_"), "NO currency symbol prefix mismatch");
        assertTrue(
            _contains(yesCurrencySymbol, collateralSymbol), "YES currency symbol missing base"
        );
        assertTrue(_contains(noCurrencySymbol, collateralSymbol), "NO currency symbol missing base");
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > valueBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0) return true;
        if (needleBytes.length > valueBytes.length) return false;

        for (uint256 i; i <= valueBytes.length - needleBytes.length; ++i) {
            bool matchFound = true;
            for (uint256 j; j < needleBytes.length; ++j) {
                if (valueBytes[i + j] != needleBytes[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) return true;
        }
        return false;
    }
}
