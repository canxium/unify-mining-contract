// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract WorkDistribution {

    // --- Config ---
    // Minimum deposit to become a miner
    uint256 public constant MIN_DEPOSIT = 303 ether;
    uint256 public constant EPOCH_LENGTH = 86400; // Approx. 1 day in blocks
    uint256 public constant INACTIVITY_LIMIT = 7; // 1 week in epochs
    uint256 public constant INACTIVITY_PENALTY = 1 ether;
    uint64 public constant TOTAL_NONCE_SPACE = type(uint64).max;
    uint256 deposited = 0;

    // --- State ---
    struct MinerNonces {
        uint256 deposited;          // Amount deposited
        uint256 wons;               // Reset every epoch
        uint64 start;               // Assigned range start
        uint64 end;                 // Assigned range end
        uint256 registeredEpoch;    // Epoch when miner registered
        uint256 lastWonEpoch;       // Last epoch when miner won
    }

    address[] public miners;
    mapping(address => MinerNonces) public minerNonces;

    uint256 public minWinsInEpoch;

    event NonceFound(address indexed miner, uint64 nonce, uint256 blockNumber);
    event EpochRotated(uint256 newEpochStart, uint256 totalMiners);

    constructor() {
    }

    /**
     * @dev Register as a miner by depositing the required amount.
     */
    function register(address miner) external payable {
        require(minerNonces[miner].deposited == 0, "Already registered");
        uint256 required = (MIN_DEPOSIT * (miners.length + 1) * 23053) / 5000000;
        require(msg.value >= required, "Insufficient deposit");

        deposited += msg.value;
        uint256 currentEpoch = block.number / EPOCH_LENGTH;
        minerNonces[miner] = MinerNonces(msg.value, 0, 0, 0, currentEpoch, 0);
        miners.push(miner);
    }

    /**
     * @dev Exit as a miner and withdraw deposited funds.
     * Cannot exit in the same epoch as registration.
     */
    function exit() external payable {
        require(minerNonces[msg.sender].deposited > 0, "Not registered");
        uint256 currentEpoch = block.number / EPOCH_LENGTH;
        require(minerNonces[msg.sender].registeredEpoch < currentEpoch, "Cannot exit in same epoch");

        (bool sent, ) = payable(msg.sender).call{value: minerNonces[msg.sender].deposited}("");
        require(sent, "Failed to withdraw deposited funds");
        deposited -= minerNonces[msg.sender].deposited;
        delete minerNonces[msg.sender];
    }

    /**
     * @dev The "System Transaction". 
     * Miner call this function to submit the nonce for previous block.
     * Since PoW 2.0 are lag-rewarded.
     */
    function mined(uint64 nonceFound) external {
        require(tx.origin == msg.sender, "No contracts allowed");

        for (uint256 i = 0; i < miners.length; i++) {
            if (nonceFound >= minerNonces[miners[i]].start && nonceFound <= minerNonces[miners[i]].end) {
                minerNonces[miners[i]].wons += 1;
                minerNonces[miners[i]].lastWonEpoch = block.number / EPOCH_LENGTH;
                (bool sent, ) = payable(msg.sender).call{value: address(this).balance - deposited}("");
                require(sent, "Failed to send block reward");
                emit NonceFound(miners[i], nonceFound, block.number);
                break;
            }
        
        }

        if (block.number % EPOCH_LENGTH == 0) {
            recalculateRanges();
        }
    }

    /**
     * @dev Recalculates ranges based on performance (History).
     * Zero-win miners get a synthetic weight (minWins) to avoid starvation,
     * and inactive miners are removed.
     */
    function recalculateRanges() internal {
        uint256 currentEpoch = block.number / EPOCH_LENGTH;
        if (miners.length == 0) return;

        uint256 minWins = type(uint256).max;
        for (uint256 i = 0; i < miners.length; i++) {
            uint256 lastWon = minerNonces[miners[i]].lastWonEpoch;
            if (currentEpoch > lastWon && currentEpoch - lastWon > 7) {
                (bool sent, ) = payable(msg.sender).call{value: minerNonces[msg.sender].deposited - INACTIVITY_PENALTY}("");
                require(sent, "Failed to withdraw deposited funds");
                deposited -= minerNonces[miners[i]].deposited;
                delete minerNonces[miners[i]];
                delete miners[i];
                continue;
            }

            if (minerNonces[miners[i]].wons > 0 && minerNonces[miners[i]].wons < minWins) {
                minWins = minerNonces[miners[i]].wons;
            }
        }

        if (minWins == type(uint256).max || minWins == 0) {
            minWins = 1;
        }

        uint256 weightDivisor = 0;
        for (uint256 i = 0; i < miners.length; i++) {
            if (minerNonces[miners[i]].wons == 0) {
                minerNonces[miners[i]].wons = minWins;
            }

            weightDivisor += minerNonces[miners[i]].wons;
        }

        if (weightDivisor == 0) {
            weightDivisor = miners.length;
        }
        
        // Allocate ranges based on weights
        uint64 currentStart = 0;
        for (uint256 i = 0; i < miners.length; i++) {
            address mAddr = miners[i];
            uint256 weight = minerNonces[mAddr].wons;            

            minerNonces[mAddr].start = currentStart;
            
            // Last miner gets everything remaining
            if (i == miners.length - 1) {
                minerNonces[mAddr].end = TOTAL_NONCE_SPACE;
            } else {
                uint256 rangeSize = weight * (uint256(TOTAL_NONCE_SPACE) / weightDivisor);
                uint256 potentialEnd = uint256(currentStart) + rangeSize;
                
                if (potentialEnd > TOTAL_NONCE_SPACE) {
                    potentialEnd = TOTAL_NONCE_SPACE;
                }
                
                minerNonces[mAddr].end = uint64(potentialEnd);
                
                if (potentialEnd < TOTAL_NONCE_SPACE) {
                    currentStart = uint64(potentialEnd) + 1;
                }
            }
            
            // Reset wins for next epoch
            minerNonces[mAddr].wons = 0;
        }

        emit EpochRotated(block.number, miners.length);
    }
    
    // Helper to see miner range
    function nonce(address miner) external view returns (uint64, uint64) {
        require(minerNonces[miner].deposited > 0, "Miner not registered");
        return (minerNonces[miner].start, minerNonces[miner].end);
    }

    // Helper to get total number of miners
    function minersCount() external view returns (uint256) {
        return miners.length;
    }
}