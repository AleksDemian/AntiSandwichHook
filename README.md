# Uniswap V4 Sandwich Attack Hook and Test Suite

This project demonstrates a **sandwich attack protection hook** for Uniswap V4. The project utilizes the Uniswap V4 protocol and Foundry framework for testing.

## Overview

A sandwich attack occurs when a malicious actor (often an MEV bot) places transactions before and after a target transaction to manipulate the price and extract value. This project implements a hook to protect against such attacks and includes test cases to verify the behavior of the system with and without the hook.

### Features

- **Anti-sandwich Hook**: A custom hook designed to detect and mitigate sandwich attacks by monitoring changes in pool balances before and after swaps.
- **Test Suite**: Comprehensive test cases to simulate both successful and failed sandwich attacks and ensure the pool behaves correctly under various conditions.
- **Uniswap V4 Integration**: Built using Uniswap V4’s core and periphery contracts to simulate realistic swap scenarios.

## Installation

To run the project, you’ll need to have **Foundry** installed. Follow the steps below to install dependencies and run tests.

### Install Foundry

If you haven't installed Foundry yet, you can install it by running:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

To install project run:
```
forge install https://github.com/AleksDemian/AntiSandwichHook
```

To run tests
```
forge test
```