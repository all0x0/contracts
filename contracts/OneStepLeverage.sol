// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { IERC3156FlashLender } from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPositionManager } from "./Interfaces/IPositionManager.sol";
import { IRToken } from "./Interfaces/IRToken.sol";
import { PositionManagerDependent } from "./PositionManagerDependent.sol";
import { IOneStepLeverage } from "./Interfaces/IOneStepLeverage.sol";
import { IAMM } from "./Interfaces/IAMM.sol";

contract OneStepLeverage is IERC3156FlashBorrower, IOneStepLeverage, PositionManagerDependent {
    using SafeERC20 for IERC20;

    IAMM public immutable override amm;
    IERC20 public immutable override collateralToken;

    uint256 public constant override MAX_LEFTOVER_R = 1e18;

    constructor(
        IPositionManager positionManager,
        IAMM amm_,
        IERC20 collateralToken_
    )
        PositionManagerDependent(address(positionManager))
    {
        amm = amm_;
        collateralToken = collateralToken_;

        // We approve tokens here so we do not need to do approvals in particular actions.
        // Approved contracts are known, so this should be considered as safe.

        // No need to use safeApprove, IRToken is known token and is safe.
        positionManager.rToken().approve(address(amm), type(uint256).max);
        positionManager.rToken().approve(address(positionManager.rToken()), type(uint256).max);
        collateralToken_.safeApprove(address(amm), type(uint256).max);
        collateralToken_.safeApprove(address(positionManager), type(uint256).max);
    }

    function manageLeveragedPosition(
        uint256 debtChange,
        bool isDebtIncrease,
        uint256 principalCollateralChange,
        bool principalCollateralIncrease,
        bytes calldata ammData,
        uint256 minReturnOrAmountToSell,
        uint256 maxFeePercentage
    )
        external
        override
    {
        if (principalCollateralIncrease && principalCollateralChange > 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), principalCollateralChange);
        }

        bytes memory data = abi.encode(
            msg.sender,
            principalCollateralChange,
            principalCollateralIncrease,
            isDebtIncrease,
            ammData,
            minReturnOrAmountToSell,
            maxFeePercentage
        );

        IRToken rToken = IPositionManager(positionManager).rToken();
        rToken.flashLoan(this, address(rToken), debtChange, data);
    }

    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    )
        external
        override
        returns (bytes32)
    {
        IERC20 rToken = IPositionManager(positionManager).rToken();
        if (msg.sender != address(rToken)) {
            revert UnsupportedToken();
        }
        if (initiator != address(this)) {
            revert InvalidInitiator();
        }

        (
            address user,
            uint256 principalCollateralChange,
            bool principalCollateralIncrease,
            bool isDebtIncrease,
            bytes memory ammData,
            uint256 minReturnOrAmountToSell,
            uint256 maxFeePercentage
        ) = abi.decode(data, (address, uint256, bool, bool, bytes, uint256, uint256));

        uint256 leveragedCollateralChange = isDebtIncrease
            ? amm.swap(rToken, collateralToken, amount, minReturnOrAmountToSell, ammData)
            : minReturnOrAmountToSell;

        uint256 collateralChange;
        bool increaseCollateral;
        if (principalCollateralIncrease != isDebtIncrease) {
            collateralChange = principalCollateralChange > leveragedCollateralChange
                ? principalCollateralChange - leveragedCollateralChange
                : leveragedCollateralChange - principalCollateralChange;

            increaseCollateral = principalCollateralIncrease && !isDebtIncrease
                ? principalCollateralChange > leveragedCollateralChange
                : leveragedCollateralChange > principalCollateralChange;
        } else {
            increaseCollateral = principalCollateralIncrease;
            collateralChange = principalCollateralChange + leveragedCollateralChange;
        }

        IPositionManager(positionManager).managePosition(
            collateralToken, user, collateralChange, increaseCollateral, amount, isDebtIncrease, maxFeePercentage
        );

        if (!principalCollateralIncrease && principalCollateralChange > 0) {
            collateralToken.safeTransfer(user, principalCollateralChange);
        }
        if (!isDebtIncrease) {
            uint256 repayAmount = amount + fee;
            uint256 amountOut = amm.swap(collateralToken, rToken, leveragedCollateralChange, repayAmount, ammData);
            if (amountOut > repayAmount + MAX_LEFTOVER_R) {
                // No need to use safeTransfer as rToken is known
                rToken.transfer(user, amountOut - repayAmount);
            }
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}