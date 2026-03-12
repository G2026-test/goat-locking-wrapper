// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ValidatorEntryUpgradeable} from "src/ValidatorEntryUpgradeable.sol";
import {IncentivePool} from "src/IncentivePool.sol";
import {ILocking} from "src/interfaces/IGoatLocking.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockLocking} from "test/mocks/MockLocking.sol";

contract ValidatorEntryUpgradeableV2 is ValidatorEntryUpgradeable {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract ValidatorEntryUpgradeableTest is Test {
    MockLocking private locking;
    MockERC20 private rewardToken;
    ValidatorEntryUpgradeable private entry;

    address private constant FOUNDATION = address(0xF2);
    address private constant NEW_FOUNDATION = address(0xF6);
    address private constant FOUNDATION_TREASURY = address(0xF8);
    address private constant OPERATOR = address(0xF3);
    address private constant NEW_OPERATOR = address(0xF7);
    address private constant OPERATOR_TREASURY = address(0xF9);
    address private constant FUNDER = address(0xF4);
    address private constant FUNDER_PAYEE = address(0xF5);
    address private constant VALIDATOR = address(0xBEEF);
    address private constant NEW_OWNER = address(0xD00D);
    address private constant UNLOCK_RECIPIENT = address(0xAC1D);

    function setUp() public {
        locking = new MockLocking();
        rewardToken = new MockERC20();

        ValidatorEntryUpgradeable implementation = new ValidatorEntryUpgradeable();
        bytes memory initData =
            abi.encodeCall(ValidatorEntryUpgradeable.initialize, (locking, rewardToken, FOUNDATION, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        entry = ValidatorEntryUpgradeable(payable(address(proxy)));

        entry.setCommissionRates(2_000, 3_000, 5_000, 4_000);
        locking.setOwner(VALIDATOR, FUNDER);
    }

    function testUpgradeToNewImplementation() public {
        ValidatorEntryUpgradeableV2 newImpl = new ValidatorEntryUpgradeableV2();
        address nonOwner = address(0xB0B);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        entry.upgradeToAndCall(address(newImpl), "");

        entry.upgradeToAndCall(address(newImpl), "");

        assertEq(ValidatorEntryUpgradeableV2(address(entry)).version(), "v2");
    }

    function testDistributeRewardViaValidatorEntry() public {
        address payable poolAddr = _migrateDefault(10 ether, 1_000 ether, 0);
        _fundPool(poolAddr, 10 ether, 1_000 ether);

        uint256 funderNativeBefore = FUNDER_PAYEE.balance;
        uint256 funderTokenBefore = rewardToken.balanceOf(FUNDER_PAYEE);

        entry.withdrawRewards(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.foundationNativeCommission(), 2 ether);
        assertEq(pool.operatorNativeCommission(), 3 ether);
        assertEq(pool.foundationTokenCommission(), 500 ether);
        assertEq(pool.operatorTokenCommission(), 400 ether);
        assertEq(FUNDER_PAYEE.balance - funderNativeBefore, 5 ether);
        assertEq(rewardToken.balanceOf(FUNDER_PAYEE) - funderTokenBefore, 100 ether);
    }

    function testWithdrawsRespectRoles() public {
        address payable poolAddr = _migrateDefault(10 ether, 1_000 ether, 0);
        _fundPool(poolAddr, 5 ether, 200 ether);
        entry.withdrawRewards(VALIDATOR);

        uint256 foundationNativeBefore = FOUNDATION.balance;
        uint256 operatorNativeBefore = OPERATOR.balance;

        vm.prank(FOUNDATION);
        entry.withdrawFoundationCommission(VALIDATOR, FOUNDATION);
        vm.prank(OPERATOR);
        entry.withdrawOperatorCommission(VALIDATOR, OPERATOR);

        assertEq(FOUNDATION.balance - foundationNativeBefore, 1 ether);
        assertEq(OPERATOR.balance - operatorNativeBefore, 1.5 ether);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.foundationTokenCommission(), 0);
        assertEq(pool.operatorTokenCommission(), 0);
    }

    function testOperatorAllowanceCapsShare() public {
        address payable poolAddr = _migrateDefault(1 ether, 100 ether, 0);
        _fundPool(poolAddr, 10 ether, 1_000 ether);

        entry.withdrawRewards(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.operatorNativeCommission(), 1 ether);
        assertEq(pool.operatorTokenCommission(), 100 ether);
    }

    function testSetFoundationWithdrawsPendingCommissionToExplicitReceiver() public {
        address payable poolAddr = _migrateDefault(0, 0, 0);
        _fundPool(poolAddr, 10 ether, 1_000 ether);
        entry.withdrawRewards(VALIDATOR);

        uint256 treasuryNativeBefore = FOUNDATION_TREASURY.balance;
        entry.setFoundation(NEW_FOUNDATION, FOUNDATION_TREASURY);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(entry.foundation(), NEW_FOUNDATION);
        assertEq(FOUNDATION_TREASURY.balance - treasuryNativeBefore, 2 ether);
        assertEq(rewardToken.balanceOf(FOUNDATION_TREASURY), 500 ether);
        assertEq(pool.foundationNativeCommission(), 0);
        assertEq(pool.foundationTokenCommission(), 0);
    }

    function testSetOperatorWithdrawsPendingCommissionToExplicitReceiver() public {
        address payable poolAddr = _migrateDefault(0, 0, 0);
        _fundPool(poolAddr, 10 ether, 1_000 ether);
        entry.withdrawRewards(VALIDATOR);

        uint256 treasuryNativeBefore = OPERATOR_TREASURY.balance;

        vm.prank(OPERATOR);
        entry.setOperator(VALIDATOR, NEW_OPERATOR, OPERATOR_TREASURY);

        bool isActive;
        uint32 index_;
        uint32 cooldown;
        address funder;
        address funderPayee;
        address operator;
        (isActive, index_, cooldown, funder, funderPayee, operator,) = entry.validators(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertTrue(isActive);
        assertEq(index_, 0);
        assertEq(cooldown, 0);
        assertEq(funder, FUNDER);
        assertEq(funderPayee, FUNDER_PAYEE);
        assertEq(operator, NEW_OPERATOR);
        assertEq(OPERATOR_TREASURY.balance - treasuryNativeBefore, 3 ether);
        assertEq(rewardToken.balanceOf(OPERATOR_TREASURY), 400 ether);
        assertEq(pool.operatorNativeCommission(), 0);
        assertEq(pool.operatorTokenCommission(), 0);
    }

    function testMigrateToLeavesInFlightRewardClaimedForLaterWithdrawal()
        public
    {
        address payable poolAddr = _migrateDefault(0, 0, 0);
        _seedClaim(VALIDATOR, 10 ether, 1_000 ether);

        uint256 funderNativeBefore = FUNDER_PAYEE.balance;
        vm.prank(FUNDER);
        entry.migrateTo(VALIDATOR, NEW_OWNER);

        bool isActive;
        uint32 index_;
        uint32 cooldown;
        (isActive, index_, cooldown,,,,) = entry.validators(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(locking.owners(VALIDATOR), NEW_OWNER);
        assertFalse(isActive);
        assertEq(index_, 0);
        assertEq(cooldown, block.timestamp + 7 days);
        assertEq(FUNDER_PAYEE.balance - funderNativeBefore, 0);
        assertEq(rewardToken.balanceOf(FUNDER_PAYEE), 0);
        assertEq(address(pool).balance, 10 ether);
        assertEq(rewardToken.balanceOf(address(pool)), 1_000 ether);

        entry.withdrawRewards(VALIDATOR);

        assertEq(FUNDER_PAYEE.balance - funderNativeBefore, 5 ether);
        assertEq(rewardToken.balanceOf(FUNDER_PAYEE), 100 ether);
        assertEq(pool.foundationNativeCommission(), 2 ether);
        assertEq(pool.operatorNativeCommission(), 3 ether);
        assertEq(pool.foundationTokenCommission(), 500 ether);
        assertEq(pool.operatorTokenCommission(), 400 ether);
    }

    function testMigrationCooldownBlocksImmediateRemigrationAndAllowsLater() public {
        address payable initialPool = _migrateDefault(0, 0, 0);

        vm.prank(FUNDER);
        entry.migrateTo(VALIDATOR, FUNDER);

        vm.prank(FUNDER);
        entry.registerMigration(VALIDATOR);
        vm.prank(FUNDER);
        locking.changeValidatorOwner(VALIDATOR, address(entry));
        vm.prank(FUNDER);
        vm.expectRevert("Migration window not expired");
        entry.migrate(VALIDATOR, FUNDER, FUNDER_PAYEE, OPERATOR, 0, 0, 0);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(FUNDER);
        entry.migrate(VALIDATOR, FUNDER, FUNDER_PAYEE, OPERATOR, 0, 0, 0);

        (bool isActive,, uint32 cooldown,,,, address payable poolAddr) = entry.validators(VALIDATOR);
        assertTrue(isActive);
        assertEq(cooldown, 0);
        assertTrue(poolAddr != address(0));
        assertTrue(poolAddr != initialPool);
    }

    function testDelegateAndUndelegateForwardThroughEntry() public {
        _migrateDefault(0, 0, 0);

        MockERC20 depositToken = new MockERC20();
        depositToken.mint(FUNDER, 250 ether);

        ILocking.Locking[] memory values = new ILocking.Locking[](2);
        values[0] = ILocking.Locking({token: address(0), amount: 1 ether});
        values[1] = ILocking.Locking({token: address(depositToken), amount: 250 ether});

        vm.deal(FUNDER, 1 ether);
        vm.startPrank(FUNDER);
        depositToken.approve(address(entry), 250 ether);
        entry.delegate{value: 1 ether}(VALIDATOR, values);
        vm.stopPrank();

        assertEq(locking.lastLockCaller(), address(entry));
        assertEq(locking.lastLockValidator(), VALIDATOR);
        assertEq(locking.lastLockValue(), 1 ether);
        assertEq(locking.lastLockLength(), 2);
        assertEq(address(locking).balance, 1 ether);
        assertEq(depositToken.balanceOf(address(locking)), 250 ether);

        ILocking.Locking[] memory unlockValues = new ILocking.Locking[](1);
        unlockValues[0] = ILocking.Locking({token: address(0), amount: 2 ether});

        vm.prank(FUNDER);
        entry.undelegate(VALIDATOR, UNLOCK_RECIPIENT, unlockValues);

        assertEq(locking.lastUnlockCaller(), address(entry));
        assertEq(locking.lastUnlockValidator(), VALIDATOR);
        assertEq(locking.lastUnlockRecipient(), UNLOCK_RECIPIENT);
        assertEq(locking.lastUnlockLength(), 1);
    }

    function testRegisterMigrationRevertsWhileActive() public {
        _migrateDefault(10 ether, 1_000 ether, 0);

        vm.prank(address(entry));
        locking.changeValidatorOwner(VALIDATOR, FUNDER);
        vm.expectRevert("Already migrated");
        vm.prank(FUNDER);
        entry.registerMigration(VALIDATOR);
    }

    function _migrateDefault(uint256 nativeAllowance, uint256 tokenAllowance, uint256 allowanceUpdatePeriod)
        internal
        returns (address payable poolAddr)
    {
        poolAddr = _migrateValidator(FUNDER_PAYEE, nativeAllowance, tokenAllowance, allowanceUpdatePeriod);
    }

    function _migrateValidator(
        address funderPayee,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 allowanceUpdatePeriod
    ) internal returns (address payable poolAddr) {
        vm.prank(FUNDER);
        entry.registerMigration(VALIDATOR);
        vm.prank(FUNDER);
        locking.changeValidatorOwner(VALIDATOR, address(entry));
        vm.prank(FUNDER);
        entry.migrate(VALIDATOR, FUNDER, funderPayee, OPERATOR, nativeAllowance, tokenAllowance, allowanceUpdatePeriod);

        bool isActive;
        uint32 index_;
        (isActive, index_,,,,, poolAddr) = entry.validators(VALIDATOR);
        assertTrue(isActive);
        assertEq(index_, 0);
    }

    function _seedClaim(address validator, uint256 nativeAmount, uint256 tokenAmount) internal {
        vm.deal(address(this), nativeAmount);
        rewardToken.mint(address(this), tokenAmount);
        rewardToken.approve(address(locking), tokenAmount);
        locking.seedClaim{value: nativeAmount}(validator, rewardToken, nativeAmount, tokenAmount);
    }

    function _fundPool(address payable poolAddr, uint256 nativeAmount, uint256 tokenAmount) internal {
        vm.deal(address(this), address(this).balance + nativeAmount);
        (bool sent,) = poolAddr.call{value: nativeAmount}("");
        require(sent, "fund native");
        if (tokenAmount > 0) {
            rewardToken.mint(poolAddr, tokenAmount);
        }
    }
}
