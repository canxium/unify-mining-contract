// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/WorkDistribution.sol"; // Adjust path to your file

// 1. Harness to expose internal functions and fix the array bug for testing
contract MinerHarness is WorkDistribution {
    // HELPER: Manually set wins to test calculation logic without grinding
    function setWins(address miner, uint256 count) external {
        minerNonces[miner].wons = count;
    }

    // EXPOSE: Allow calling internal function from test
    function exposeRecalculateRanges() external {
        recalculateRanges();
    }
    
    // HELPER: Get array length
    function getMinersLength() external view returns (uint256) {
        return miners.length;
    }
    
    // HELPER: Set registered epoch for testing new miner logic
    function setRegisteredEpoch(address miner, uint256 epoch) external {
        minerNonces[miner].registeredEpoch = epoch;
    }
}

contract WeightedWDCMinerTest is Test {
    MinerHarness c;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    // Max uint64
    uint64 MAX_SPACE = type(uint64).max;
    
    // Events to test
    event NonceFound(address indexed miner, uint64 nonce, uint256 blockNumber);

    function setUp() public {
        c = new MinerHarness();
        
        // Fund users
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(charlie, 10000 ether);
    }

    // --- TEST 1: Equal Split (No Wins) ---
    function test_Recalculate_EqualSplit() public {
        // 1. Register 2 miners
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);

        // 2. Trigger recalculation with 0 wins
        c.exposeRecalculateRanges();

        // 3. Verify Logic: Should split 50/50
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);

        console.log("Alice Range:", aStart, aEnd);
        console.log("Bob Range:  ", bStart, bEnd);

        // Alice starts at 0
        assertEq(aStart, 0);
        
        // Bob starts right after Alice
        assertEq(bStart, aEnd + 1);
        
        // Bob ends at MAX (or extremely close due to precision)
        // With 2 miners, split is simple.
        assertApproxEqAbs(aEnd, MAX_SPACE / 2, 1); 
        assertEq(bEnd, MAX_SPACE);
    }

    // --- TEST 2: Weighted Split (Performance Based) ---
    function test_Recalculate_Weighted() public {
        // Register Alice and Bob
        vm.prank(alice);
        c.register{value: 304 ether}(alice);
        vm.prank(bob);
        c.register{value: 304 ether}(bob);

        // Scenario: Alice found 3 nonces, Bob found 1 nonce.
        // Total = 4. Alice should get 75%, Bob 25%.
        c.setWins(alice, 3);
        c.setWins(bob, 1);

        c.exposeRecalculateRanges();

        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);

        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        
        uint256 totalSpace = uint256(MAX_SPACE);

        // Check Alice ~75%
        uint256 expectedAlice = (totalSpace * 3) / 4;
        assertApproxEqRel(aliceSize, expectedAlice, 0.001e18); // 0.1% tolerance

        // Check Bob ~25%
        uint256 expectedBob = (totalSpace * 1) / 4;
        assertApproxEqRel(bobSize, expectedBob, 0.001e18);

        // Ensure continuity
        assertEq(bStart, aEnd + 1);
        assertEq(bEnd, MAX_SPACE);
    }

    // --- TEST 3: Edge Case - Single Miner ---
    function test_Recalculate_SingleMiner() public {
        vm.prank(alice);
        c.register{value: 304 ether}(alice);

        c.setWins(alice, 5); // Even with wins, if only 1 miner, they get all
        c.exposeRecalculateRanges();

        (uint64 start, uint64 end) = c.nonce(alice);
        assertEq(start, 0);
        assertEq(end, MAX_SPACE);
    }

    // --- TEST 4: Boundary & Overflow Checks ---
    function test_Recalculate_NoGaps() public {
        // Register 3 miners
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);

        // Random wins
        c.setWins(alice, 100);
        c.setWins(bob, 200);
        c.setWins(charlie, 5); // Tiny contributor

        c.exposeRecalculateRanges();

        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);

        // Chain continuity check
        // Alice -> Bob -> Charlie
        assertEq(aStart, 0);
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE); // Last one must hit the wall

        // Check that stats were reset
        ( , uint256 wonsA, , , ,) = c.minerNonces(alice);
        assertEq(wonsA, 0);
    }

    // --- TEST 5: Fuzz Testing (The Stress Test) ---
    // This generates random win counts to ensure math never reverts
    function testFuzz_Recalculate(uint8 winA, uint8 winB, uint8 winC) public {
        console.log("Fuzz Test with wins:", uint256(winA), uint256(winB), uint256(winC));
        // Avoid 0 total wins to test the weighted logic specifically
        vm.assume(uint256(winA) + winB + winC > 0);

        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);

        c.setWins(alice, winA);
        c.setWins(bob, winB);
        c.setWins(charlie, winC);

        c.exposeRecalculateRanges();

        // Just verify the chain isn't broken
        (, uint64 ae) = c.nonce(alice);
        (uint64 bs, uint64 be) = c.nonce(bob);
        (uint64 cs, uint64 ce) = c.nonce(charlie);

        assertEq(bs, ae + 1, "Gap between A and B");
        assertEq(cs, be + 1, "Gap between B and C");
        
        // Note: In some rare math edge cases with integer division, 
        // the last miner might catch the remainder. 
        // We just ensure it doesn't overflow or revert.
        assertEq(ce, MAX_SPACE, "Last miner didn't finish space");
    }

    // --- TEST 6: All Miners Have Wins (No Zero-Win Miners) ---
    function test_Recalculate_AllHaveWins() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        
        c.setWins(alice, 10);
        c.setWins(bob, 5);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        
        // Alice should get ~66.67%, Bob ~33.33%
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        
        assertApproxEqRel(aliceSize * 3, bobSize * 6, 0.001e18); // 2:1 ratio
        assertEq(bStart, aEnd + 1);
        assertEq(bEnd, MAX_SPACE);
    }

    // --- TEST 7: One Winner, Others Zero ---
    function test_Recalculate_OneWinnerRestZero() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);
        
        c.setWins(alice, 100); // Only Alice performed
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        
        // Bob and Charlie (zero-win miners) get full minWins (100)
        // Total weight = 100 (alice) + 100 (bob) + 100 (charlie) = 300
        // Each should get ~33.33%
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        
        // All three should have roughly equal space
        assertApproxEqRel(aliceSize, bobSize, 0.05e18); // 5% tolerance
        assertApproxEqRel(bobSize, charlieSize, 0.05e18);
        
        // Chain continuity
        assertEq(aStart, 0);
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE);
    }

    // --- TEST 8: Very Small Win Count (1 total win) ---
    function test_Recalculate_SingleWin() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        
        c.setWins(alice, 1);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        
        // Bob (zero-win miner) gets full minWins (1)
        // Total weight = 1 (alice) + 1 (bob) = 2
        // Both should have roughly equal space (50/50)
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        
        assertApproxEqRel(aliceSize, bobSize, 0.05e18);
        assertEq(bStart, aEnd + 1);
        assertEq(bEnd, MAX_SPACE);
    }

    // --- TEST 9: Mix of Zero and Non-Zero Wins ---
    function test_Recalculate_MixedPerformance() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);
        
        c.setWins(alice, 50);
        c.setWins(bob, 0);
        c.setWins(charlie, 50);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        
        // Bob (zero-win miner) gets full minWins (50)
        // Total weight = 50 (alice) + 50 (bob) + 50 (charlie) = 150
        // All three should get ~33.33%
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        
        // All should have roughly equal space
        assertApproxEqRel(aliceSize, bobSize, 0.05e18);
        assertApproxEqRel(aliceSize, charlieSize, 0.05e18); // 5% tolerance
        
        // Chain continuity
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE);
    }

    // --- TEST 10: Two Miners, One with Zero ---
    function test_Recalculate_TwoMinersOneZero() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        
        c.setWins(alice, 90);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        
        // Bob (zero-win miner) gets full minWins (90)
        // Total weight = 90 (alice) + 90 (bob) = 180
        // Both should get ~50%
        assertApproxEqRel(aliceSize, bobSize, 0.05e18); // 5% tolerance
        
        assertEq(bStart, aEnd + 1);
        assertEq(bEnd, MAX_SPACE);
    }

    // --- TEST 10b: Multiple Zero-Win Miners ---
    function test_Recalculate_MultipleZeroWin() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);
        
        c.setWins(alice, 90);
        // Bob and Charlie have 0 wins
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        
        // Bob and Charlie (zero-win miners) get full minWins (90)
        // Total weight = 90 (alice) + 90 (bob) + 90 (charlie) = 270
        // All should get ~33.33%
        assertApproxEqRel(aliceSize, bobSize, 0.05e18);
        assertApproxEqRel(bobSize, charlieSize, 0.05e18);
        
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE);
    }

    // --- TEST 11: Very Unbalanced Wins ---
    function test_Recalculate_VeryUnbalanced() public {
        vm.prank(alice); c.register{value: 304 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 304 ether}(charlie);
        
        c.setWins(alice, 200);
        c.setWins(bob, 5);
        c.setWins(charlie, 1);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        
        // Alice should dominate
        assertGt(aliceSize, bobSize * 10);
        assertGt(aliceSize, charlieSize * 10);
        
        // Bob should have more than Charlie
        assertGt(bobSize, charlieSize);
        
        // Chain continuity
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE);
    }

    // --- TEST 12: Large Scale - 100 Miners ---
    function test_Recalculate_100Miners() public {
        address[] memory testMiners = new address[](100);
        
        // Register 100 miners
        for (uint256 i = 0; i < 100; i++) {
            testMiners[i] = makeAddr(string(abi.encodePacked("miner", i)));
            vm.deal(testMiners[i], 10000 ether);
            
            // Calculate required deposit: (MIN_DEPOSIT * (miners.length + 1) * 23053) / 5000000
            uint256 minerCount = i; // Current number of miners before this one
            uint256 required = (303 ether * (minerCount + 1) * 23053) / 5000000;
            
            vm.prank(testMiners[i]);
            c.register{value: required}(testMiners[i]);
            
            // Assign random wins 0-2 (using pseudo-random based on index)
            uint256 wins = i % 3; // 0, 1, or 2
            if (wins > 0) {
                c.setWins(testMiners[i], wins);
            }
        }
        
        c.exposeRecalculateRanges();
        
        // Verify chain continuity and no gaps
        uint64 prevEnd = 0;
        for (uint256 i = 0; i < 100; i++) {
            (uint64 start, uint64 end) = c.nonce(testMiners[i]);
            
            if (i == 0) {
                assertEq(start, 0, "First miner should start at 0");
            } else {
                assertEq(start, prevEnd + 1, "Gap detected");
            }
            
            assertGt(end, start, "Invalid range");
            prevEnd = end;
        }
        
        assertEq(prevEnd, MAX_SPACE, "Last miner must reach MAX_SPACE");
    }

    // --- TEST 13: Large Scale - 500 Miners ---
    function test_Recalculate_500Miners() public {
        address[] memory testMiners = new address[](500);
        uint256 totalWins = 0;
        
        // Register 500 miners
        for (uint256 i = 0; i < 500; i++) {
            testMiners[i] = makeAddr(string(abi.encodePacked("miner", i)));
            vm.deal(testMiners[i], 100000 ether);
            
            // Calculate required deposit
            uint256 minerCount = i;
            uint256 required = (303 ether * (minerCount + 1) * 23053) / 5000000;
            
            vm.prank(testMiners[i]);
            c.register{value: required}(testMiners[i]);
            
            // Assign wins ensuring total <= 2048
            uint256 wins = (i * 7) % 3; // 0, 1, or 2 with different distribution
            if (totalWins + wins <= 2048) {
                if (wins > 0) {
                    c.setWins(testMiners[i], wins);
                    totalWins += wins;
                }
            }
        }
        
        console.log("500 miners test - Total wins:", totalWins);
        
        c.exposeRecalculateRanges();
        
        // Verify chain continuity
        uint64 prevEnd = 0;
        for (uint256 i = 0; i < 500; i++) {
            (uint64 start, uint64 end) = c.nonce(testMiners[i]);
            
            if (i == 0) {
                assertEq(start, 0, "First miner should start at 0");
            } else {
                assertEq(start, prevEnd + 1, "Gap detected");
            }
            
            assertGt(end, start, "Invalid range");
            prevEnd = end;
        }
        
        assertEq(prevEnd, MAX_SPACE, "Last miner must reach MAX_SPACE");
    }

    // --- TEST 14: Large Scale - 1000 Miners ---
    function test_Recalculate_1000Miners() public {
        address[] memory testMiners = new address[](1000);
        uint256 totalWins = 0;
        
        // Register 1000 miners
        for (uint256 i = 0; i < 1000; i++) {
            testMiners[i] = makeAddr(string(abi.encodePacked("miner", i)));
            vm.deal(testMiners[i], 200000 ether);
            
            // Calculate required deposit
            uint256 minerCount = i;
            uint256 required = (303 ether * (minerCount + 1) * 23053) / 5000000;
            
            vm.prank(testMiners[i]);
            c.register{value: required}(testMiners[i]);
            
            // Assign wins ensuring total <= 2048
            // Pattern: roughly 50% get 0, 25% get 1, 25% get 2
            uint256 wins;
            if (i % 4 == 0 || i % 4 == 1) {
                wins = 0;
            } else if (i % 4 == 2) {
                wins = 1;
            } else {
                wins = 2;
            }
            
            if (totalWins + wins <= 2048) {
                if (wins > 0) {
                    c.setWins(testMiners[i], wins);
                    totalWins += wins;
                }
            } else {
                break; // Stop adding wins once we hit the limit
            }
        }
        
        console.log("1000 miners test - Total wins:", totalWins);
        
        c.exposeRecalculateRanges();
        
        // Verify chain continuity and space allocation
        uint64 prevEnd = 0;
        uint256 zeroSpaceCount = 0;
        
        for (uint256 i = 0; i < 1000; i++) {
            (uint64 start, uint64 end) = c.nonce(testMiners[i]);
            
            if (i == 0) {
                assertEq(start, 0, "First miner should start at 0");
            } else {
                assertEq(start, prevEnd + 1, "Gap detected");
            }
            
            uint256 rangeSize = uint256(end) - uint256(start);
            if (rangeSize == 0) {
                zeroSpaceCount++;
            }
            
            assertGt(end, start, "Invalid range");
            prevEnd = end;
        }
        
        assertEq(prevEnd, MAX_SPACE, "Last miner must reach MAX_SPACE");
        console.log("Miners with zero space:", zeroSpaceCount);
        assertEq(zeroSpaceCount, 0, "No miner should have zero space");
    }

    // --- TEST 15: Large Scale - Edge Case with Max Wins ---
    function test_Recalculate_MaxWinsDistribution() public {
        address[] memory testMiners = new address[](1024);
        
        // Register 1024 miners, each gets exactly 2 wins (total = 2048)
        for (uint256 i = 0; i < 1024; i++) {
            testMiners[i] = makeAddr(string(abi.encodePacked("miner", i)));
            vm.deal(testMiners[i], 200000 ether);
            
            // Calculate required deposit
            uint256 minerCount = i;
            uint256 required = (303 ether * (minerCount + 1) * 23053) / 5000000;
            
            vm.prank(testMiners[i]);
            c.register{value: required}(testMiners[i]);
            c.setWins(testMiners[i], 2);
        }
        
        console.log("Max wins test - 1024 miners * 2 wins = 2048 total");
        
        c.exposeRecalculateRanges();
        
        // Verify equal distribution (all have same wins)
        uint64 prevEnd = 0;
        uint256 firstRange = 0;
        
        for (uint256 i = 0; i < 1024; i++) {
            (uint64 start, uint64 end) = c.nonce(testMiners[i]);
            
            uint256 rangeSize = uint256(end) - uint256(start);
            
            if (i == 0) {
                firstRange = rangeSize;
            } else if (i < 1023) {
                // All non-last miners should have roughly equal space
                assertApproxEqAbs(rangeSize, firstRange, firstRange / 10); // 10% tolerance
            }
            
            if (i > 0) {
                assertEq(start, prevEnd + 1, "Gap detected");
            }
            
            prevEnd = end;
        }
        
        assertEq(prevEnd, MAX_SPACE, "Last miner must reach MAX_SPACE");
    }

    // ==================== EXIT FUNCTION TESTS ====================

    // --- TEST 16: Basic Exit ---
    function test_Exit_Basic() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        // Advance to next epoch (must wait one epoch before exit)
        vm.roll(86400);
        
        uint256 balanceBefore = alice.balance;
        
        vm.prank(alice);
        c.exit();
        
        // Should get deposit back
        assertEq(alice.balance, balanceBefore + 303 ether);
        
        // State should be cleaned
        (uint256 deposited, , , , ,) = c.minerNonces(alice);
        assertEq(deposited, 0);
    }

    // --- TEST 17: Exit Not Registered ---
    function test_Exit_NotRegistered() public {
        vm.prank(alice);
        vm.expectRevert("Not registered");
        c.exit();
    }

    // --- TEST 17b: Exit in Same Epoch ---
    function test_Exit_SameEpoch() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        // Try to exit immediately (same epoch)
        vm.prank(alice);
        vm.expectRevert("Cannot exit in same epoch");
        c.exit();
    }

    // --- TEST 18: Exit and Re-register ---
    function test_Exit_AndReregister() public {
        // First registration at epoch 0
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        // Advance to next epoch
        vm.roll(86400);
        
        // Exit
        vm.prank(alice);
        c.exit();
        
        // Should be able to register again
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        (uint256 deposited, , , , ,) = c.minerNonces(alice);
        assertEq(deposited, 303 ether);
    }

    // --- TEST 19: Exit Multiple Miners ---
    function test_Exit_MultipleMiners() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);
        
        vm.prank(charlie);
        c.register{value: 305 ether}(charlie);
        
        // Advance to next epoch
        vm.roll(86400);
        
        // Bob exits
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        c.exit();
        
        assertEq(bob.balance, bobBalanceBefore + 304 ether);
        
        // Alice and Charlie should still be registered
        (uint256 aliceDeposit, , , , ,) = c.minerNonces(alice);
        (uint256 charlieDeposit, , , , ,) = c.minerNonces(charlie);
        assertEq(aliceDeposit, 303 ether);
        assertEq(charlieDeposit, 305 ether);
    }

    // ==================== MINED FUNCTION TESTS ====================

    // --- TEST 20: Basic Mined with Valid Nonce ---
    function test_Mined_ValidNonce() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);
        
        // Trigger recalculation to assign ranges
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        
        // Fund the contract with block reward
        vm.deal(address(c), 607 ether + 5 ether); // deposits + reward
        
        uint256 minerBalanceBefore = alice.balance;
        
        // Alice submits a nonce in her range
        vm.prank(alice, alice);
        c.mined(aStart);
        
        // Alice should receive the reward (5 ether)
        assertEq(alice.balance, minerBalanceBefore + 5 ether);
        
        // Check wins were incremented
        (, uint256 wins, , , ,) = c.minerNonces(alice);
        assertEq(wins, 1);
    }

    // --- TEST 22: Multiple Miners Submit Nonces ---
    function test_Mined_MultipleMiners() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, ) = c.nonce(alice);
        (uint64 bStart, ) = c.nonce(bob);
        
        // Fund contract with multiple rewards
        vm.deal(address(c), 607 ether + 10 ether);
        
        // Alice submits
        vm.prank(alice, alice);
        c.mined(aStart);
        
        // Bob submits
        vm.prank(bob, bob);
        c.mined(bStart);
        
        // Check both have wins
        (, uint256 aliceWins, , , ,) = c.minerNonces(alice);
        (, uint256 bobWins, , , ,) = c.minerNonces(bob);
        
        assertEq(aliceWins, 1);
        assertEq(bobWins, 1);
    }

    // --- TEST 23: Mined Triggers Epoch Rotation ---
    function test_Mined_EpochRotation() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);
        

        console.log("Advancing to epoch boundary...");

        c.exposeRecalculateRanges();
        
        (uint64 aStart, ) = c.nonce(alice);

        console.log("Advancing to epoch boundary...");
        console.log("Alice nonce start:", aStart);
        
        // Set wins before epoch rotation
        c.setWins(alice, 10);
        c.setWins(bob, 5);
        
        // Fast forward to epoch boundary (block number % 2048 == 0)
        vm.roll(86400);
        
        vm.deal(address(c), 607 ether + 5 ether);
        
        // This should trigger recalculation
        vm.prank(alice, alice);
        c.mined(aStart);
        
        // After recalculation, wins should be reset
        (, uint256 aliceWins, , , ,) = c.minerNonces(alice);
        (, uint256 bobWins, , , ,) = c.minerNonces(bob);
        
        assertEq(aliceWins, 0, "Alice wins should be reset");
        assertEq(bobWins, 0, "Bob wins should be reset");
    }

    // --- TEST 24: Mined Rewards Distribution ---
    function test_Mined_RewardsCorrect() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, ) = c.nonce(alice);
        
        uint256 totalDeposits = 303 ether;
        uint256 blockReward = 7.5 ether;
        
        // Fund contract: deposits + reward
        vm.deal(address(c), totalDeposits + blockReward);
        
        uint256 minerBalanceBefore = alice.balance;
        
        vm.prank(alice, alice);
        c.mined(aStart);
        
        // Miner should get exactly the reward (balance - deposited)
        assertEq(alice.balance, minerBalanceBefore + blockReward);
        
        // Contract should only have deposits left
        assertEq(address(c).balance, totalDeposits);
    }

    // --- TEST 25: Mined with Same Nonce by Different Miners ---
    function test_Mined_SameNonceDifferentMiners() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        vm.prank(bob);
        c.register{value: 304 ether}(bob);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, ) = c.nonce(alice);
        
        vm.deal(address(c), 607 ether + 10 ether);
        
        // Alice submits nonce in her range
        vm.prank(alice, alice);
        c.mined(aStart);
        
        // Bob tries to submit the same nonce (it's in Alice's range)
        vm.prank(bob, bob);
        c.mined(aStart);
        
        // Alice should have 2 wins (both submissions found her range)
        (, uint256 aliceWins, , , ,) = c.minerNonces(alice);
        (, uint256 bobWins, , , ,) = c.minerNonces(bob);
        
        assertEq(aliceWins, 2, "Alice owns this nonce range");
        assertEq(bobWins, 0, "Bob doesn't own this nonce");
    }

    // --- TEST 26: Mined Event Emission ---
    function test_Mined_EventEmitted() public {
        vm.prank(alice);
        c.register{value: 303 ether}(alice);
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, ) = c.nonce(alice);
        
        vm.deal(address(c), 303 ether + 5 ether);
        
        // Expect the NonceFound event to be emitted
        vm.expectEmit(true, false, false, true);
        emit NonceFound(alice, aStart, block.number);
        
        vm.prank(alice, alice);
        c.mined(aStart);
    }

    // ==================== NEW ALGORITHM TESTS ====================

    // --- TEST 27: Four Miners with Varied Performance ---
    function test_FourMinersVariedPerformance() public {
        address dave = makeAddr("dave");
        vm.deal(dave, 10000 ether);
        
        vm.prank(alice); c.register{value: 303 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 305 ether}(charlie);
        vm.prank(dave); c.register{value: 306 ether}(dave);
        
        // Give them wins
        c.setWins(alice, 50);
        c.setWins(bob, 30);
        c.setWins(charlie, 20);
        // Dave has 0 wins
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        (uint64 dStart, uint64 dEnd) = c.nonce(dave);
        
        // Dave (zero-win miner) gets full minWins (20)
        // Total weight = 50 + 30 + 20 + 20 = 120
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 daveSize = uint256(dEnd) - uint256(dStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        
        // Dave and Charlie should have equal space (both have weight 20)
        assertApproxEqRel(daveSize, charlieSize, 0.05e18);
        
        // Alice should have more than Dave
        assertGt(aliceSize, daveSize);
        
        // Chain continuity
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(dStart, cEnd + 1);
        assertEq(dEnd, MAX_SPACE);
    }

    // --- TEST 28: Zero-Win Miner Gets Full MinWins ---
    function test_ZeroWinMinerGetsMinWins() public {
        vm.prank(alice); c.register{value: 303 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 305 ether}(charlie);
        
        // Alice: 10 wins, Bob: 20 wins, Charlie: 0 wins
        c.setWins(alice, 10);
        c.setWins(bob, 20);
        // Charlie has 0 wins
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        
        // Min wins = 10 (Alice)
        // Charlie (zero-win) gets full minWins = 10
        // Total weight = 10 + 20 + 10 = 40
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        
        // Alice and Charlie should have equal space (both 10)
        assertApproxEqRel(aliceSize, charlieSize, 0.05e18);
        // Bob has 2x Alice
        assertApproxEqRel(bobSize, aliceSize * 2, 0.05e18);
        
        // Chain continuity
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(cEnd, MAX_SPACE);
    }

    // --- TEST 29: Multiple Zero-Win Miners All Get MinWins ---
    function test_MultipleZeroWinMinersGetMinWins() public {
        address dave = makeAddr("dave");
        vm.deal(dave, 10000 ether);
        
        vm.prank(alice); c.register{value: 303 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 305 ether}(charlie);
        vm.prank(dave); c.register{value: 306 ether}(dave);
        
        c.setWins(alice, 100);
        // Bob, Charlie, Dave have 0 wins
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        (uint64 dStart, uint64 dEnd) = c.nonce(dave);
        
        // All zero-win miners get full minWins (100)
        // Total weight = 100 + 100 + 100 + 100 = 400
        // All should get 25%
        
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        uint256 daveSize = uint256(dEnd) - uint256(dStart);
        
        // All should have equal space
        assertApproxEqRel(aliceSize, bobSize, 0.05e18);
        assertApproxEqRel(bobSize, charlieSize, 0.05e18);
        assertApproxEqRel(charlieSize, daveSize, 0.05e18);
        
        // Chain continuity
        assertEq(bStart, aEnd + 1);
        assertEq(cStart, bEnd + 1);
        assertEq(dStart, cEnd + 1);
        assertEq(dEnd, MAX_SPACE);
    }

    // --- TEST 30: Five Miners - One with Wins, Four Zero-Win ---
    function test_FiveMinersOneWinnerFourZero() public {
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        vm.deal(dave, 10000 ether);
        vm.deal(eve, 10000 ether);
        
        vm.prank(alice); c.register{value: 303 ether}(alice);
        vm.prank(bob);   c.register{value: 304 ether}(bob);
        vm.prank(charlie); c.register{value: 305 ether}(charlie);
        vm.prank(dave); c.register{value: 306 ether}(dave);
        vm.prank(eve); c.register{value: 307 ether}(eve);
        
        c.setWins(alice, 90);
        // Bob, Charlie, Dave, Eve have 0 wins
        
        c.exposeRecalculateRanges();
        
        (uint64 aStart, uint64 aEnd) = c.nonce(alice);
        (uint64 bStart, uint64 bEnd) = c.nonce(bob);
        (uint64 cStart, uint64 cEnd) = c.nonce(charlie);
        (uint64 dStart, uint64 dEnd) = c.nonce(dave);
        (uint64 eStart, uint64 eEnd) = c.nonce(eve);

        // All zero-win miners get full minWins (90)
        // Total weight = 90 + 90 + 90 + 90 + 90 = 450
        // Each gets 90/450 = 20%
        
        uint256 aliceSize = uint256(aEnd) - uint256(aStart);
        uint256 bobSize = uint256(bEnd) - uint256(bStart);
        uint256 charlieSize = uint256(cEnd) - uint256(cStart);
        uint256 daveSize = uint256(dEnd) - uint256(dStart);
        uint256 eveSize = uint256(eEnd) - uint256(eStart);
        
        // All miners should have similar space
        assertApproxEqRel(aliceSize, bobSize, 0.05e18);
        assertApproxEqRel(bobSize, charlieSize, 0.05e18);
        assertApproxEqRel(charlieSize, daveSize, 0.05e18);
        assertApproxEqRel(daveSize, eveSize, 0.05e18);
        
        uint256 totalSpace = aliceSize + bobSize + charlieSize + daveSize + eveSize;
        assertApproxEqRel(totalSpace, uint256(MAX_SPACE), 0.01e18);
        
        // Chain continuity
        assertEq(eEnd, MAX_SPACE);
    }
}