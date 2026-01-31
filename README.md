# Canxium Work Distribution Contract (WDC)

The **Work Distribution Contract (WDC)** is the heart of Canxium's **PoW 2.0 (Cooperative Consensus Protocol)**.

Unlike traditional Proof-of-Work where miners compete for the same solution, the WDC acts as a decentralized registrar that partitions the global nonce space () among active miners. This enables **Zero-Latency Mining** and mathematically eliminates race conditions (orphaned blocks) by assigning exclusive search ranges to every participant.

## Key Architecture

### 1. Cooperative Consensus (The "N+2" Pipeline)

This contract facilitates a pipelined consensus mechanism:

* **Registration:** Miners deposit CAU to register.
* **Partitioning:** The contract assigns a unique `[start, end]` nonce range to each miner based on their historical performance and stake.
* **Validation:** The Consensus Engine reads this contract's storage to verify that a block's nonce falls within the miner's assigned range.

### 2. System Integration

This is **not** a standard dApp contract. It is a **System Contract** embedded in the genesis block.

* **Address:** `0x0000000000000000000000000000000000003003`
* **Chain ID:** `3003`

### 3. The "System Transaction"

Block rewards in PoW 2.0 are **lagged**. The reward for Block `N-1` is distributed in Block `N` via a synthetic transaction.

* **Trigger:** The consensus engine automatically injects a transaction at the end of every block.
* **Sender:** `0xfffffffffffffffffffffffffffffffffffffffe` (System Sender).
* **Method:** Calls `mined(address miner, uint64 nonce)`.
* **Security:** This function is restricted to the System Sender only.

## 📂 Contract Storage Layout (CRITICAL)

The `go-canxium` consensus engine reads the **Raw Storage** of this contract directly from the `StateDB` to avoid EVM overhead during header verification.

**⚠️ WARNING: Do not change the order of variables in `WeightedWDCMiner.sol` without updating the consensus engine code.**

| Slot Index | Variable | Type | Description |
| --- | --- | --- | --- |
| **0** | `deposited` | `uint256` | Total CAU locked in contract. |
| **1** | `miners` | `address[]` | Dynamic array of registered miners. |
| **2** | `minerNonces` | `mapping` | **Primary Lookup.** Map `address => MinerNonces`. |
| **3** | `minWinsInEpoch` | `uint256` | Protocol parameter. |

### `MinerNonces` Struct Packing

Inside Slot 2 (the mapping), the struct is packed as follows:

* **Slot Base + 0:** `deposited` (uint256)
* **Slot Base + 1:** `wons` (uint256)
* **Slot Base + 2:** `[ ... unused ... | end (uint64) | start (uint64) ]`
* *Start:* Bits 0-63
* *End:* Bits 64-127

---

## 🛠 Development & Testing

This project uses **[Foundry](https://book.getfoundry.sh/)** for compilation and testing.

### Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup

```

### Installation

```bash
git clone https://github.com/canxium/wdc-contract.git
cd wdc-contract
forge install

```

### Running Tests

The test suite includes fuzzing to ensure the mathematical partitioning never leaves gaps or overlaps in the nonce space.

```bash
# Run all tests
forge test -vv

# Run fuzz tests for the recalculation logic
forge test --match-test testFuzz_Recalculate

```

### Compilation for Genesis

To generate the bytecode for `genesis.json`:

```bash
# Compile and output the binary
solc --bin --optimize --optimize-runs=200 src/WeightedWDCMiner.sol

```

Copy the output hex string into the `alloc` section of your genesis file.

---

## 📜 Contract Interface

### For Miners

#### `register()`

To join the network, send a transaction with at least `303 CAU`.

```solidity
function register() external payable;

```

#### `exit()`

To leave the network and withdraw your deposit.

```solidity
function exit() external;

```

#### `nonce(address miner)`

View function to check your assigned mining range.

```solidity
function nonce(address miner) external view returns (uint64 start, uint64 end);

```

### For Consensus (System Only)

#### `mined(address miner, uint64 nonce)`

Called by the system to report a valid block found by `miner`.

* **Access Control:** `msg.sender == SYSTEM_SENDER`
* **Effect:** Distributes reward to `miner` and increments their `wons` counter.

---

## ⚠️ Deployment Notes

1. **Genesis Injection:** This contract MUST be deployed at block 0 via the genesis `alloc` map.
2. **No Constructor Parameters:** The contract logic assumes it starts fresh. Do not attempt to pass arguments during genesis injection.
3. **Address Check:** Ensure the address matches the hardcoded constant in `go-canxium/core/wdc_constants.go`.

---

## License

MIT