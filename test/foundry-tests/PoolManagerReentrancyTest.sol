// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Currency, CurrencyLibrary} from "../../contracts/libraries/CurrencyLibrary.sol";
import {IPoolManager} from "../../contracts/interfaces/IPoolManager.sol";
import {ILockCallback} from "../../contracts/interfaces/callback/ILockCallback.sol";
import {PoolManager} from "../../contracts/PoolManager.sol";
import {Deployers} from "./utils/Deployers.sol";
import {TokenFixture} from "./utils/TokenFixture.sol";

contract TokenLocker is ILockCallback {
    using CurrencyLibrary for Currency;

    function main(IPoolManager manager, Currency currency, bool reclaim) external {
        manager.lock(abi.encode(currency, reclaim));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (Currency currency, bool reclaim) = abi.decode(data, (Currency, bool));

        IPoolManager manager = IPoolManager(msg.sender);

        assert(manager.nonzeroDeltaCount() == 0);

        int256 delta = manager.currencyDelta(address(this), currency);
        assert(delta == 0);

        // deposit some tokens
        currency.transfer(address(manager), 1);
        manager.settle(currency);
        assert(manager.nonzeroDeltaCount() == 1);
        delta = manager.currencyDelta(address(this), currency);
        assert(delta == -1);

        // take them back
        if (reclaim) {
            manager.take(currency, address(this), 1);
            assert(manager.nonzeroDeltaCount() == 0);
            delta = manager.currencyDelta(address(this), currency);
            assert(delta == 0);
        }

        return "";
    }
}

contract SimpleLinearLocker is ILockCallback {
    function(uint256) external checker;

    function main(IPoolManager manager, uint256 timesToReenter, function(uint256) external checker_) external {
        checker = checker_;
        manager.lock(abi.encode(timesToReenter, 0));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (uint256 timesToReenter, uint256 depth) = abi.decode(data, (uint256, uint256));
        checker(depth);
        if (depth < timesToReenter) {
            IPoolManager manager = IPoolManager(msg.sender);
            manager.lock(abi.encode(timesToReenter, depth + 1));
        }
        return "";
    }
}

contract ParallelLocker is ILockCallback {
    IPoolManager manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function main() external {
        manager.lock("");
    }

    function checker0(uint256) external view {
        assert(manager.locksLength() == 2);
        assert(manager.lockIndex() == 1);
        (address locker, uint96 parentLockIndex) = manager.locks(1);
        assert(locker == msg.sender);
        assert(parentLockIndex == 0);
    }

    function checker1(uint256 depth) external view {
        assert(manager.locksLength() == depth + 3);
        assert(manager.lockIndex() == depth + 2);
        (address locker, uint96 parentLockIndex) = manager.locks(depth + 2);
        assert(locker == msg.sender);
        if (depth == 0) assert(parentLockIndex == 0);
        else assert(parentLockIndex == depth + 1);
    }

    function checker2(uint256) external view {
        assert(manager.locksLength() == 5);
        assert(manager.lockIndex() == 4);
        (address locker, uint96 parentLockIndex) = manager.locks(4);
        assert(locker == msg.sender);
        assert(parentLockIndex == 0);
    }

    function lockAcquired(bytes calldata) external returns (bytes memory) {
        SimpleLinearLocker locker0 = new SimpleLinearLocker();
        SimpleLinearLocker locker1 = new SimpleLinearLocker();
        SimpleLinearLocker locker2 = new SimpleLinearLocker();

        assert(manager.locksLength() == 1);
        assert(manager.lockIndex() == 0);
        (address locker,) = manager.locks(0);
        assert(locker == address(this));

        locker0.main(manager, 0, this.checker0);
        assert(manager.locksLength() == 2);
        assert(manager.lockIndex() == 0);

        locker1.main(manager, 1, this.checker1);
        assert(manager.locksLength() == 4);
        assert(manager.lockIndex() == 0);

        locker2.main(manager, 0, this.checker2);
        assert(manager.locksLength() == 5);
        assert(manager.lockIndex() == 0);

        return "";
    }
}

contract PoolManagerReentrancyTest is Test, Deployers, TokenFixture {
    PoolManager manager;

    function setUp() public {
        initializeTokens();
        manager = Deployers.createFreshManager();
    }

    function testTokenLocker() public {
        TokenLocker locker = new TokenLocker();
        MockERC20(Currency.unwrap(currency0)).mint(address(locker), 1);
        MockERC20(Currency.unwrap(currency0)).approve(address(locker), 1);
        locker.main(manager, currency0, true);
    }

    function testTokenRevert() public {
        TokenLocker locker = new TokenLocker();
        MockERC20(Currency.unwrap(currency0)).mint(address(locker), 1);
        MockERC20(Currency.unwrap(currency0)).approve(address(locker), 1);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrencyNotSettled.selector));
        locker.main(manager, currency0, false);
    }

    function checker(uint256 depth) external {
        assertEq(manager.locksLength(), depth + 1);
        assertEq(manager.lockIndex(), depth);
        (address locker, uint96 parentLockIndex) = manager.locks(depth);
        assertEq(locker, msg.sender);
        assertEq(parentLockIndex, depth == 0 ? 0 : depth - 1);
    }

    function testSimpleLinearLocker() public {
        SimpleLinearLocker locker = new SimpleLinearLocker();
        locker.main(manager, 0, this.checker);
        locker.main(manager, 1, this.checker);
        locker.main(manager, 2, this.checker);
    }

    function testParallelLocker() public {
        ParallelLocker locker = new ParallelLocker(manager);
        locker.main();
    }
}
