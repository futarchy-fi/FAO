// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FutarchyOfficialProposalSource} from "../src/FutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyOfficialProposalSource} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
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

        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(proposal), officialProposer);

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

    function test_settled_with_manual_flag() public {
        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);
        source.setOfficialProposal(7, address(proposal), officialProposer);

        source.setManualSettled(true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_settled_with_oracle_override() public {
        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);
        source.setOfficialProposal(9, address(proposal), officialProposer);
        source.setManualSettled(false);
        source.setSettlementOracle(address(oracle));

        oracle.setSettled(address(proposal), true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_cannot_set_new_unsettled_official_proposal() public {
        MockFutarchyProposalLike p1 =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);
        MockFutarchyProposalLike p2 =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(p1), officialProposer);
        vm.expectRevert(FutarchyOfficialProposalSource.ActiveOfficialProposalExists.selector);
        source.setOfficialProposal(2, address(p2), officialProposer);
    }

    function test_can_replace_after_settlement() public {
        MockFutarchyProposalLike p1 =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);
        MockFutarchyProposalLike p2 =
            new MockFutarchyProposalLike(fao, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(p1), officialProposer);
        source.setManualSettled(true);
        source.setOfficialProposal(2, address(p2), officialProposer);

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
