## LOGIC

The repository contains two methods for implementing Scalable Reward Distribution with Compounding Stakes:

1. Liquity Stability Pool Fork: This contract is a fork of the Liquity Stability Pool, adhering closely to the rules and patterns outlined in the https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf whitepaper.

Users can deposit staking tokens into the vault/contract, which can be integrated with a yield source. When a liquidation occurs, the total staked tokens in the vault decrease, but this loss is proportionally distributed among all stakers. Similarly, any reward tokens are distributed proportionally among the stakers.


2. Simple ERC4626 Vault: This is a basic ERC4626 vault implementation where users can deposit underlying assets in exchange for corresponding shares.

The vault can be integrated with a yield source, allowing users to earn yield. If a liquidation occurs, the underlying assets decrease, which automatically propagates to the shareholders. Additionally, collateral obtained from the liquidation can be distributed proportionally, similar to the reward distribution mechanism in Sushi's MasterChef contract. This approach is straightforward and simple.




Note: Both contracts are provided for showcasing the logic. There may be issues as I am still working on unit testing and refactoring some logic components.

Repository Status: In Progress

TODO

- Add NatSpec comments
- Correct decimal scaling and adjustments
- Complete unit testing
- Perform integration testing
- Improve documentation



## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
