// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./AelinERC20.sol";
import "./MinimalProxyFactory.sol";
import {AelinDeal} from "./AelinDeal.sol";
import {AelinPool} from "./AelinPool.sol";
import {IAelinPool} from "./interfaces/IAelinPool.sol";
import {AelinFeeEscrow} from "./AelinFeeEscrow.sol";
import {IAelinUpFrontDeal} from "./interfaces/IAelinUpFrontDeal.sol";
import "./libraries/NftCheck.sol";
import "./interfaces/ICryptoPunks.sol";

contract AelinUpFrontDeal is AelinERC20, MinimalProxyFactory, IAelinUpFrontDeal {
    address constant CRYPTO_PUNKS = address(0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB);
    uint256 constant BASE = 100 * 10**18;
    uint256 constant MAX_SPONSOR_FEE = 15 * 10**18;
    uint256 constant AELIN_FEE = 2 * 10**18;

    UpFrontDeal public dealData;

    address public aelinTreasuryAddress;
    address public aelinEscrowLogicAddress;
    AelinFeeEscrow public aelinFeeEscrow;

    bool private calledInitialize;
    address public futureHolder;

    mapping(address => uint256) public allowList;
    mapping(address => IAelinPool.NftCollectionRules) public nftCollectionDetails;
    mapping(address => mapping(address => bool)) public nftWalletUsedForPurchase;
    mapping(address => mapping(uint256 => bool)) public nftId;
    mapping(address => uint256) public purchaseTokensPerUser;
    mapping(address => uint256) public poolSharesPerUser;
    mapping(address => uint256) public amountVested;

    uint256 public totalPurchasingAccepted;
    uint256 public totalPoolShares;
    uint256 public totalUnderlyingClaimed;

    bool private hasAllowList;
    bool private hasNftList;
    bool private underlyingDepositComplete;
    bool private holderClaimed;
    bool private feeEscrowClaimed;

    uint256 private dealStart;
    uint256 public vestingCliffExpiry;
    uint256 public purchaseExpiry;
    uint256 public vestingExpiry;

    function initialize(
        UpFrontDeal calldata _dealData,
        address _dealCreator,
        uint256 _depositUnderlayingAmount,
        address _aelinTreasuryAddress,
        address _aelinEscrowLogicAddress
    ) external initOnce {
        // pool initialization checks
        require(_dealData.purchaseDuration >= 30 minutes && _dealData.purchaseDuration <= 30 days, "not within limit");
        require(_dealData.sponsorFee <= MAX_SPONSOR_FEE, "exceeds max sponsor fee");
        uint8 purchaseTokenDecimals = IERC20Decimals(_dealData.purchaseToken).decimals();
        require(purchaseTokenDecimals <= DEAL_TOKEN_DECIMALS, "purchase token not compatible");

        require(1825 days >= _dealData.vestingCliffPeriod, "max 5 year cliff");
        require(1825 days >= _dealData.vestingPeriod, "max 5 year vesting");

        require(_dealData.purchaseTokenPerDealToken > 0, "invalid deal price");

        uint8 underlyingTokenDecimals = IERC20Decimals(_dealData.underlyingDealToken).decimals();
        uint256 _totalIntendedRaise = (_dealData.purchaseTokenPerDealToken * _dealData.underlyingDealTokenTotal) /
            10**underlyingTokenDecimals;
        require(_dealData.purchaseRaiseMinimum < _totalIntendedRaise, "raise minimum is less than deal total");

        // store pool and deal details as state variables
        dealData = _dealData;
        dealStart = block.timestamp;

        // the deal token has the same amount of decimals as the underlying deal token,
        // eventually making them 1:1 redeemable
        _setNameSymbolAndDecimals(
            string(abi.encodePacked("aeUpFrontDeal-", _dealData.name)),
            string(abi.encodePacked("aeUD-", _dealData.symbol)),
            underlyingTokenDecimals
        );

        aelinEscrowLogicAddress = _aelinEscrowLogicAddress;
        aelinTreasuryAddress = _aelinTreasuryAddress;

        // Allow list logic
        // check if there's allowlist and amounts,
        // if yes, store it to `allowList` and emit a single event with the addresses and amounts
        address[] memory allowListAddresses = _dealData.allowListAddresses;
        uint256[] memory allowListAmounts = _dealData.allowListAmounts;

        if (allowListAddresses.length > 0 || allowListAmounts.length > 0) {
            require(
                allowListAddresses.length == allowListAmounts.length,
                "allowListAddresses and allowListAmounts arrays should have the same length"
            );
            for (uint256 i = 0; i < allowListAddresses.length; i++) {
                allowList[allowListAddresses[i]] = allowListAmounts[i];
            }
            hasAllowList = true;
            emit AllowlistAddress(allowListAddresses, allowListAmounts);
        }

        // NftCollection logic
        // check if the deal is nft gated
        // if yes, store it in `nftCollectionDetails` and `nftId` and emit respective events for 721 and 1155
        IAelinPool.NftCollectionRules[] memory nftCollectionRules = _dealData.nftCollectionRules;

        if (nftCollectionRules.length > 0) {
            // if the first address supports punks or 721, the entire pool only supports 721 or punks
            if (
                nftCollectionRules[0].collectionAddress == CRYPTO_PUNKS ||
                NftCheck.supports721(nftCollectionRules[0].collectionAddress)
            ) {
                for (uint256 i = 0; i < nftCollectionRules.length; i++) {
                    require(
                        nftCollectionRules[i].collectionAddress == CRYPTO_PUNKS ||
                            NftCheck.supports721(nftCollectionRules[i].collectionAddress),
                        "can only contain 721"
                    );
                    nftCollectionDetails[nftCollectionRules[i].collectionAddress] = nftCollectionRules[i];
                    emit PoolWith721(
                        nftCollectionRules[i].collectionAddress,
                        nftCollectionRules[i].purchaseAmount,
                        nftCollectionRules[i].purchaseAmountPerToken
                    );
                }
                hasNftList = true;
            }
            // if the first address supports 1155, the entire pool only supports 1155
            else if (NftCheck.supports1155(nftCollectionRules[0].collectionAddress)) {
                for (uint256 i = 0; i < nftCollectionRules.length; i++) {
                    require(NftCheck.supports1155(nftCollectionRules[i].collectionAddress), "can only contain 1155");
                    nftCollectionDetails[nftCollectionRules[i].collectionAddress] = nftCollectionRules[i];

                    for (uint256 j = 0; j < nftCollectionRules[i].tokenIds.length; j++) {
                        nftId[nftCollectionRules[i].collectionAddress][nftCollectionRules[i].tokenIds[j]] = true;
                    }
                    emit PoolWith1155(
                        nftCollectionRules[i].collectionAddress,
                        nftCollectionRules[i].purchaseAmount,
                        nftCollectionRules[i].purchaseAmountPerToken,
                        nftCollectionRules[i].tokenIds,
                        nftCollectionRules[i].minTokensEligible
                    );
                }
                hasNftList = true;
            } else {
                revert("collection is not compatible");
            }
        }

        // deposit underlying token logic
        // check if the underlyingDealAmount is more than 0,
        // if yes, transfer it to this contract and store it in `currentDealTokenTotal` and add it
        if (_depositUnderlayingAmount > 0) {
            require(
                IERC20(_dealData.underlyingDealToken).balanceOf(_dealCreator) >= _depositUnderlayingAmount,
                "not enough balance"
            );
            IERC20(_dealData.underlyingDealToken).transferFrom(_dealCreator, address(this), _depositUnderlayingAmount);
            uint256 currentDealTokenTotal = IERC20(_dealData.underlyingDealToken).balanceOf(address(this));
            if (currentDealTokenTotal >= _dealData.underlyingDealTokenTotal) {
                underlyingDepositComplete = true;
                purchaseExpiry = block.timestamp + dealData.purchaseDuration;
                vestingCliffExpiry = purchaseExpiry + _dealData.vestingCliffPeriod;
                vestingExpiry = vestingCliffExpiry + _dealData.vestingPeriod;
                emit DealFullyFunded(address(this), block.timestamp, purchaseExpiry, vestingCliffExpiry, vestingExpiry);
            }

            emit DepositDealToken(_dealData.underlyingDealToken, _dealCreator, currentDealTokenTotal);
        }
    }

    modifier initOnce() {
        require(!calledInitialize, "can only initialize once");
        calledInitialize = true;
        _;
    }

    /**
     * @dev method for holder to deposit underlying deal tokens
     * all underlying deal tokens must be deposited for the purchasing period to start
     * if tokens were deposited directly, this method must still be called to start the purchasing period
     */
    function depositUnderlyingTokens(uint256 _depositUnderlyingAmount) public onlyHolder {
        UpFrontDeal memory _dealData = dealData;

        require(
            IERC20(_dealData.underlyingDealToken).balanceOf(msg.sender) >= _depositUnderlyingAmount,
            "not enough balance"
        );
        require(!underlyingDepositComplete, "already deposited the total");

        uint256 balanceBeforeTransfer = IERC20(_dealData.underlyingDealToken).balanceOf(address(this));
        IERC20(_dealData.underlyingDealToken).transferFrom(msg.sender, address(this), _depositUnderlyingAmount);
        uint256 balanceAfterTransfer = IERC20(_dealData.underlyingDealToken).balanceOf(address(this));
        uint256 underlyingDealTokenAmount = balanceAfterTransfer - balanceBeforeTransfer;

        if (balanceAfterTransfer >= _dealData.underlyingDealTokenTotal) {
            underlyingDepositComplete = true;
            purchaseExpiry = block.timestamp + _dealData.purchaseDuration;
            vestingCliffExpiry = purchaseExpiry + _dealData.vestingCliffPeriod;
            vestingExpiry = vestingCliffExpiry + _dealData.vestingPeriod;
            emit DealFullyFunded(address(this), block.timestamp, purchaseExpiry, vestingCliffExpiry, vestingExpiry);
        }

        emit DepositDealToken(_dealData.underlyingDealToken, msg.sender, underlyingDealTokenAmount);
    }

    /**
     * @dev allows holder to withdraw any excess underlying deal tokens deposited to the contract
     */
    function withdrawExcess() external onlyHolder {
        UpFrontDeal memory _dealData = dealData;
        uint256 currentBalance = IERC20(_dealData.underlyingDealToken).balanceOf(address(this));
        require(currentBalance > _dealData.underlyingDealTokenTotal, "no excess to withdraw");

        uint256 excessAmount = currentBalance - _dealData.underlyingDealTokenTotal;
        IERC20(_dealData.underlyingDealToken).transfer(msg.sender, excessAmount);

        emit WithdrewExcess(address(this), excessAmount);
    }

    /**
     * @dev accept deal by depositing purchasing tokens which is converted to a mapping which stores the amount of
     * underlying purchased. pool shares have the same decimals as the underlying deal token
     */
    function acceptDeal(IAelinPool.NftPurchaseList[] calldata _nftPurchaseList, uint256 _purchaseTokenAmount) external lock {
        UpFrontDeal memory _dealData = dealData;
        require(underlyingDepositComplete, "deal token not yet deposited");
        require(block.timestamp < purchaseExpiry, "not in purchase window");
        require(IERC20(_dealData.purchaseToken).balanceOf(msg.sender) >= _purchaseTokenAmount, "not enough purchaseToken");
        uint256 purchaseTokenAmount;

        if (_nftPurchaseList.length > 0) {
            purchaseTokenAmount = _purchaseDealTokensWithNft(_nftPurchaseList, _purchaseTokenAmount);
        } else {
            purchaseTokenAmount = _purchaseDealTokens(_dealData, _purchaseTokenAmount);
        }

        totalPurchasingAccepted += purchaseTokenAmount;
        purchaseTokensPerUser[msg.sender] += purchaseTokenAmount;

        uint8 underlyingTokenDecimals = IERC20Decimals(_dealData.underlyingDealToken).decimals();
        uint256 poolSharesAmount;

        // this takes into account the decimal conversion between purchasing token and underlying deal token
        // pool shares having the same amount of decimals as underlying deal tokens
        poolSharesAmount = (purchaseTokenAmount * 10**underlyingTokenDecimals) / _dealData.purchaseTokenPerDealToken;

        // pool shares directly correspond to the amount of deal tokens that can be minted
        // pool shares held = deal tokens minted as long as no deallocation takes place
        totalPoolShares += poolSharesAmount;
        poolSharesPerUser[msg.sender] += poolSharesAmount;

        if (!_dealData.allowDeallocation) {
            require(totalPoolShares <= _dealData.underlyingDealTokenTotal, "purchased amount over total");
        }

        emit AcceptDeal(
            msg.sender,
            purchaseTokenAmount,
            purchaseTokensPerUser[msg.sender],
            poolSharesAmount,
            poolSharesPerUser[msg.sender]
        );
    }

    /**
     * @dev purchase deal tokens, if purchase cap is reached allow user to purchase up to the max
     * @return uint256 purchase token quantity
     */
    function _purchaseDealTokens(UpFrontDeal memory _dealData, uint256 _purchaseTokenAmount) internal returns (uint256) {
        if (hasAllowList) {
            require(_purchaseTokenAmount <= allowList[msg.sender], "more than allocation");
            allowList[msg.sender] -= _purchaseTokenAmount;
        }

        uint256 balanceBeforeTransfer = IERC20(_dealData.purchaseToken).balanceOf(address(this));
        IERC20(_dealData.purchaseToken).transferFrom(msg.sender, address(this), _purchaseTokenAmount);
        uint256 balanceAfterTransfer = IERC20(_dealData.purchaseToken).balanceOf(address(this));
        uint256 purchaseTokenAmount = balanceAfterTransfer - balanceBeforeTransfer;

        return (purchaseTokenAmount);
    }

    /**
     * @dev
     * @return uint256 purchase token quantity
     */
    function _purchaseDealTokensWithNft(IAelinPool.NftPurchaseList[] calldata _nftPurchaseList, uint256 _purchaseTokenAmount)
        internal
        returns (uint256)
    {
        UpFrontDeal memory _dealData = dealData;
        require(hasNftList, "pool does not have an NFT list");

        uint256 maxPurchaseTokenAmount;

        for (uint256 i = 0; i < _nftPurchaseList.length; i++) {
            IAelinPool.NftPurchaseList memory nftPurchaseList = _nftPurchaseList[i];
            address _collectionAddress = nftPurchaseList.collectionAddress;
            uint256[] memory _tokenIds = nftPurchaseList.tokenIds;

            IAelinPool.NftCollectionRules memory nftCollectionRules = nftCollectionDetails[_collectionAddress];
            require(nftCollectionRules.collectionAddress == _collectionAddress, "collection not in the pool");

            if (nftCollectionRules.purchaseAmountPerToken) {
                maxPurchaseTokenAmount += nftCollectionRules.purchaseAmount * _tokenIds.length;
            }

            if (!nftCollectionRules.purchaseAmountPerToken && nftCollectionRules.purchaseAmount > 0) {
                require(!nftWalletUsedForPurchase[_collectionAddress][msg.sender], "wallet already used for nft set");
                nftWalletUsedForPurchase[_collectionAddress][msg.sender] = true;
                maxPurchaseTokenAmount += nftCollectionRules.purchaseAmount;
            }

            if (nftCollectionRules.purchaseAmount == 0) {
                maxPurchaseTokenAmount = _purchaseTokenAmount;
            }

            if (NftCheck.supports721(_collectionAddress)) {
                _blackListCheck721(_collectionAddress, _tokenIds);
            }
            if (NftCheck.supports1155(_collectionAddress)) {
                _eligibilityCheck1155(_collectionAddress, _tokenIds, nftCollectionRules);
            }
            if (_collectionAddress == CRYPTO_PUNKS) {
                _blackListCheckPunks(_collectionAddress, _tokenIds);
            }
        }

        require(_purchaseTokenAmount <= maxPurchaseTokenAmount, "purchase amount should be less the max allocation");

        uint256 balanceBeforeTransfer = IERC20(_dealData.purchaseToken).balanceOf(address(this));
        IERC20(_dealData.purchaseToken).transferFrom(msg.sender, address(this), _purchaseTokenAmount);
        uint256 balanceAfterTransfer = IERC20(_dealData.purchaseToken).balanceOf(address(this));
        uint256 purchaseTokenAmount = balanceAfterTransfer - balanceBeforeTransfer;

        return (purchaseTokenAmount);
    }

    /**
     * @dev purchaser calls to claim their deal tokens or refund if the minimum raise does not pass
     */
    function purchaserClaim() public lock purchasingOver {
        UpFrontDeal memory _dealData = dealData;

        require(poolSharesPerUser[msg.sender] > 0, "no pool shares to claim with");

        if (_dealData.purchaseRaiseMinimum == 0 || totalPurchasingAccepted > _dealData.purchaseRaiseMinimum) {
            claimDealTokens();
        } else {
            claimRefund();
        }
    }

    /**
     * @dev convert pool shares to deal tokens
     * NOTE deallocation can only be allowed if the purchaseTokenPerDealToken is constant
     */
    function claimDealTokens() internal {
        UpFrontDeal memory _dealData = dealData;

        bool _deallocate = totalPoolShares > _dealData.underlyingDealTokenTotal;

        if (_deallocate) {
            // adjust for deallocation and mint deal tokens
            uint256 _amountOverTotal = totalPoolShares - _dealData.underlyingDealTokenTotal;
            uint256 _adjustedDealTokensForUser = ((BASE - AELIN_FEE - _dealData.sponsorFee) *
                poolSharesPerUser[msg.sender] *
                _amountOverTotal) /
                totalPoolShares /
                10**18;
            poolSharesPerUser[msg.sender] = 0;
            _mint(msg.sender, _adjustedDealTokensForUser);

            // refund any purchase tokens that got deallocated
            uint256 _underlyingTokenDecimals = IERC20Decimals(_dealData.underlyingDealToken).decimals();
            uint256 _totalIntendedRaise = (_dealData.purchaseTokenPerDealToken * _dealData.underlyingDealTokenTotal) /
                10**_underlyingTokenDecimals;
            uint256 _amountOverRaise = totalPurchasingAccepted - _totalIntendedRaise;
            uint256 _purchasingRefund = (100 * purchaseTokensPerUser[msg.sender] * _amountOverRaise) /
                totalPurchasingAccepted;
            purchaseTokensPerUser[msg.sender] = 0;
            IERC20(_dealData.purchaseToken).transfer(msg.sender, _purchasingRefund);

            emit ClaimDealTokens(msg.sender, _adjustedDealTokensForUser, _purchasingRefund);
        } else {
            // mint deal tokens when there is no deallocation
            uint256 _adjustedDealTokensForUser = ((BASE - AELIN_FEE - _dealData.sponsorFee) *
                poolSharesPerUser[msg.sender]) / 10**18;
            poolSharesPerUser[msg.sender] = 0;
            purchaseTokensPerUser[msg.sender] = 0;
            _mint(msg.sender, _adjustedDealTokensForUser);
            emit ClaimDealTokens(msg.sender, _adjustedDealTokensForUser, 0);
        }
    }

    /**
     * @dev refunds all purchase tokens; called if the minimum raise was not reached
     */
    function claimRefund() internal {
        UpFrontDeal memory _dealData = dealData;
        uint256 _currentBalance = purchaseTokensPerUser[msg.sender];
        purchaseTokensPerUser[msg.sender] = 0;
        totalPurchasingAccepted -= _currentBalance;
        IERC20(_dealData.purchaseToken).transfer(msg.sender, _currentBalance);
    }

    /**
     * @dev sponsor calls once the purchasing period is over if the minimum raise has passed to claim
     * their share of deal tokens
     * NOTE also calls the claim for the protocol fee
     */
    function sponsorClaim() public lock purchasingOver passMinimumRaise onlySponsor {
        UpFrontDeal memory _dealData = dealData;
        uint256 _sponsorFeeAmt = (_dealData.underlyingDealTokenTotal * _dealData.sponsorFee) / BASE;
        _mint(_dealData.sponsor, _sponsorFeeAmt);
        emit SponsorClaim(_dealData.sponsor, _sponsorFeeAmt);

        feeEscrowClaim();
    }

    /**
     * @dev holder calls once purchasing period is over to claim their raise or
     * underlying deal tokens if the minimum raise has not passed
     * NOTE also calls the claim for the protocol fee
     */
    function holderClaim() public lock purchasingOver onlyHolder {
        UpFrontDeal memory _dealData = dealData;

        require(!holderClaimed, "holder has already claimed");

        if (_dealData.purchaseRaiseMinimum == 0 || totalPurchasingAccepted > _dealData.purchaseRaiseMinimum) {
            bool _deallocate = totalPoolShares > _dealData.underlyingDealTokenTotal;

            if (_deallocate) {
                uint256 _underlyingTokenDecimals = IERC20Decimals(_dealData.underlyingDealToken).decimals();
                uint256 _totalIntendedRaise = (_dealData.purchaseTokenPerDealToken * _dealData.underlyingDealTokenTotal) /
                    10**_underlyingTokenDecimals;
                IERC20(_dealData.purchaseToken).transfer(_dealData.holder, _totalIntendedRaise);
                emit HolderClaim(_dealData.holder, _dealData.purchaseToken, _totalIntendedRaise, block.timestamp);
            } else {
                // holder receives raise
                uint256 _currentBalance = IERC20(_dealData.purchaseToken).balanceOf(address(this));
                IERC20(_dealData.purchaseToken).transfer(_dealData.holder, _currentBalance);
                emit HolderClaim(_dealData.holder, _dealData.purchaseToken, _currentBalance, block.timestamp);
                // holder receives any leftover underlying deal tokens
                uint256 _underlyingRefund = _dealData.underlyingDealTokenTotal - totalPoolShares;
                IERC20(_dealData.underlyingDealToken).transfer(_dealData.holder, _underlyingRefund);
                emit HolderClaim(_dealData.holder, _dealData.underlyingDealToken, _underlyingRefund, block.timestamp);
            }
        } else {
            uint256 _currentBalance = IERC20(_dealData.underlyingDealToken).balanceOf(address(this));
            IERC20(_dealData.purchaseToken).transfer(_dealData.holder, _currentBalance);
            emit HolderClaim(_dealData.holder, _dealData.underlyingDealToken, _currentBalance, block.timestamp);
        }

        feeEscrowClaim();

        holderClaimed = true;
    }

    /**
     * @dev transfers protocol fee of underlying deal tokens to the treasury escrow contract
     */
    function feeEscrowClaim() public lock purchasingOver {
        UpFrontDeal memory _dealData = dealData;

        if (!feeEscrowClaimed) {
            address aelinEscrowStorageProxy = _cloneAsMinimalProxy(aelinEscrowLogicAddress, "Could not create new escrow");
            aelinFeeEscrow = AelinFeeEscrow(aelinEscrowStorageProxy);
            aelinFeeEscrow.initialize(aelinTreasuryAddress, _dealData.underlyingDealToken);

            uint256 aelinFeeAmt = (_dealData.underlyingDealTokenTotal * AELIN_FEE) / BASE;
            IERC20(_dealData.underlyingDealToken).transfer(address(aelinFeeEscrow), aelinFeeAmt);
        }

        feeEscrowClaimed = true;
    }

    /**
     * @dev purchaser calls after the purchasing period to claim underlying deal tokens
     * amount based on the vesting schedule
     */
    function claimUnderlying() external lock purchasingOver passMinimumRaise {
        UpFrontDeal memory _dealData = dealData;

        uint256 underlyingDealTokensClaimed = claimableUnderlyingTokens(msg.sender);
        if (underlyingDealTokensClaimed > 0) {
            amountVested[msg.sender] += underlyingDealTokensClaimed;
            _burn(msg.sender, underlyingDealTokensClaimed);
            IERC20(_dealData.underlyingDealToken).transfer(msg.sender, underlyingDealTokensClaimed);
            totalUnderlyingClaimed += underlyingDealTokensClaimed;
            emit ClaimedUnderlyingDealToken(msg.sender, _dealData.underlyingDealToken, underlyingDealTokensClaimed);
        }
    }

    /**
     * @dev a view showing the amount of the underlying deal token a purchaser gets in return
     */
    function claimableUnderlyingTokens(address purchaser) public view returns (uint256) {
        UpFrontDeal memory _dealData = dealData;

        uint256 underlyingClaimable = 0;

        uint256 maxTime = block.timestamp > vestingExpiry ? vestingExpiry : block.timestamp;
        if (
            balanceOf(purchaser) > 0 &&
            (maxTime > vestingCliffExpiry || (maxTime == vestingCliffExpiry && _dealData.vestingPeriod == 0))
        ) {
            uint256 timeElapsed = maxTime - vestingCliffExpiry;

            underlyingClaimable = _dealData.vestingPeriod == 0
                ? balanceOf(purchaser)
                : ((balanceOf(purchaser) + amountVested[purchaser]) * timeElapsed) /
                    _dealData.vestingPeriod -
                    amountVested[purchaser];
        }

        return (underlyingClaimable);
    }

    /**
     * @dev the holder may change their address
     */
    function setHolder(address _holder) external onlyHolder {
        futureHolder = _holder;
    }

    function acceptHolder() external {
        require(msg.sender == futureHolder, "only future holder can access");
        dealData.holder = futureHolder;
        emit SetHolder(futureHolder);
    }

    function _blackListCheck721(address _collectionAddress, uint256[] memory _tokenIds) internal {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(IERC721(_collectionAddress).ownerOf(_tokenIds[i]) == msg.sender, "has to be the token owner");
            require(!nftId[_collectionAddress][_tokenIds[i]], "tokenId already used");
            nftId[_collectionAddress][_tokenIds[i]] = true;
        }
    }

    function _eligibilityCheck1155(
        address _collectionAddress,
        uint256[] memory _tokenIds,
        IAelinPool.NftCollectionRules memory nftCollectionRules
    ) internal view {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(nftId[_collectionAddress][_tokenIds[i]], "tokenId not in the pool");
            require(
                IERC1155(_collectionAddress).balanceOf(msg.sender, _tokenIds[i]) >= nftCollectionRules.minTokensEligible[i],
                "erc1155 balance too low"
            );
        }
    }

    function _blackListCheckPunks(address _punksAddress, uint256[] memory _tokenIds) internal {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(ICryptoPunks(_punksAddress).punkIndexToAddress(_tokenIds[i]) == msg.sender, "not the owner");
            require(!nftId[_punksAddress][_tokenIds[i]], "tokenId already used");
            nftId[_punksAddress][_tokenIds[i]] = true;
        }
    }

    /**
     * @dev a function that any Ethereum address can call to vouch for a pool's legitimacy
     */
    function vouch() external {
        emit Vouch(msg.sender);
    }

    /**
     * @dev a function that any Ethereum address can call to disavow for a pool's legitimacy
     */
    function disavow() external {
        emit Disavow(msg.sender);
    }

    modifier onlyHolder() {
        require(msg.sender == dealData.holder);
        _;
    }

    modifier onlySponsor() {
        require(msg.sender == dealData.sponsor);
        _;
    }

    modifier purchasingOver() {
        require(underlyingDepositComplete, "underlying deposit not complete");
        require(block.timestamp > purchaseExpiry, "purchase period not over");
        _;
    }

    modifier passMinimumRaise() {
        require(
            dealData.purchaseRaiseMinimum == 0 || totalPurchasingAccepted > dealData.purchaseRaiseMinimum,
            "does not pass minimum raise"
        );
        _;
    }
}