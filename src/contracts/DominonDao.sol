// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { EquitoApp } from "./equito-evm/src/EquitoApp.sol";
import { bytes64 ,EquitoMessage, EquitoMessageLibrary } from "./equito-evm/src/libraries/EquitoMessageLibrary.sol";

contract DominionDAO is ReentrancyGuard, AccessControl, EquitoApp {
    bytes32 private immutable CONTRIBUTOR_ROLE = keccak256("CONTRIBUTOR");
    bytes32 private immutable STAKEHOLDER_ROLE = keccak256("STAKEHOLDER");
    uint256 constant FEE_PER_MESSAGE = 0.01 ether; 

    uint256 immutable MIN_STAKEHOLDER_CONTRIBUTION = 1 ether;
    uint32 immutable MIN_VOTE_DURATION = 5 minutes;
    uint256 totalProposals;
    uint256 public daoBalance;

    mapping(uint256 => ProposalStruct) private raisedProposals;
    mapping(address => uint256[]) private stakeholderVotes;
    mapping(uint256 => VotedStruct[]) private votedOn;
    mapping(address => uint256) private contributors;
    mapping(address => uint256) private stakeholders;

    struct ProposalStruct {
        uint256 id;
        uint256 amount;
        uint256 duration;
        uint256 upvotes;
        uint256 downvotes;
        string title;
        string description;
        bool passed;
        bool paid;
        address payable beneficiary;
        address proposer;
        address executor;
    }

    struct VotedStruct {
        address voter;
        uint256 timestamp;
        bool choosen;
    }

    event Action(
        address indexed initiator,
        bytes32 role,
        string message,
        address indexed beneficiary,
        uint256 amount
    );

    constructor(address _router) EquitoApp(_router) {
        // The EquitoApp constructor initializes Ownable with msg.sender
        // No need to set up roles here unless required
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(STAKEHOLDER_ROLE, msg.sender);
    }

    modifier stakeholderOnly(string memory message) {
        require(hasRole(STAKEHOLDER_ROLE, msg.sender), message);
        _;
    }

    modifier contributorOnly(string memory message) {
        require(hasRole(CONTRIBUTOR_ROLE, msg.sender), message);
        _;
    }

    function createProposal(
        string calldata title,
        string calldata description,
        address beneficiary,
        uint256 amount,
        uint256[] calldata destinationChainSelectors
    )
        external
        payable
        stakeholderOnly("Proposal Creation Allowed for Stakeholders only")
        returns (ProposalStruct memory)
    {
        uint256 proposalId = totalProposals++;
        ProposalStruct storage proposal = raisedProposals[proposalId];

        proposal.id = proposalId;
        proposal.proposer = payable(msg.sender);
        proposal.title = title;
        proposal.description = description;
        proposal.beneficiary = payable(beneficiary);
        proposal.amount = amount;
        proposal.duration = block.timestamp + MIN_VOTE_DURATION;

        emit Action(
            msg.sender,
            CONTRIBUTOR_ROLE,
            "PROPOSAL RAISED",
            beneficiary,
            amount
        );

        // Cross-chain messaging
        bytes memory data = abi.encode("proposal", proposal);

        uint256 feePerMessage = FEE_PER_MESSAGE;
        uint256 totalFee = feePerMessage * destinationChainSelectors.length;

        require(msg.value >= totalFee, "Insufficient fee for cross-chain messages");

        for (uint256 i = 0; i < destinationChainSelectors.length; i++) {
            uint256 chainSelector = destinationChainSelectors[i];
            bytes64 memory peerAddress = getPeer(chainSelector);

            router.sendMessage{value: feePerMessage}(
                peerAddress,
                chainSelector,
                data
            );
        }

        return proposal;
    }

    function performVote(uint256 proposalId, bool choosen)
        external
        payable
        stakeholderOnly("Unauthorized: Stakeholders only")
        returns (VotedStruct memory)
    {
        ProposalStruct storage proposal = raisedProposals[proposalId];

        handleVoting(proposal);

        if (choosen) proposal.upvotes++;
        else proposal.downvotes++;

        stakeholderVotes[msg.sender].push(proposal.id);

        votedOn[proposal.id].push(
            VotedStruct(
                msg.sender,
                block.timestamp,
                choosen
            )
        );

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "PROPOSAL VOTE",
            proposal.beneficiary,
            proposal.amount
        );

        // Cross-chain voting
        bytes memory payload = abi.encode("vote", proposalId, msg.sender, choosen);

        uint256[] memory destinationChainSelectors = getOtherChainSelectors();
        uint256 feePerMessage = FEE_PER_MESSAGE;
        uint256 totalFee = feePerMessage * destinationChainSelectors.length;

        require(msg.value >= totalFee, "Insufficient fee for cross-chain messages");

        for (uint256 i = 0; i < destinationChainSelectors.length; i++) {
            uint256 chainSelector = destinationChainSelectors[i];
            bytes64 memory peerAddress = getPeer(chainSelector);

            router.sendMessage{value: feePerMessage}(
                peerAddress,
                chainSelector,
                payload
            );
        }

        return VotedStruct(
            msg.sender,
            block.timestamp,
            choosen
        );
    }

    function handleVoting(ProposalStruct storage proposal) private {
        if (
            proposal.passed ||
            proposal.duration <= block.timestamp
        ) {
            proposal.passed = true;
            revert("Proposal duration expired");
        }

        uint256[] memory tempVotes = stakeholderVotes[msg.sender];
        for (uint256 votes = 0; votes < tempVotes.length; votes++) {
            if (proposal.id == tempVotes[votes])
                revert("Double voting not allowed");
        }
    }

    function payBeneficiary(uint256 proposalId)
        external
        stakeholderOnly("Unauthorized: Stakeholders only")
        nonReentrant()
        returns (uint256)
    {
        ProposalStruct storage proposal = raisedProposals[proposalId];
        require(daoBalance >= proposal.amount, "Insufficient fund");

        if (proposal.paid) revert("Payment sent before");

        if (proposal.upvotes <= proposal.downvotes)
            revert("Insufficient votes");

        payTo(proposal.beneficiary, proposal.amount);

        proposal.paid = true;
        proposal.executor = msg.sender;
        daoBalance -= proposal.amount;

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "PAYMENT TRANSFERRED",
            proposal.beneficiary,
            proposal.amount
        );

        return daoBalance;
    }

    function contribute() payable external returns (uint256) {
        require(msg.value > 0 ether, "Contributing zero is not allowed.");
        if (!hasRole(STAKEHOLDER_ROLE, msg.sender)) {
            uint256 totalContribution =
                contributors[msg.sender] + msg.value;

            if (totalContribution >= MIN_STAKEHOLDER_CONTRIBUTION) {
                stakeholders[msg.sender] = totalContribution;
                contributors[msg.sender] += msg.value;
                _grantRole(STAKEHOLDER_ROLE, msg.sender);
                _grantRole(CONTRIBUTOR_ROLE, msg.sender);
            } else {
                contributors[msg.sender] += msg.value;
                _grantRole(CONTRIBUTOR_ROLE, msg.sender);
            }
        } else {
            contributors[msg.sender] += msg.value;
            stakeholders[msg.sender] += msg.value;
        }

        daoBalance += msg.value;

        emit Action(
            msg.sender,
            STAKEHOLDER_ROLE,
            "CONTRIBUTION RECEIVED",
            address(this),
            msg.value
        );

        return daoBalance;
    }

    // Equito cross-chain message handling
    function _receiveMessageFromPeer(
        EquitoMessage calldata message,
        bytes calldata messageData
    ) internal override {
        (string memory messageType, bytes memory payload) = abi.decode(
            messageData,
            (string, bytes)
        );

        if (keccak256(bytes(messageType)) == keccak256(bytes("proposal"))) {
            ProposalStruct memory proposal = abi.decode(payload, (ProposalStruct));
            uint256 proposalId = totalProposals++;
            raisedProposals[proposalId] = proposal;

            emit Action(
                proposal.proposer,
                STAKEHOLDER_ROLE,
                "CROSS-CHAIN PROPOSAL RECEIVED",
                proposal.beneficiary,
                proposal.amount
            );
        } else if (keccak256(bytes(messageType)) == keccak256(bytes("vote"))) {
            (uint256 proposalId, address voter, bool choosen) = abi.decode(
                payload,
                (uint256, address, bool)
            );

            ProposalStruct storage proposal = raisedProposals[proposalId];

            if (choosen) proposal.upvotes++;
            else proposal.downvotes++;

            stakeholderVotes[voter].push(proposal.id);

            votedOn[proposal.id].push(
                VotedStruct(
                    voter,
                    block.timestamp,
                    choosen
                )
            );

            emit Action(
                voter,
                STAKEHOLDER_ROLE,
                "CROSS-CHAIN PROPOSAL VOTE",
                proposal.beneficiary,
                proposal.amount
            );
        } else {
            revert("Invalid message type");
        }
    }

    function _receiveMessageFromNonPeer(
        EquitoMessage calldata message,
        bytes calldata messageData
    ) internal override {
        revert("Messages from non-peer contracts are not accepted");
    }

    // Helper function to get selectors of other chains
    function getOtherChainSelectors() internal view returns (uint256[] memory) {
        // Implement logic to return selectors of other chains
        // For example, return a hardcoded array or retrieve from storage
    }

    function getProposals()
        external
        view
        returns (ProposalStruct[] memory props)
    {
        props = new ProposalStruct[](totalProposals);

        for (uint256 i = 0; i < totalProposals; i++) {
            props[i] = raisedProposals[i];
        }
    }

    // Rest of your existing functions...

    function payTo(
        address to,
        uint256 amount
    ) internal returns (bool) {
        (bool success,) = payable(to).call{value: amount}("");
        require(success, "Payment failed");
        return true;
    }
}
