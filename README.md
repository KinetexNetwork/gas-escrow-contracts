# Kinetex Gas Escrow

Kinetex Gas Escrow smart contracts

## Description

Kinetex Gas Escrow allows user to borrow gas in a network using their deposit in other
(or even the same) network. The borrowed amount is then repaid by user back to the gas
provider. Borrow can be liquidated with deposit lost for user if repay time missed or
deposited assets dropped cost below agreed threshold.

There are two primary contracts and three auxiliary in Gas Escrow:

[__contracts/GasProvider.sol__](contracts/GasProvider.sol)

Contract for lending gas to user. Gas provider calls `lendGas` method, user repays via `repayGas`.
Gas borrow can be liquidated if repay time has passed (`liquidateByTime`) or deposited assets
dropped in cost too much (`liquidateByCost`).

[__contracts/GasInsurer.sol__](contracts/GasInsurer.sol)

Contract for accepting user deposits (`deposit` method). Contract supports withdraw of deposited
assets implemented as two-step operation (`initiateWithdraw`, `proceedWithdraw`, `cancelWithdraw`)
for safety reasons. Contract has `liquidate` method for slashing deposits used by liquidated borrows.

[__contracts/ProoferRegistry.sol__](contracts/ProoferRegistry.sol)

Whitelist of contract addresses who can be a source of proof for a Gas Escrow method.
Owner can approve (`approveProofer`) or revoke (`revokeProofer`) addresses.

[__contracts/ProofValidator.sol__](contracts/ProofValidator.sol)

Validator of blockchain state proofs based on multi-sig. Owner can regulate valid signer
addresses and their required number via `approveSigner`, `revokeSigner`, and `setThreshold`.

[__contracts/TrackerRegistry.sol__](contracts/TrackerRegistry.sol)

Registry of token trackers that provides asset rates and costs. For each asset tracker address
can be set up (`setTracker`/`unsetTracker`) and asset decimals override (`setDecimals`/`unsetDecimals`).

## Development

This project uses the following stack:

- Language: Solidity v0.8.16
- Framework: Hardhat
- Node.js: v18
- Yarn: v1.22

### Setup Environment

1. Ensure you have relevant Node.js version. For NVM: `nvm use`

2. Install dependencies: `yarn install`

3. Setup environment variables:

    * Clone variables example file: `cp .env.example .env`
    * Edit `.env` according to your needs

### Development Commands

Below is the list of commands executed via `yarn` with their descriptions:

 Command                | Alias            | Description
------------------------|------------------|------------
 `yarn hardhat`         | `yarn h`         | Call [`hardhat`](https://hardhat.org/) CLI
 `yarn build`           | `yarn b`         | Compile contracts (puts to `artifacts` folder)
 `yarn prettify`        | `yarn p`         | Format code of contracts in `contracts` folder

## Licensing

The primary license for Kinetex Gas Escrow is the Business Source License 1.1 (`BUSL-1.1`), see [`LICENSE`](./LICENSE).
However, some files are dual licensed under `GPL-2.0-or-later`:

- Several files in `contracts/` may also be licensed under `GPL-2.0-or-later` (as indicated in their SPDX headers),
  see [`LICENSE_GPL2`](./LICENSE_GPL2)

### Other Exceptions

- All `@openzeppelin` and `@chainlink` library files are licensed under `MIT` (as indicated in its SPDX header),
  see [`LICENSE_MIT`](./LICENSE_MIT)
