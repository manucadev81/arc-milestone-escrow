pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract MilestoneEscrowTest is Test {
    MockUSDC usdc;
    MilestoneEscrow escrow;

    address client = makeAddr("client");
    address lead = makeAddr("lead");
    address dev = makeAddr("dev");
    address designer = makeAddr("designer");
    address arbiter = makeAddr("arbiter");
    address stranger = makeAddr("stranger");

    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new MilestoneEscrow(address(usdc));
        usdc.mint(client, 1_000_000 * USDC);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _team() internal view returns (address[] memory payees, uint16[] memory shares) {
        payees = new address[](3);
        payees[0] = lead;
        payees[1] = dev;
        payees[2] = designer;
        shares = new uint16[](3);
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;
    }

    function _amounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        amounts[0] = 1_000 * USDC;
        amounts[1] = 2_500 * USDC;
        amounts[2] = 1_500 * USDC;
    }

    function _create() internal returns (uint256 dealId) {
        (address[] memory payees, uint16[] memory shares) = _team();
        vm.prank(client);
        dealId = escrow.createDeal(arbiter, payees, shares, _amounts());
    }

    function test_CreateDealLocksTheFullAmount() public {
        uint256 before = usdc.balanceOf(client);
        uint256 dealId = _create();

        assertEq(dealId, 1);
        assertEq(usdc.balanceOf(address(escrow)), 5_000 * USDC);
        assertEq(usdc.balanceOf(client), before - 5_000 * USDC);

        (
            address storedClient,
            address storedArbiter,
            address[] memory payees,
            uint16[] memory shares,
            uint256[] memory amounts,
            MilestoneEscrow.MilestoneState[] memory states
        ) = escrow.getDeal(dealId);

        assertEq(storedClient, client);
        assertEq(storedArbiter, arbiter);
        assertEq(payees.length, 3);
        assertEq(shares[1], 3000);
        assertEq(amounts[2], 1_500 * USDC);
        assertEq(uint256(states[0]), uint256(MilestoneEscrow.MilestoneState.Funded));
    }

    function test_ReleaseSplitsByShares() public {
        uint256 dealId = _create();

        vm.prank(client);
        escrow.release(dealId, 0);

        assertEq(escrow.claimable(lead), 500 * USDC);
        assertEq(escrow.claimable(dev), 300 * USDC);
        assertEq(escrow.claimable(designer), 200 * USDC);
    }

    function test_LeadReceivesRoundingDust() public {
        address[] memory payees = new address[](3);
        payees[0] = lead;
        payees[1] = dev;
        payees[2] = designer;
        uint16[] memory shares = new uint16[](3);
        shares[0] = 3334;
        shares[1] = 3333;
        shares[2] = 3333;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(address(0), payees, shares, amounts);
        escrow.release(dealId, 0);
        vm.stopPrank();

        assertEq(escrow.claimable(dev), 33);
        assertEq(escrow.claimable(designer), 33);
        assertEq(escrow.claimable(lead), 34);
    }

    function test_WithdrawPaysOutAndClearsBalance() public {
        uint256 dealId = _create();
        vm.prank(client);
        escrow.release(dealId, 1);

        vm.prank(dev);
        uint256 paid = escrow.withdraw();

        assertEq(paid, 750 * USDC);
        assertEq(usdc.balanceOf(dev), 750 * USDC);
        assertEq(escrow.claimable(dev), 0);

        vm.prank(dev);
        vm.expectRevert(MilestoneEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    function test_LeadCanRefundTheClient() public {
        uint256 dealId = _create();

        vm.prank(lead);
        escrow.refund(dealId, 2);

        assertEq(escrow.claimable(client), 1_500 * USDC);

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        escrow.withdraw();
        assertEq(usdc.balanceOf(client), before + 1_500 * USDC);
    }

    function test_ArbiterCanSettleEitherWay() public {
        uint256 dealId = _create();

        vm.startPrank(arbiter);
        escrow.release(dealId, 0);
        escrow.refund(dealId, 1);
        vm.stopPrank();

        assertEq(escrow.claimable(lead), 500 * USDC);
        assertEq(escrow.claimable(client), 2_500 * USDC);
    }

    function test_ClientCannotRefundThemselves() public {
        uint256 dealId = _create();

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.NotAuthorized.selector);
        escrow.refund(dealId, 0);
    }

    function test_PayeesCannotReleaseToThemselves() public {
        uint256 dealId = _create();

        vm.prank(lead);
        vm.expectRevert(MilestoneEscrow.NotAuthorized.selector);
        escrow.release(dealId, 0);

        vm.prank(stranger);
        vm.expectRevert(MilestoneEscrow.NotAuthorized.selector);
        escrow.release(dealId, 0);
    }

    function test_MilestoneSettlesOnlyOnce() public {
        uint256 dealId = _create();

        vm.prank(client);
        escrow.release(dealId, 0);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneAlreadySettled.selector);
        escrow.release(dealId, 0);

        vm.prank(lead);
        vm.expectRevert(MilestoneEscrow.MilestoneAlreadySettled.selector);
        escrow.refund(dealId, 0);
    }

    function test_UnknownDealAndMilestoneRevert() public {
        uint256 dealId = _create();

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.DealNotFound.selector);
        escrow.release(99, 0);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneNotFound.selector);
        escrow.release(dealId, 3);
    }

    function test_SharesMustSumToOneHundredPercent() public {
        (address[] memory payees, uint16[] memory shares) = _team();
        shares[2] = 1999;

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.InvalidShares.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts());
    }

    function test_RejectsBadInputs() public {
        (address[] memory payees, uint16[] memory shares) = _team();
        uint256[] memory amounts = _amounts();

        vm.startPrank(client);

        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(client, payees, shares, amounts);

        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(dev, payees, shares, amounts);

        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, new uint256[](0));

        amounts[1] = 0;
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, amounts);

        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, new address[](0), new uint16[](0), _amounts());

        payees[1] = address(0);
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts());

        vm.stopPrank();
    }

    function test_ConstructorRejectsZeroToken() public {
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        new MilestoneEscrow(address(0));
    }

    function test_BlockedPayeeDoesNotStopTheRestOfTheTeam() public {
        uint256 dealId = _create();
        usdc.setBlocked(designer, true);

        vm.prank(client);
        escrow.release(dealId, 0);

        vm.prank(dev);
        escrow.withdraw();
        vm.prank(lead);
        escrow.withdraw();

        assertEq(usdc.balanceOf(dev), 300 * USDC);
        assertEq(usdc.balanceOf(lead), 500 * USDC);

        vm.prank(designer);
        vm.expectRevert(bytes("blocked"));
        escrow.withdraw();
        assertEq(escrow.claimable(designer), 200 * USDC);
    }

    function test_EscrowBalanceAlwaysCoversWhatItOwes() public {
        uint256 dealId = _create();

        vm.prank(client);
        escrow.release(dealId, 0);
        vm.prank(lead);
        escrow.refund(dealId, 1);
        vm.prank(dev);
        escrow.withdraw();

        uint256 owed = escrow.claimable(lead) + escrow.claimable(dev) + escrow.claimable(designer)
            + escrow.claimable(client) + 1_500 * USDC;
        assertEq(usdc.balanceOf(address(escrow)), owed);
    }

    function testFuzz_ReleaseDistributesExactlyTheMilestone(uint256 amount, uint16 shareA, uint16 shareB) public {
        amount = bound(amount, 1, 1_000_000 * USDC);
        shareA = uint16(bound(shareA, 1, 9_998));
        shareB = uint16(bound(shareB, 1, 9_999 - shareA));

        address[] memory payees = new address[](3);
        payees[0] = lead;
        payees[1] = dev;
        payees[2] = designer;
        uint16[] memory shares = new uint16[](3);
        shares[0] = shareA;
        shares[1] = shareB;
        shares[2] = uint16(10_000 - shareA - shareB);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(address(0), payees, shares, amounts);
        escrow.release(dealId, 0);
        vm.stopPrank();

        assertEq(escrow.claimable(lead) + escrow.claimable(dev) + escrow.claimable(designer), amount);
    }
}
