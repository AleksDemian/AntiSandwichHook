// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolId, PoolKey} from "v4-core/src/types/PoolId.sol";

import {Slot0} from "v4-core/src/types/Slot0.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDeltaLibrary, BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract AntiSandwichHook is BaseHook {
    using StateLibrary for IPoolManager;

    // Структура для зберіганя стану пулу
    struct Checkpoint {
        uint32 blockNumber;
        Slot0 slot0;
        Pool.State state;
    }

    // Мапінг для зберігання останніх контрольних точок для кожного пулу
    mapping(PoolId => Checkpoint) private _lastCheckpoints;
    // Мапінг для зберігання змін в балансах пулу, які використовуються для обчислення "справедливих" змін
    mapping(PoolId => BalanceDelta) private _fairDeltas;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() 
        public 
        pure 
        virtual 
        override 
        returns (Hooks.Permissions memory) 
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true, 
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, 
            afterSwapReturnDelta: true, 
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata swapParams, 
        bytes calldata
    ) external virtual override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // Отримуємо унікальний ідентифікатор пулу
        PoolId poolId = key.toId();
        // Отримуємо останню контрольну точку для пулу
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];
        
        // Якщо поточний блок відрізняється від останнього блоку, коли була оновлена контрольна точка
        if (_lastCheckpoint.blockNumber != uint32(block.number)) {
            // Оновлюємо стан пулу з пул-менеджера
            _lastCheckpoint.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
        } else {
            // Фіксуємо поточний стан пулу, зокрема ціну
            if (!swapParams.zeroForOne) {
                _lastCheckpoint.state.slot0 = _lastCheckpoint.slot0;
            }

            // Виконуємо своп з поточним станом пулу
            (_fairDeltas[poolId],,,) = Pool.swap(
                _lastCheckpoint.state,
                Pool.SwapParams({
                    tickSpacing: key.tickSpacing,
                    zeroForOne: swapParams.zeroForOne,
                    amountSpecified: swapParams.amountSpecified,
                    sqrtPriceLimitX96: swapParams.sqrtPriceLimitX96,
                    lpFeeOverride: 0
                })
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Отримуємо поточний номер блоку
        uint32 blockNumber = uint32(block.number);
        // Отримуємо унікальний ідентифікатор пулу
        PoolId poolId = key.toId();
        // Отримуємо останню контрольну точку для пулу
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];
        
        // Якщо це перший своп у новому блоці, ініціалізуємо тимчасовий стан пулу
        if (_lastCheckpoint.blockNumber != blockNumber) {
            _lastCheckpoint.blockNumber = blockNumber;

            // Ітеруємо по тікам від початкового тіку до кінцевого
            (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
            for (int24 tick = _lastCheckpoint.slot0.tick(); tick < tickAfter; tick += key.tickSpacing) {
                (
                    uint128 liquidityGross,
                    int128 liquidityNet,
                    uint256 feeGrowthOutside0X128,
                    uint256 feeGrowthOutside1X128
                ) = poolManager.getTickInfo(poolId, tick);

                // Зберігаємо інформацію про кожен тік у контрольну точку
                _lastCheckpoint.state.ticks[tick] =
                    Pool.TickInfo(liquidityGross, liquidityNet, feeGrowthOutside0X128, feeGrowthOutside1X128);
            }

            // Глибоке копіювання лише тих значень, які змінюються і використовуються у розрахунках справедливих дельт
            _lastCheckpoint.state.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
            
            // Отримуємо глобальний ріст комісій для токенів 0 і 1
            (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = poolManager.getFeeGrowthGlobals(poolId);
            
            // Зберігаємо ці значення у контрольну точку
            _lastCheckpoint.state.feeGrowthGlobal0X128 = feeGrowthGlobal0;
            _lastCheckpoint.state.feeGrowthGlobal1X128 = feeGrowthGlobal1;
            
            // Зберігаємо загальну ліквідність пулу
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        // Отримуємо "справедливу" дельту для цього пулу
        BalanceDelta _fairDelta = _fairDeltas[poolId];

        int128 feeAmount = 0;
       
        // Якщо справедлива дельта не дорівнює нулю, перевіряємо на відповідність балансу
        if (BalanceDelta.unwrap(_fairDelta) != 0) {
            // Якщо кількість токенів 0 співпадає зі справедливою дельтою, але кількість токенів 1 збільшена
            if (delta.amount0() == _fairDelta.amount0() && delta.amount1() > _fairDelta.amount1()) {
                // Розраховуємо і відправляємо комісію в пул для токену 1
                feeAmount = delta.amount1() - _fairDelta.amount1();
                poolManager.donate(key, 0, uint256(uint128(feeAmount)), "");
            }

            // Якщо кількість токенів 1 співпадає зі справедливою дельтою, але кількість токенів 0 збільшена
            if (delta.amount1() == _fairDelta.amount1() && delta.amount0() > _fairDelta.amount0()) {
                // Розраховуємо і відправляємо комісію в пул для токену 0
                feeAmount = delta.amount0() - _fairDelta.amount0();
                poolManager.donate(key, uint256(uint128(feeAmount)), 0, "");
            }
            
            // Обнуляємо справедливу дельту після нарахування комісії
            _fairDeltas[poolId] = BalanceDelta.wrap(0);
        }

        return (this.afterSwap.selector, feeAmount);
    }
}