pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract EscrowHandler is Test {
    MilestoneEscrow public escrow;
    MockUSDC public usdc;

    address[] public clients;
    address[] public team;
    address public arbiter;
    address[] public everyone;

    uint256 public constant USDC = 1e6;
    uint256 public settledTwice;
    uint256 public creditMismatches;
    uint256 public fundedOutstanding;
    mapping(uint256 => mapping(uint256 => uint256)) public settlements;

    constructor(MilestoneEscrow escrow_, MockUSDC usdc_) {
        escrow = escrow_;
        usdc = usdc_;
        arbiter = makeAddr("arbiter");
        for (uint256 i; i < 3; ++i) {
            address c = makeAddr(string(abi.encodePacked("client", i)));
            clients.push(c);
            everyone.push(c);
            usdc.mint(c, 10_000_000 * USDC);
            vm.prank(c);
            usdc.approve(address(escrow), type(uint256).max);
        }
        for (uint256 i; i < 5; ++i) {
            address p = makeAddr(string(abi.encodePacked("payee", i)));
            team.push(p);
            everyone.push(p);
        }
        everyone.push(arbiter);
    }

    function everyoneCount() external view returns (uint256) {
        return everyone.length;
    }

    function createDeal(uint256 clientSeed, uint8 payeeCount, uint8 milestoneCount, uint256 seed, bool withArbiter)
        external
    {
        address client = clients[clientSeed % clients.length];
        payeeCount = uint8(bound(payeeCount, 1, team.length));
        milestoneCount = uint8(bound(milestoneCount, 1, 6));

        address[] memory payees = new address[](payeeCount);
        uint16[] memory shares = new uint16[](payeeCount);
        uint256 left = 10_000;
        for (uint256 i; i < payeeCount; ++i) {
            payees[i] = team[i];
            uint256 room = left - (payeeCount - 1 - i);
            uint256 share = i == payeeCount - 1 ? left : 1 + (uint256(keccak256(abi.encode(seed, i))) % room);
            shares[i] = uint16(share);
            left -= share;
        }

        uint256[] memory amounts = new uint256[](milestoneCount);
        uint64[] memory deadlines = new uint64[](milestoneCount);
        bytes32[] memory specs = new bytes32[](milestoneCount);
        uint256 total;
        for (uint256 i; i < milestoneCount; ++i) {
            amounts[i] = 1 + (uint256(keccak256(abi.encode(seed, "amt", i))) % (1_000 * USDC));
            deadlines[i] = uint64(block.timestamp + 1 + (uint256(keccak256(abi.encode(seed, "dl", i))) % 30 days));
            specs[i] = keccak256(abi.encode(seed, i));
            total += amounts[i];
        }
        if (usdc.balanceOf(client) < total) return;

        vm.prank(client);
        escrow.createDeal(withArbiter ? arbiter : address(0), payees, shares, amounts, deadlines, specs);
        fundedOutstanding += total;
    }

    function release(uint256 dealSeed, uint256 index, bool byArbiter) external {
        uint256 count = escrow.dealCount();
        if (count == 0) return;
        uint256 dealId = 1 + (dealSeed % count);
        (address client, address dealArbiter,,, uint256[] memory amounts,,,) = escrow.getDeal(dealId);
        index = index % amounts.length;
        address actor = byArbiter && dealArbiter != address(0) ? dealArbiter : client;

        uint256 before = _sumClaimable();
        vm.prank(actor);
        try escrow.release(dealId, index) {
            _recordSettlement(dealId, index);
            fundedOutstanding -= amounts[index];
            if (_sumClaimable() - before != amounts[index]) creditMismatches++;
        } catch {}
    }

    function refund(uint256 dealSeed, uint256 index, uint8 who) external {
        uint256 count = escrow.dealCount();
        if (count == 0) return;
        uint256 dealId = 1 + (dealSeed % count);
        (address client, address dealArbiter, address[] memory payees,, uint256[] memory amounts,,,) =
            escrow.getDeal(dealId);
        index = index % amounts.length;
        address actor = who % 3 == 0 ? client : who % 3 == 1 ? payees[0] : dealArbiter;
        if (actor == address(0)) actor = payees[0];

        uint256 before = escrow.claimable(client);
        vm.prank(actor);
        try escrow.refund(dealId, index) {
            _recordSettlement(dealId, index);
            fundedOutstanding -= amounts[index];
            if (escrow.claimable(client) - before != amounts[index]) creditMismatches++;
        } catch {}
    }

    function withdraw(uint256 who) external {
        address actor = everyone[who % everyone.length];
        vm.prank(actor);
        try escrow.withdraw() {} catch {}
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + bound(by, 1, 60 days));
    }

    function sumClaimable() external view returns (uint256) {
        return _sumClaimable();
    }

    function _sumClaimable() internal view returns (uint256 sum) {
        for (uint256 i; i < everyone.length; ++i) {
            sum += escrow.claimable(everyone[i]);
        }
    }

    function _recordSettlement(uint256 dealId, uint256 index) internal {
        settlements[dealId][index]++;
        if (settlements[dealId][index] > 1) settledTwice++;
    }
}

contract MilestoneEscrowInvariants is Test {
    MockUSDC usdc;
    MilestoneEscrow escrow;
    EscrowHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        escrow = new MilestoneEscrow(address(usdc));
        handler = new EscrowHandler(escrow, usdc);
        targetContract(address(handler));
    }

    function invariant_EscrowBalanceCoversClaimableAndFunded() public view {
        assertEq(usdc.balanceOf(address(escrow)), handler.sumClaimable() + handler.fundedOutstanding());
    }

    function invariant_MilestonesSettleAtMostOnce() public view {
        assertEq(handler.settledTwice(), 0);
    }

    function invariant_EverySettlementCreditsExactlyTheMilestone() public view {
        assertEq(handler.creditMismatches(), 0);
    }

    function invariant_StatesMatchTheLedger() public view {
        uint256 funded;
        for (uint256 d = 1; d <= escrow.dealCount(); ++d) {
            (,,,, uint256[] memory amounts,,, MilestoneEscrow.MilestoneState[] memory states) = escrow.getDeal(d);
            for (uint256 i; i < amounts.length; ++i) {
                if (states[i] == MilestoneEscrow.MilestoneState.Funded) funded += amounts[i];
            }
        }
        assertEq(funded, handler.fundedOutstanding());
    }
}
