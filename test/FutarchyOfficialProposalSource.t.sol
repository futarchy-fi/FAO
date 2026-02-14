// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FutarchyOfficialProposalSource} from "../src/FutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockProposalSettlementOracle} from "./mocks/MockProposalSettlementOracle.sol";

contract FutarchyOfficialProposalSourceTest is Test {
    FutarchyOfficialProposalSource internal source;
    MockAlgebraFactoryLike internal factory;
    MockProposalSettlementOracle internal oracle;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);
    address internal officialProposer = address(0x1111);

    address internal fao = address(0xA001);
    address internal wxdai = address(0xA002);
    address internal yesComp = address(0xA101);
    address internal noComp = address(0xA102);
    address internal yesCurr = address(0xA103);
    address internal noCurr = address(0xA104);
    address internal yesPool = address(0xB101);
    address internal noPool = address(0xB102);

    function setUp() public {
        factory = new MockAlgebraFactoryLike();
        source = new FutarchyOfficialProposalSource(
            owner, officialProposer, IAlgebraFactoryLike(address(factory))
        );
        oracle = new MockProposalSettlementOracle();
    }

    function test_set_and_read_official_proposal() public {
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);

        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond"), yesComp, noComp, yesCurr, noCurr
        );

        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(1, address(proposal));

        (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPoolOut,
            address noPoolOut
        ) = source.officialProposal();

        assertEq(proposalId, 1);
        assertEq(creator, officialProposer);
        assertTrue(exists);
        assertFalse(settled);
        assertEq(proposalToken, fao);
        assertEq(collateralToken, wxdai);
        assertEq(yesPoolOut, yesPool);
        assertEq(noPoolOut, noPool);

        IFutarchyOfficialProposalSource.OfficialProposalData memory extended =
            source.officialProposalExtended();
        assertEq(extended.proposalId, 1);
        assertEq(extended.proposal, address(proposal));
        assertEq(extended.yesCompanyToken, yesComp);
        assertEq(extended.noCompanyToken, noComp);
        assertEq(extended.yesCurrencyToken, yesCurr);
        assertEq(extended.noCurrencyToken, noCurr);
    }

    function test_official_proposer_can_set_official_proposal_without_owner() public {
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);

        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond"), yesComp, noComp, yesCurr, noCurr
        );

        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(1, address(proposal));

        (
            uint256 proposalId,
            address creator,
            bool exists,,
            address proposalToken,
            address collateralToken,,
        ) = source.officialProposal();
        assertEq(proposalId, 1);
        assertEq(creator, officialProposer);
        assertTrue(exists);
        assertEq(proposalToken, fao);
        assertEq(collateralToken, wxdai);
    }

    function test_only_official_proposer_can_call_set_official_proposal_from_proposer() public {
        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond"), yesComp, noComp, yesCurr, noCurr
        );

        vm.prank(nonOwner);
        vm.expectRevert(FutarchyOfficialProposalSource.NotOfficialProposer.selector);
        source.setOfficialProposalFromOfficialProposer(1, address(proposal));
    }

    function test_settled_with_manual_flag() public {
        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond"), yesComp, noComp, yesCurr, noCurr
        );
        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(7, address(proposal));

        source.setManualSettled(true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_settled_with_oracle_override() public {
        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond"), yesComp, noComp, yesCurr, noCurr
        );
        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(9, address(proposal));
        source.setManualSettled(false);
        source.setSettlementOracle(address(oracle));

        oracle.setSettled(address(proposal), true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_cannot_set_new_unsettled_official_proposal() public {
        MockFutarchyProposalLike p1 = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond1"), yesComp, noComp, yesCurr, noCurr
        );
        MockFutarchyProposalLike p2 = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond2"), yesComp, noComp, yesCurr, noCurr
        );

        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(1, address(p1));
        vm.expectRevert(FutarchyOfficialProposalSource.ActiveOfficialProposalExists.selector);
        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(2, address(p2));
    }

    function test_can_replace_after_settlement() public {
        MockFutarchyProposalLike p1 = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond1"), yesComp, noComp, yesCurr, noCurr
        );
        MockFutarchyProposalLike p2 = new MockFutarchyProposalLike(
            fao, wxdai, bytes32("cond2"), yesComp, noComp, yesCurr, noCurr
        );

        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(1, address(p1));
        source.setManualSettled(true);
        vm.prank(officialProposer);
        source.setOfficialProposalFromOfficialProposer(2, address(p2));

        (uint256 proposalId,, bool exists,,,,,) = source.officialProposal();
        assertEq(proposalId, 2);
        assertTrue(exists);
    }

    function test_only_owner_guards() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        source.setOfficialProposer(address(0xCAFE));
    }
}
