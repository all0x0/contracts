// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IRToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/CheckContract.sol";

contract BorrowerOperations is LiquityBase, Ownable2Step, CheckContract, IBorrowerOperations {
    string constant public NAME = "BorrowerOperations";

    bool private _addressesSet;

    // --- Connected contract declarations ---

    ITroveManager public troveManager;

    address gasPoolAddress;

    ICollSurplusPool collSurplusPool;

    address public feeRecipient;

    IRToken public rToken;

    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    // --- Modifiers ---

    modifier validMaxFeePercentageWhen(uint256 _maxFeePercentage, bool condition) {
        if (condition && (_maxFeePercentage < troveManager.borrowingSpread() || _maxFeePercentage > DECIMAL_PRECISION)) {
            revert BorrowerOperationsInvalidMaxFeePercentage();
        }
        _;
    }

    modifier onlyActiveTrove() {
        if (troveManager.getTroveStatus(msg.sender) != ITroveManager.TroveStatus.active) {
            revert BorrowerOperationsTroveNotActive();
        }
        _;
    }

    modifier onlyNonActiveTrove() {
        if (troveManager.getTroveStatus(msg.sender) == ITroveManager.TroveStatus.active) {
            revert BorrowerOperationsTroveActive();
        }
        _;
    }

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

     struct LocalVariables_adjustTrove {
        uint price;
        uint collChange;
        uint netDebtChange;
        bool isCollIncrease;
        uint debt;
        uint coll;
        uint oldICR;
        uint newICR;
        uint newNICR;
        uint rFee;
        uint newDebt;
        uint newColl;
        uint stake;
    }

    struct LocalVariables_openTrove {
        uint price;
        uint rFee;
        uint netDebt;
        uint compositeDebt;
        uint ICR;
        uint NICR;
        uint stake;
        uint arrayIndex;
    }

    struct ContractsCache {
        ITroveManager troveManager;
        IActivePool activePool;
        IRToken rToken;
    }

    // --- Setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _sortedTrovesAddress,
        address _rTokenAddress,
        address _feeRecipient
    )
        external
        override
        onlyOwner
    {
        if (_addressesSet) {
            revert BorrowerOperationsAddressesAlreadySet();
        }

        // This makes impossible to open a trove with zero withdrawn R
        assert(MIN_NET_DEBT > 0);

        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_gasPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_priceFeedAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_rTokenAddress);

        troveManager = ITroveManager(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        rToken = IRToken(_rTokenAddress);
        feeRecipient = _feeRecipient;

        _addressesSet = true;

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit GasPoolAddressChanged(_gasPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit RTokenAddressChanged(_rTokenAddress);
        emit FeeRecipientChanged(_feeRecipient);
    }

    function setFeeRecipient(address _feeRecipient) external override onlyOwner {
        if (!_addressesSet) {
            revert BorrowerOperationsAddressesNotSet();
        }

        feeRecipient = _feeRecipient;
        emit FeeRecipientChanged(_feeRecipient);
    }

    // --- Borrower Trove Operations ---

    function openTrove(
        uint _maxFeePercentage,
        uint _rAmount,
        address _upperHint,
        address _lowerHint,
        uint _collAmount
    )
        external
        override
        validMaxFeePercentageWhen(_maxFeePercentage, true)
        onlyNonActiveTrove
    {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, rToken);
        LocalVariables_openTrove memory vars;

        vars.rFee;
        vars.netDebt = _rAmount;

        vars.rFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.rToken, _rAmount, _maxFeePercentage);
        vars.netDebt += vars.rFee;
        _requireAtLeastMinNetDebt(vars.netDebt);

        // ICR is based on the composite debt, i.e. the requested R amount + R borrowing fee + R gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);
        assert(vars.compositeDebt > 0);

        vars.price = priceFeed.fetchPrice();
        vars.ICR = LiquityMath._computeCR(_collAmount, vars.compositeDebt, vars.price);
        vars.NICR = LiquityMath._computeNominalCR(_collAmount, vars.compositeDebt);

        _requireICRisAboveMCR(vars.ICR);

        // Set the trove struct's properties
        contractsCache.troveManager.setTroveStatus(msg.sender, 1);
        contractsCache.troveManager.increaseTroveColl(msg.sender, _collAmount);
        contractsCache.troveManager.increaseTroveDebt(msg.sender, vars.compositeDebt);

        contractsCache.troveManager.updateTroveRewardSnapshots(msg.sender);
        vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);

        sortedTroves.insert(msg.sender, vars.NICR, _upperHint, _lowerHint);
        vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(msg.sender);
        emit TroveCreated(msg.sender, vars.arrayIndex);

        // Move the collateralToken to the Active Pool, and mint the rAmount to the borrower
        contractsCache.activePool.depositCollateral(msg.sender, _collAmount);
        _withdrawR(contractsCache.activePool, contractsCache.rToken, msg.sender, _rAmount, vars.netDebt);
        // Move the R gas compensation to the Gas Pool
        _withdrawR(contractsCache.activePool, contractsCache.rToken, gasPoolAddress, R_GAS_COMPENSATION, R_GAS_COMPENSATION);

        emit TroveUpdated(msg.sender, vars.compositeDebt, _collAmount, vars.stake, BorrowerOperation.openTrove);
        emit RBorrowingFeePaid(msg.sender, vars.rFee);
    }

    // Send ETH as collateral to a trove
    function addColl(address _upperHint, address _lowerHint, uint256 _collDeposit) external override {
        _adjustTrove(0, 0, false, _upperHint, _lowerHint, 0, _collDeposit);
    }

    // Withdraw ETH collateral from a trove
    function withdrawColl(uint _collWithdrawal, address _upperHint, address _lowerHint) external override {
        _adjustTrove(_collWithdrawal, 0, false, _upperHint, _lowerHint, 0, 0);
    }

    // Withdraw R tokens from a trove: mint new R tokens to the owner, and increase the trove's debt accordingly
    function withdrawR(uint _maxFeePercentage, uint _rAmount, address _upperHint, address _lowerHint) external override {
        _adjustTrove(0, _rAmount, true, _upperHint, _lowerHint, _maxFeePercentage, 0);
    }

    // Repay R tokens to a Trove: Burn the repaid R tokens, and reduce the trove's debt accordingly
    function repayR(uint _rAmount, address _upperHint, address _lowerHint) external override {
        _adjustTrove(0, _rAmount, false, _upperHint, _lowerHint, 0, 0);
    }

    function adjustTrove(uint _maxFeePercentage, uint _collWithdrawal, uint _rChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint256 _collDeposit) external override {
        _adjustTrove(_collWithdrawal, _rChange, _isDebtIncrease, _upperHint, _lowerHint, _maxFeePercentage, _collDeposit);
    }

    /*
    * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
    *
    * It therefore expects either a positive _collDeposit, or a positive _collWithdrawal argument.
    *
    * If both are positive, it will revert.
    */
    function _adjustTrove(
        uint _collWithdrawal,
        uint _rChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint,
        uint _maxFeePercentage,
        uint256 _collDeposit
    )
        internal
        validMaxFeePercentageWhen(_maxFeePercentage, _isDebtIncrease)
        onlyActiveTrove
    {
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, rToken);
        LocalVariables_adjustTrove memory vars;

        if (_isDebtIncrease && _rChange == 0) {
            revert DebtIncreaseZeroDebtChange();
        }
        if (_collDeposit != 0 && _collWithdrawal != 0) {
            revert NotSingularCollateralChange();
        }
        if (_collDeposit == 0 && _collWithdrawal == 0 && _rChange == 0) {
            revert NoCollateralOrDebtChange();
        }

        contractsCache.troveManager.applyPendingRewards(msg.sender);

        // Get the collChange based on whether or not ETH was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(_collDeposit, _collWithdrawal);

        vars.netDebtChange = _rChange;

        // If the adjustment incorporates a debt increase, then trigger a borrowing fee
        if (_isDebtIncrease) {
            vars.rFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.rToken, _rChange, _maxFeePercentage);
            vars.netDebtChange += vars.rFee; // The raw debt change includes the fee
        }

        vars.debt = contractsCache.troveManager.getTroveDebt(msg.sender);
        vars.coll = contractsCache.troveManager.getTroveColl(msg.sender);

        // Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
        vars.price = priceFeed.fetchPrice();
        vars.oldICR = LiquityMath._computeCR(vars.coll, vars.debt, vars.price);
        vars.newICR = _getNewICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, vars.price);
        assert(_collWithdrawal <= vars.coll);

        _requireICRisAboveMCR(vars.newICR);

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough R
        if (!_isDebtIncrease && _rChange > 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt) - vars.netDebtChange);
            _requireValidRRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientRBalance(contractsCache.rToken, msg.sender, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(contractsCache.troveManager, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);

        // Re-insert trove in to the sorted list
        vars.newNICR = _getNewNominalICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        sortedTroves.reInsert(msg.sender, vars.newNICR, _upperHint, _lowerHint);

        emit TroveUpdated(msg.sender, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustTrove);
        emit RBorrowingFeePaid(msg.sender, vars.rFee);

        // Use the unmodified _rChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            contractsCache.activePool,
            contractsCache.rToken,
            vars.collChange,
            vars.isCollIncrease,
            _rChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeTrove() external override onlyActiveTrove {
        ITroveManager troveManagerCached = troveManager;
        IActivePool activePoolCached = activePool;
        IRToken rTokenCached = rToken;

        troveManagerCached.applyPendingRewards(msg.sender);

        uint coll = troveManagerCached.getTroveColl(msg.sender);
        uint debt = troveManagerCached.getTroveDebt(msg.sender);

        _requireSufficientRBalance(rTokenCached, msg.sender, debt - R_GAS_COMPENSATION);

        troveManagerCached.removeStake(msg.sender);
        troveManagerCached.closeTrove(msg.sender);

        emit TroveUpdated(msg.sender, 0, 0, 0, BorrowerOperation.closeTrove);

        // Burn the repaid R from the user's balance and the gas compensation from the Gas Pool
        _repayR(activePoolCached, rTokenCached, msg.sender, debt - R_GAS_COMPENSATION);
        _repayR(activePoolCached, rTokenCached, gasPoolAddress, R_GAS_COMPENSATION);

        // Send the collateral back to the user
        activePoolCached.sendETH(msg.sender, coll);
    }

    /**
     * Claim remaining collateral from a redemption
     */
    function claimCollateral() external override {
        // send ETH from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(ITroveManager _troveManager, IRToken _rToken, uint _rAmount, uint _maxFeePercentage) internal returns (uint rFee) {
        _troveManager.decayBaseRateFromBorrowing(); // decay the baseRate state variable
        rFee = _troveManager.getBorrowingFee(_rAmount);

        _requireUserAcceptsFee(rFee, _rAmount, _maxFeePercentage);

        if (rFee > 0) {
            _rToken.mint(feeRecipient, rFee);
        }
    }

    function _getUSDValue(uint _coll, uint _price) internal pure returns (uint usdValue) {
        usdValue = _price * _coll / DECIMAL_PRECISION;
    }

    function _getCollChange(
        uint _collReceived,
        uint _requestedCollWithdrawal
    )
        internal
        pure
        returns(uint collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update trove's coll and debt based on whether they increase or decrease
    function _updateTroveFromAdjustment
    (
        ITroveManager _troveManager,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        private
        returns (uint newColl, uint newDebt)
    {
        newColl = _isCollIncrease ? _troveManager.increaseTroveColl(msg.sender, _collChange)
                                  : _troveManager.decreaseTroveColl(msg.sender, _collChange);
        newDebt = _isDebtIncrease ? _troveManager.increaseTroveDebt(msg.sender, _debtChange)
                                  : _troveManager.decreaseTroveDebt(msg.sender, _debtChange);
    }

    function _moveTokensAndETHfromAdjustment
    (
        IActivePool _activePool,
        IRToken _rToken,
        uint _collChange,
        bool _isCollIncrease,
        uint _rChange,
        bool _isDebtIncrease,
        uint _netDebtChange
    )
        private
    {
        if (_isDebtIncrease) {
            _withdrawR(_activePool, _rToken, msg.sender, _rChange, _netDebtChange);
        } else {
            _repayR(_activePool, _rToken, msg.sender, _rChange);
        }

        if (_isCollIncrease) {
            _activePool.depositCollateral(msg.sender, _collChange);
        } else {
            _activePool.sendETH(msg.sender, _collChange);
        }
    }

    // Issue the specified amount of R to _account and increases the total active debt (_netDebtIncrease potentially includes a rFee)
    function _withdrawR(IActivePool _activePool, IRToken _rToken, address _account, uint _rAmount, uint _netDebtIncrease) internal {
        _activePool.increaseRDebt(_netDebtIncrease);
        _rToken.mint(_account, _rAmount);
    }

    // Burn the specified amount of R from _account and decreases the total active debt
    function _repayR(IActivePool _activePool, IRToken _rToken, address _account, uint _R) internal {
        _activePool.decreaseRDebt(_R);
        _rToken.burn(_account, _R);
    }

    // --- 'Require' wrapper functions ---

    function _requireICRisAboveMCR(uint _newICR) internal pure {
        if (_newICR < MCR) {
            revert NewICRLowerThanMCR(_newICR);
        }
    }

    function _requireAtLeastMinNetDebt(uint _netDebt) internal pure {
        if (_netDebt < MIN_NET_DEBT) {
            revert NetDebtBelowMinimum(_netDebt);
        }
    }

    function _requireValidRRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
        if (_debtRepayment > _currentDebt - R_GAS_COMPENSATION) {
            revert RepayRAmountExceedsDebt(_debtRepayment);
        }
    }

    function _requireSufficientRBalance(IRToken _rToken, address _borrower, uint _debtRepayment) internal view {
        uint256 balance = _rToken.balanceOf(_borrower);
        if (balance < _debtRepayment) {
            revert RepayNotEnoughR(balance);
        }
    }

    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewNominalICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        pure
        internal
        returns (uint newNICR)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        newNICR = LiquityMath._computeNominalCR(newColl, newDebt);
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        pure
        internal
        returns (uint newICR)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        newICR = LiquityMath._computeCR(newColl, newDebt, _price);
    }

    function _getNewTroveAmounts(
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        pure
        returns (uint newColl, uint newDebt)
    {
        newColl = _isCollIncrease ? _coll + _collChange :  _coll - _collChange;
        newDebt = _isDebtIncrease ? _debt + _debtChange : _debt - _debtChange;
    }

    function getCompositeDebt(uint _debt) external pure override returns (uint) {
        return _getCompositeDebt(_debt);
    }
}
