// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixed256x18} from "@tempus-labs/contracts/math/Fixed256x18.sol";
import {MathUtils} from "../../contracts/Dependencies/MathUtils.sol";
import {IStEth} from "../../contracts/Dependencies/IStEth.sol";
import {IPositionManager} from "../../contracts/Interfaces/IPositionManager.sol";
import {IPositionManagerStEth} from "../../contracts/Interfaces/IPositionManagerStEth.sol";
import {StEthPositionManager} from "../../contracts/StEthPositionManager.sol";
import {PriceFeedTestnet} from "../TestContracts/PriceFeedTestnet.sol";

library PositionManagerUtils {
    using Fixed256x18 for uint256;

    enum ETHType {
        ETH,
        STETH,
        WSTETH
    }

    struct OpenPositionResult {
        uint256 rAmount;
        uint256 netDebt;
        uint256 totalDebt;
        uint256 icr;
        uint256 collateral;
    }

    struct WithdrawRResult {
        uint256 rAmount;
        uint256 increasedTotalDebt;
    }

    function openPosition(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        IERC20 collateralToken,
        uint256 maxFeePercentage,
        uint256 extraRAmount,
        address upperHint,
        address lowerHint,
        uint256 icr,
        uint256 amount,
        ETHType ethType
    ) internal returns (OpenPositionResult memory result) {
        result.rAmount = getNetBorrowingAmount(positionManager, MathUtils.MIN_NET_DEBT) + extraRAmount;
        result.icr = icr;
        result.totalDebt = getOpenPositionTotalDebt(positionManager, result.rAmount);
        result.netDebt = MathUtils.getNetDebt(result.totalDebt);
        amount = (amount == 0) ? result.icr * result.totalDebt / priceFeed.getPrice() : amount;

        if (ethType == ETHType.ETH) {
            IStEth stEth = IPositionManagerStEth(address(positionManager)).stEth();
            uint256 wstEthAmount = stEth.getSharesByPooledEth(amount);
            IPositionManagerStEth(address(positionManager)).managePositionEth{value: amount}(
                result.rAmount, true, upperHint, lowerHint, maxFeePercentage
            );
            result.collateral = wstEthAmount;
        } else if (ethType == ETHType.STETH) {
            IStEth stEth = IPositionManagerStEth(address(positionManager)).stEth();
            uint256 wstEthAmount = stEth.getSharesByPooledEth(amount);
            stEth.approve(address(positionManager), amount);
            IPositionManagerStEth(address(positionManager)).managePositionStEth(
                amount, true, result.rAmount, true, upperHint, lowerHint, maxFeePercentage
            );
            result.collateral = wstEthAmount;
        } else {
            collateralToken.approve(address(positionManager), amount);
            positionManager.managePosition(amount, true, result.rAmount, true, upperHint, lowerHint, maxFeePercentage);
            result.collateral = amount;
        }
    }

    function openPosition(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        IERC20 collateralToken,
        uint256 icr
    ) internal returns (OpenPositionResult memory result) {
        result = openPosition(
            positionManager,
            priceFeed,
            collateralToken,
            MathUtils._100_PERCENT,
            0,
            address(0),
            address(0),
            icr,
            0,
            ETHType.WSTETH
        );
    }

    function openPositionStEth(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        IERC20 collateralToken,
        uint256 icr,
        ETHType ethType
    ) internal returns (OpenPositionResult memory result) {
        result = openPosition(
            positionManager,
            priceFeed,
            collateralToken,
            MathUtils._100_PERCENT,
            0,
            address(0),
            address(0),
            icr,
            0,
            ethType
        );
    }

    function openPosition(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        IERC20 collateralToken,
        uint256 extraRAmount,
        uint256 icr
    ) internal returns (OpenPositionResult memory result) {
        result = openPosition(
            positionManager,
            priceFeed,
            collateralToken,
            MathUtils._100_PERCENT,
            extraRAmount,
            address(0),
            address(0),
            icr,
            0,
            ETHType.WSTETH
        );
    }

    function openPosition(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        IERC20 collateralToken,
        uint256 extraRAmount,
        uint256 icr,
        uint256 amount
    ) internal returns (OpenPositionResult memory result) {
        result = openPosition(
            positionManager,
            priceFeed,
            collateralToken,
            MathUtils._100_PERCENT,
            extraRAmount,
            address(0),
            address(0),
            icr,
            amount,
            ETHType.WSTETH
        );
    }

    function withdrawR(
        IPositionManager positionManager,
        PriceFeedTestnet priceFeed,
        address borrower,
        uint256 maxFeePercentage,
        uint256 rAmount,
        uint256 icr,
        address upperHint,
        address lowerHint
    ) internal returns (WithdrawRResult memory result) {
        require(
            !(rAmount > 0 && icr > 0) && (rAmount > 0 || icr > 0), "Specify either R amount or target ICR, but not both"
        );

        result.rAmount = rAmount;

        if (icr > 0) {
            IERC20 raftDebtToken = positionManager.raftDebtToken();
            IERC20 raftCollateralToken = positionManager.raftCollateralToken();
            uint256 debt = raftDebtToken.balanceOf(borrower);
            uint256 collateral = raftCollateralToken.balanceOf(borrower);
            uint256 price = priceFeed.getPrice();
            uint256 targetDebt = collateral * price / icr;
            require(targetDebt > debt, "Target debt is not greater than current debt");
            result.increasedTotalDebt = targetDebt - debt;
            result.rAmount = getNetBorrowingAmount(positionManager, result.increasedTotalDebt);
        } else {
            result.increasedTotalDebt = getAmountWithBorrowingFee(positionManager, result.rAmount);
        }

        positionManager.managePosition(0, false, result.rAmount, true, upperHint, lowerHint, maxFeePercentage);
    }

    function withdrawR(IPositionManager positionManager, PriceFeedTestnet priceFeed, address borrower, uint256 icr)
        internal
        returns (WithdrawRResult memory result)
    {
        uint256 maxFee = MathUtils._100_PERCENT;
        result = withdrawR(positionManager, priceFeed, borrower, maxFee, 0, icr, address(0), address(0));
    }

    function getNetBorrowingAmount(IPositionManager _positionManager, uint256 _debtWithFee)
        internal
        view
        returns (uint256)
    {
        uint256 borrowingRate = _positionManager.getBorrowingRateWithDecay();
        return _debtWithFee.divUp(MathUtils._100_PERCENT + borrowingRate);
    }

    function getOpenPositionTotalDebt(IPositionManager _positionManager, uint256 rAmount)
        internal
        view
        returns (uint256)
    {
        uint256 fee = _positionManager.getBorrowingFee(rAmount);
        return rAmount + MathUtils.R_GAS_COMPENSATION + fee;
    }

    function getAmountWithBorrowingFee(IPositionManager _positionManager, uint256 _rAmount)
        internal
        view
        returns (uint256)
    {
        return _rAmount + _positionManager.getBorrowingFee(_rAmount);
    }
}