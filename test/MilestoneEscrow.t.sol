pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {FalseUSDC} from "./mocks/FalseUSDC.sol";
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
    uint64 constant START = 1_800_000_000;
    uint64 constant WEEK = 7 days;

    function setUp() public {
        vm.warp(START);
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

    function _deadlines() internal pure returns (uint64[] memory deadlines) {
        deadlines = new uint64[](3);
        deadlines[0] = START + WEEK;
        deadlines[1] = START + 2 * WEEK;
        deadlines[2] = START + 3 * WEEK;
    }

    function _specs() internal pure returns (bytes32[] memory specs) {
        specs = new bytes32[](3);
        specs[0] = keccak256("design");
        specs[1] = keccak256("build");
        specs[2] = keccak256("launch");
    }

    function _single(uint256 amount)
        internal
        pure
        returns (uint256[] memory a, uint64[] memory d, bytes32[] memory s)
    {
        a = new uint256[](1);
        a[0] = amount;
        d = new uint64[](1);
        d[0] = START + WEEK;
        s = new bytes32[](1);
        s[0] = keccak256("only");
    }

    function _create() internal returns (uint256 dealId) {
        (address[] memory payees, uint16[] memory shares) = _team();
        vm.prank(client);
        dealId = escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());
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
            uint64[] memory deadlines,
            bytes32[] memory specs,
            MilestoneEscrow.MilestoneState[] memory states
        ) = escrow.getDeal(dealId);

        assertEq(storedClient, client);
        assertEq(storedArbiter, arbiter);
        assertEq(payees.length, 3);
        assertEq(shares[1], 3000);
        assertEq(amounts[2], 1_500 * USDC);
        assertEq(deadlines[1], START + 2 * WEEK);
        assertEq(specs[0], keccak256("design"));
        assertEq(uint256(states[0]), uint256(MilestoneEscrow.MilestoneState.Funded));
    }

    function test_CreateDealEmitsEverythingTheIndexerNeeds() public {
        (address[] memory payees, uint16[] memory shares) = _team();
        vm.expectEmit(true, true, true, true);
        emit MilestoneEscrow.DealCreated(
            1, client, lead, arbiter, 5_000 * USDC, payees, shares, _amounts(), _deadlines(), _specs()
        );
        _create();
    }

    function test_GetMilestoneReadsOneMilestone() public {
        uint256 dealId = _create();
        vm.prank(client);
        escrow.release(dealId, 1);

        (uint256 amount, uint64 deadline, bytes32 spec, MilestoneEscrow.MilestoneState state) =
            escrow.getMilestone(dealId, 1);
        assertEq(amount, 2_500 * USDC);
        assertEq(deadline, START + 2 * WEEK);
        assertEq(spec, keccak256("build"));
        assertEq(uint256(state), uint256(MilestoneEscrow.MilestoneState.Released));

        vm.expectRevert(MilestoneEscrow.MilestoneNotFound.selector);
        escrow.getMilestone(dealId, 3);
        vm.expectRevert(MilestoneEscrow.DealNotFound.selector);
        escrow.getMilestone(2, 0);
    }

    function test_ReleaseSplitsByShares() public {
        uint256 dealId = _create();

        vm.expectEmit(true, true, true, true);
        emit MilestoneEscrow.MilestoneReleased(dealId, 0, 1_000 * USDC, client);
        vm.prank(client);
        escrow.release(dealId, 0);

        assertEq(escrow.claimable(lead), 500 * USDC);
        assertEq(escrow.claimable(dev), 300 * USDC);
        assertEq(escrow.claimable(designer), 200 * USDC);
    }

    function test_ClientCanReleaseAfterTheDeadline() public {
        uint256 dealId = _create();
        vm.warp(START + 10 * WEEK);

        vm.prank(client);
        escrow.release(dealId, 0);
        assertEq(escrow.claimable(lead), 500 * USDC);
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
        (uint256[] memory amounts, uint64[] memory deadlines, bytes32[] memory specs) = _single(100);

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(address(0), payees, shares, amounts, deadlines, specs);
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

        vm.expectEmit(true, true, true, true);
        emit MilestoneEscrow.Withdrawn(dev, 750 * USDC);
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

        vm.expectEmit(true, true, true, true);
        emit MilestoneEscrow.MilestoneRefunded(dealId, 2, 1_500 * USDC, lead);
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

    function test_ClientCannotRefundBeforeTheDeadline() public {
        uint256 dealId = _create();

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneNotExpired.selector);
        escrow.refund(dealId, 0);

        vm.warp(START + WEEK);
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneNotExpired.selector);
        escrow.refund(dealId, 0);
    }

    function test_ClientCanRefundExpiredMilestonesOnly() public {
        uint256 dealId = _create();
        vm.warp(START + WEEK + 1);

        vm.startPrank(client);
        escrow.refund(dealId, 0);
        vm.expectRevert(MilestoneEscrow.MilestoneNotExpired.selector);
        escrow.refund(dealId, 1);
        vm.stopPrank();

        assertEq(escrow.claimable(client), 1_000 * USDC);
        (,,, MilestoneEscrow.MilestoneState state) = escrow.getMilestone(dealId, 0);
        assertEq(uint256(state), uint256(MilestoneEscrow.MilestoneState.Refunded));
    }

    function test_ClientRefundOfUnknownMilestoneReverts() public {
        uint256 dealId = _create();
        vm.warp(START + 10 * WEEK);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneNotFound.selector);
        escrow.refund(dealId, 3);
    }

    function test_ExpiredMilestoneCanStillBeReleasedByTheClient() public {
        uint256 dealId = _create();
        vm.warp(START + 10 * WEEK);

        vm.prank(client);
        escrow.release(dealId, 2);
        assertEq(escrow.claimable(dev), 450 * USDC);
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

    function test_NonLeadPayeesAndStrangersCannotRefund() public {
        uint256 dealId = _create();
        vm.warp(START + 10 * WEEK);

        vm.prank(dev);
        vm.expectRevert(MilestoneEscrow.NotAuthorized.selector);
        escrow.refund(dealId, 0);

        vm.prank(stranger);
        vm.expectRevert(MilestoneEscrow.NotAuthorized.selector);
        escrow.refund(dealId, 0);
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

        vm.warp(START + 10 * WEEK);
        vm.prank(client);
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
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());
    }

    function test_RejectsBadTeams() public {
        (address[] memory payees, uint16[] memory shares) = _team();

        vm.startPrank(client);

        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(client, payees, shares, _amounts(), _deadlines(), _specs());

        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(dev, payees, shares, _amounts(), _deadlines(), _specs());

        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, new address[](0), new uint16[](0), _amounts(), _deadlines(), _specs());

        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, payees, new uint16[](2), _amounts(), _deadlines(), _specs());

        payees[1] = address(0);
        vm.expectRevert(MilestoneEscrow.ZeroAddress.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = client;
        vm.expectRevert(MilestoneEscrow.ClientCannotBePayee.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = lead;
        vm.expectRevert(MilestoneEscrow.DuplicatePayee.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = address(escrow);
        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = address(usdc);
        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = dev;
        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(address(escrow), payees, shares, _amounts(), _deadlines(), _specs());

        vm.expectRevert(MilestoneEscrow.InvalidArbiter.selector);
        escrow.createDeal(address(usdc), payees, shares, _amounts(), _deadlines(), _specs());

        payees[1] = dev;
        shares[1] = 0;
        shares[0] = 8000;
        vm.expectRevert(MilestoneEscrow.InvalidShares.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        vm.stopPrank();
    }

    function test_RejectsTooManyPayees() public {
        address[] memory payees = new address[](21);
        uint16[] memory shares = new uint16[](21);
        for (uint256 i; i < 21; ++i) {
            payees[i] = address(uint160(0x1000 + i));
            shares[i] = i == 0 ? 10_000 - 20 * 476 : 476;
        }
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.InvalidPayees.selector);
        escrow.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());
    }

    function test_RejectsBadMilestones() public {
        (address[] memory payees, uint16[] memory shares) = _team();
        uint256[] memory amounts = _amounts();
        uint64[] memory deadlines = _deadlines();
        bytes32[] memory specs = _specs();

        vm.startPrank(client);

        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, new uint256[](0), new uint64[](0), new bytes32[](0));

        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, new uint64[](2), specs);

        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, deadlines, new bytes32[](4));

        amounts[1] = 0;
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        amounts[1] = 2_500 * USDC;

        deadlines[2] = START;
        vm.expectRevert(MilestoneEscrow.InvalidDeadline.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        deadlines[2] = START + 3 * WEEK;

        uint256[] memory tooMany = new uint256[](51);
        uint64[] memory manyDeadlines = new uint64[](51);
        bytes32[] memory manySpecs = new bytes32[](51);
        for (uint256 i; i < 51; ++i) {
            tooMany[i] = 1;
            manyDeadlines[i] = START + 1;
        }
        vm.expectRevert(MilestoneEscrow.InvalidMilestones.selector);
        escrow.createDeal(arbiter, payees, shares, tooMany, manyDeadlines, manySpecs);

        vm.stopPrank();
    }

    function test_RejectsTotalAboveTheCap() public {
        (address[] memory payees, uint16[] memory shares) = _team();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = uint256(type(uint128).max);
        amounts[1] = 1;
        uint64[] memory deadlines = new uint64[](2);
        deadlines[0] = START + WEEK;
        deadlines[1] = START + WEEK;
        bytes32[] memory specs = new bytes32[](2);

        vm.startPrank(client);
        vm.expectRevert(MilestoneEscrow.TotalTooLarge.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);

        amounts[0] = type(uint256).max;
        amounts[1] = type(uint256).max;
        vm.expectRevert(MilestoneEscrow.TotalTooLarge.selector);
        escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        vm.stopPrank();
    }

    function test_TransferReturningFalseReverts() public {
        MilestoneEscrow strict = new MilestoneEscrow(address(new FalseUSDC()));
        (address[] memory payees, uint16[] memory shares) = _team();

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.TransferFailed.selector);
        strict.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());

        vm.mockCall(address(strict.token()), abi.encodeWithSelector(FalseUSDC.transferFrom.selector), abi.encode(true));
        vm.prank(client);
        uint256 dealId = strict.createDeal(arbiter, payees, shares, _amounts(), _deadlines(), _specs());
        vm.prank(client);
        strict.release(dealId, 0);

        vm.prank(dev);
        vm.expectRevert(MilestoneEscrow.TransferFailed.selector);
        strict.withdraw();
        assertEq(strict.claimable(dev), 300 * USDC);
    }

    function test_SettledMilestoneReportsSettledToTheClientBeforeTheDeadline() public {
        uint256 dealId = _create();
        vm.prank(lead);
        escrow.refund(dealId, 0);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.MilestoneAlreadySettled.selector);
        escrow.refund(dealId, 0);
    }

    function test_AcceptsTheLargestAllowedDeal() public {
        address[] memory payees = new address[](20);
        uint16[] memory shares = new uint16[](20);
        for (uint256 i; i < 20; ++i) {
            payees[i] = address(uint160(0x3000 + i));
            shares[i] = 500;
        }
        uint256[] memory amounts = new uint256[](50);
        uint64[] memory deadlines = new uint64[](50);
        bytes32[] memory specs = new bytes32[](50);
        for (uint256 i; i < 50; ++i) {
            amounts[i] = USDC;
            deadlines[i] = START + 1;
        }

        vm.startPrank(client);
        uint256 first = escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        uint256 second = escrow.createDeal(address(0), payees, shares, amounts, deadlines, specs);
        escrow.release(second, 49);
        vm.stopPrank();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(escrow.claimable(payees[19]), USDC / 20);
        vm.expectRevert(MilestoneEscrow.DealNotFound.selector);
        escrow.getDeal(3);
    }

    function test_SinglePayeeTakesTheWholeMilestone() public {
        address[] memory payees = new address[](1);
        payees[0] = lead;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        (uint256[] memory amounts, uint64[] memory deadlines, bytes32[] memory specs) = _single(777);

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(address(0), payees, shares, amounts, deadlines, specs);
        escrow.release(dealId, 0);
        vm.stopPrank();

        assertEq(escrow.claimable(lead), 777);
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
        amount = bound(amount, 1, type(uint128).max);
        shareA = uint16(bound(shareA, 1, 9_998));
        shareB = uint16(bound(shareB, 1, 9_999 - shareA));
        usdc.mint(client, amount);

        address[] memory payees = new address[](3);
        payees[0] = lead;
        payees[1] = dev;
        payees[2] = designer;
        uint16[] memory shares = new uint16[](3);
        shares[0] = shareA;
        shares[1] = shareB;
        shares[2] = uint16(10_000 - shareA - shareB);
        (uint256[] memory amounts, uint64[] memory deadlines, bytes32[] memory specs) = _single(amount);

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(address(0), payees, shares, amounts, deadlines, specs);
        escrow.release(dealId, 0);
        vm.stopPrank();

        assertEq(escrow.claimable(lead) + escrow.claimable(dev) + escrow.claimable(designer), amount);
        assertLe(escrow.claimable(lead) - (amount * shareA) / 10_000, 2);
        assertEq(escrow.claimable(dev), (amount * shareB) / 10_000);
    }

    function testFuzz_ReleaseWithManyPayees(uint256 amount, uint8 count, uint256 seed) public {
        amount = bound(amount, 1, type(uint128).max);
        count = uint8(bound(count, 1, 20));
        usdc.mint(client, amount);

        address[] memory payees = new address[](count);
        uint16[] memory shares = new uint16[](count);
        uint256 left = 10_000;
        for (uint256 i; i < count; ++i) {
            payees[i] = address(uint160(0x2000 + i));
            uint256 room = left - (count - 1 - i);
            uint256 share = i == count - 1 ? left : 1 + (uint256(keccak256(abi.encode(seed, i))) % room);
            shares[i] = uint16(share);
            left -= share;
        }
        (uint256[] memory amounts, uint64[] memory deadlines, bytes32[] memory specs) = _single(amount);

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        escrow.release(dealId, 0);
        vm.stopPrank();

        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += escrow.claimable(payees[i]);
            if (i > 0) assertEq(escrow.claimable(payees[i]), (amount * shares[i]) / 10_000);
        }
        assertEq(sum, amount);
    }

    function testFuzz_ClientRefundRespectsTheDeadline(uint64 deadline, uint64 now_) public {
        deadline = uint64(bound(deadline, START + 1, type(uint64).max - 1));
        now_ = uint64(bound(now_, START, type(uint64).max - 1));
        (address[] memory payees, uint16[] memory shares) = _team();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 * USDC;
        uint64[] memory deadlines = new uint64[](1);
        deadlines[0] = deadline;
        bytes32[] memory specs = new bytes32[](1);

        vm.startPrank(client);
        uint256 dealId = escrow.createDeal(arbiter, payees, shares, amounts, deadlines, specs);
        vm.warp(now_);
        if (now_ > deadline) {
            escrow.refund(dealId, 0);
            assertEq(escrow.claimable(client), 10 * USDC);
        } else {
            vm.expectRevert(MilestoneEscrow.MilestoneNotExpired.selector);
            escrow.refund(dealId, 0);
        }
        vm.stopPrank();
    }
}
