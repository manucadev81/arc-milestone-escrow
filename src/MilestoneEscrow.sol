pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MilestoneEscrow {
    enum MilestoneState {
        Funded,
        Released,
        Refunded
    }

    struct Deal {
        address client;
        address arbiter;
        address[] payees;
        uint16[] sharesBps;
        uint256[] amounts;
        MilestoneState[] states;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 20;
    uint256 public constant MAX_MILESTONES = 50;

    IERC20 public immutable token;
    uint256 public dealCount;
    mapping(address => uint256) public claimable;
    mapping(uint256 => Deal) private deals;

    event DealCreated(
        uint256 indexed dealId, address indexed client, address indexed lead, address arbiter, uint256 total
    );
    event MilestoneReleased(uint256 indexed dealId, uint256 indexed index, uint256 amount, address indexed by);
    event MilestoneRefunded(uint256 indexed dealId, uint256 indexed index, uint256 amount, address indexed by);
    event Withdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error InvalidPayees();
    error InvalidMilestones();
    error InvalidShares();
    error InvalidArbiter();
    error DealNotFound();
    error MilestoneNotFound();
    error MilestoneAlreadySettled();
    error NotAuthorized();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
    }

    function createDeal(
        address arbiter,
        address[] calldata payees,
        uint16[] calldata sharesBps,
        uint256[] calldata amounts
    ) external returns (uint256 dealId) {
        _checkTeam(arbiter, payees, sharesBps);
        uint256 total = _checkMilestones(amounts);

        dealId = ++dealCount;
        Deal storage deal = deals[dealId];
        deal.client = msg.sender;
        deal.arbiter = arbiter;
        deal.payees = payees;
        deal.sharesBps = sharesBps;
        deal.amounts = amounts;
        for (uint256 i; i < amounts.length; ++i) {
            deal.states.push(MilestoneState.Funded);
        }

        emit DealCreated(dealId, msg.sender, payees[0], arbiter, total);

        if (!token.transferFrom(msg.sender, address(this), total)) revert TransferFailed();
    }

    function release(uint256 dealId, uint256 index) external {
        Deal storage deal = _deal(dealId);
        if (msg.sender != deal.client && msg.sender != deal.arbiter) revert NotAuthorized();
        uint256 amount = _settle(deal, index, MilestoneState.Released);

        uint256 payeeCount = deal.payees.length;
        uint256 distributed;
        for (uint256 i = 1; i < payeeCount; ++i) {
            uint256 part = (amount * deal.sharesBps[i]) / BPS;
            claimable[deal.payees[i]] += part;
            distributed += part;
        }
        claimable[deal.payees[0]] += amount - distributed;

        emit MilestoneReleased(dealId, index, amount, msg.sender);
    }

    function refund(uint256 dealId, uint256 index) external {
        Deal storage deal = _deal(dealId);
        if (msg.sender != deal.payees[0] && msg.sender != deal.arbiter) revert NotAuthorized();
        uint256 amount = _settle(deal, index, MilestoneState.Refunded);

        claimable[deal.client] += amount;

        emit MilestoneRefunded(dealId, index, amount, msg.sender);
    }

    function withdraw() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender] = 0;

        emit Withdrawn(msg.sender, amount);

        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
    }

    function getDeal(uint256 dealId)
        external
        view
        returns (
            address client,
            address arbiter,
            address[] memory payees,
            uint16[] memory sharesBps,
            uint256[] memory amounts,
            MilestoneState[] memory states
        )
    {
        Deal storage deal = _deal(dealId);
        return (deal.client, deal.arbiter, deal.payees, deal.sharesBps, deal.amounts, deal.states);
    }

    function _checkTeam(address arbiter, address[] calldata payees, uint16[] calldata sharesBps) private view {
        uint256 payeeCount = payees.length;
        if (payeeCount == 0 || payeeCount > MAX_PAYEES || payeeCount != sharesBps.length) revert InvalidPayees();
        if (arbiter == msg.sender) revert InvalidArbiter();

        uint256 shareSum;
        for (uint256 i; i < payeeCount; ++i) {
            if (payees[i] == address(0)) revert ZeroAddress();
            if (payees[i] == arbiter) revert InvalidArbiter();
            if (sharesBps[i] == 0) revert InvalidShares();
            shareSum += sharesBps[i];
        }
        if (shareSum != BPS) revert InvalidShares();
    }

    function _checkMilestones(uint256[] calldata amounts) private pure returns (uint256 total) {
        uint256 milestoneCount = amounts.length;
        if (milestoneCount == 0 || milestoneCount > MAX_MILESTONES) revert InvalidMilestones();
        for (uint256 i; i < milestoneCount; ++i) {
            if (amounts[i] == 0) revert InvalidMilestones();
            total += amounts[i];
        }
    }

    function _deal(uint256 dealId) private view returns (Deal storage deal) {
        deal = deals[dealId];
        if (deal.client == address(0)) revert DealNotFound();
    }

    function _settle(Deal storage deal, uint256 index, MilestoneState next) private returns (uint256 amount) {
        if (index >= deal.amounts.length) revert MilestoneNotFound();
        if (deal.states[index] != MilestoneState.Funded) revert MilestoneAlreadySettled();
        deal.states[index] = next;
        amount = deal.amounts[index];
    }
}
