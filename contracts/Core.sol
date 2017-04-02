pragma solidity ^0.4.8;

import "./dependencies/ERC20.sol";
import {ERC20 as Shares} from "./dependencies/ERC20.sol";
import "./assets/AssetProtocol.sol";
import "./dependencies/Owned.sol";
import "./dependencies/SafeMath.sol";
import "./universe/UniverseProtocol.sol";
import "./participation/SubscribeProtocol.sol";
import "./participation/RedeemProtocol.sol";
import "./datafeeds/PriceFeedProtocol.sol";
import "./fees/ManagementFeeProtocol.sol";
import "./fees/PerformanceFeeProtocol.sol";
import "./riskmgmt/RiskMgmtProtocol.sol";
import "./exchange/ExchangeProtocol.sol";

/// @title Core Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple core where referenceAsset is EtherToken and
///   Creation of Shares is done with Ether
contract Core is Shares, SafeMath, Owned {

    // TYPES

    struct CalculatedValues { // last time creation/annihilation of shares happened.
        uint nav;
        uint delta;
        uint atTimestamp;
    }

    struct Modules {
        UniverseProtocol universe;
        SubscribeProtocol subcribe;
        RedeemProtocol redeem;
        RiskMgmtProtocol riskmgmt;
        ManagementFeeProtocol management_fee;
        PerformanceFeeProtocol performance_fee;
    }

    // FIELDS

    // Constant token specific fields
    string public name;
    string public constant symbol = "MLN-P";
    uint public constant decimals = 18;
    // Constant fields
    uint public constant PRICE_OF_ETHER_RELATIVE_TO_REFERENCE_ASSET = 1; // By definition always equal one
    uint public constant BASE_UNIT_OF_SHARES = 10 ** decimals;
    // Fields that are only changed in constructor
    address referenceAsset;
    // Fields that can be changed by functions
    CalculatedValues calculated;
    Modules module;
    uint public sumInvested; // Sum of all investments in Ether
    uint public sumWithdrawn; // Sum of all withdrawals in Ether
    uint public sharePrice = 1 * BASE_UNIT_OF_SHARES;

    // EVENTS

    event SharesCreated(address buyer, uint numShares, uint sharePrice); // Participation
    event SharesAnnihilated(address seller, uint numShares, uint sharePrice);
    event Refund(address to, uint value);
    event NotAllocated(address to, uint value);
    event PortfolioContent(uint assetHoldings, uint assetPrice, uint assetDecimals); // Calcualtions
    event CalculatedValuesUpdated(uint atTimestamp, uint nav, uint delta);
    event NetAssetValueCalculated(uint nav, uint managementFee, uint performanceFee);
    event SpendingApproved(address ofToken, address onExchange, uint amount); // Managing

    // MODIFIERS

    modifier msg_value_at_least(uint x) {
        assert(msg.value >= x);
        _;
    }

    modifier msg_value_past_zero() {
        assert(msg.value > 0);
        _;
    }

    modifier not_zero(uint x) {
        assert(x != 0);
        _;
    }

    modifier balances_msg_sender_at_least(uint x) {
        assert(balances[msg.sender] >= x);
        _;
    }

    modifier this_balance_at_least(uint x) {
        assert(this.balance >= x);
        _;
    }

    modifier less_than_or_equl_to(uint x, uint y) {
        assert(x <= y);
        _;
    }

    // CONSTANT METHDOS

    function getReferenceAsset() constant returns (address) { return referenceAsset; }
    function getUniverseAddress() constant returns (address) { return module.universe; }
    function getSharePrice() constant returns (uint) { return sharePrice; }

    // NON-CONSTANT METHODS

    function Core(
        string withName,
        address ofManager,
        address ofUniverse,
        address ofRiskMgmt,
        address ofManagmentFee,
        address ofPerformanceFee
    ) {
        name = withName;
        owner = ofManager;
        calculated = CalculatedValues({ nav: 0, delta: 1 ether, atTimestamp: now });
        module.universe = UniverseProtocol(ofUniverse);
        referenceAsset = module.universe.getReferenceAsset();
        // Assert referenceAsset is equal to quoteAsset in all assigned PriceFeeds
        uint numAssignedAssets = module.universe.numAssignedAssets();
        for (uint i = 0; i < numAssignedAssets; ++i) {
            PriceFeedProtocol Price = PriceFeedProtocol(address(module.universe.priceFeedAt(i)));
            address quoteAsset = Price.getQuoteAsset();
            assert(referenceAsset == quoteAsset);
        }
        module.riskmgmt = RiskMgmtProtocol(ofRiskMgmt);
        module.management_fee = ManagementFeeProtocol(ofManagmentFee);
        module.performance_fee = PerformanceFeeProtocol(ofPerformanceFee);
    }

    /// Pre: Needed to receive Ether from EtherToken Contract
    /// Post: Receive Either directly
    function() payable {}

    // NON-CONSTANT METHODS - PARTICIPATION

    /// Pre: EtherToken as Asset in Universe
    /// Post: Transfer ownership percentage of all assets from Investor to Core and create shareAmount.
    function createShares(uint shareAmount, uint wantedValue) { createSharesOnBehalf(msg.sender, shareAmount, wantedValue); }

    function createSharesOnBehalf(address recipient, uint shareAmount, uint wantedValue) {
        sharePrice = calcSharePrice(); // TODO Request delivery of new price, instead of historical data
        uint actualValue = sharePrice * shareAmount / BASE_UNIT_OF_SHARES;
        assert(actualValue <= wantedValue); // Protection against price movement/manipulation
        if (calculated.nav == 0) {
          assert(AssetProtocol(referenceAsset).transferFrom(msg.sender, this, actualValue)); // Transfer Ownership of Asset from core to investor
        } else {
          portfolioSlice(shareAmount, true);
        }
        accounting(actualValue, shareAmount, true);
        SharesCreated(msg.sender, shareAmount, sharePrice);
    }

    /// Pre: Sender owns shares, actively running price feed
    /// Post: Transfer ownership percentage of all assets from Core to Investor and annihilate shareAmount.
    function annihilateShares(uint shareAmount, uint wantedValue) { annihilateSharesOnBehalf(msg.sender, shareAmount, wantedValue); }

    function annihilateSharesOnBehalf(address recipient, uint shareAmount, uint wantedValue)
        balances_msg_sender_at_least(shareAmount)
    {
        sharePrice = calcSharePrice(); // TODO Request delivery of new price, instead of historical data
        uint actualValue = sharePrice * shareAmount / BASE_UNIT_OF_SHARES;
        assert(actualValue >= wantedValue); // Protection against price movement/manipulation
        portfolioSlice(shareAmount, false);
        accounting(actualValue, shareAmount, false);
        SharesAnnihilated(msg.sender, shareAmount, sharePrice);
    }

    /// Pre: Approve spending for all non empty coreHoldings of Assets
    /// Pre: Sender owns shares, sharePrice input only needed for accounting purposes, redeem indepent of actively running price feed
    /// Post: Transfer ownership percentage of all assets from Core to Investor and annihilate offered shares.
    function portfolioSlice(uint shareAmount, bool isAllocation)
        internal
    {
        // Transfer ownershipPercentage of Assets
        uint numAssignedAssets = module.universe.numAssignedAssets();
        for (uint i = 0; i < numAssignedAssets; ++i) {
            AssetProtocol Asset = AssetProtocol(address(module.universe.assetAt(i)));
            uint coreHoldings = Asset.balanceOf(this); // Amount of asset base units this core holds
            uint ownershipPercentage = coreHoldings * shareAmount / totalSupply; // ownership percentage of msg.sender
            if (coreHoldings == 0) continue;
            if (isAllocation) assert(Asset.transferFrom(msg.sender, this, ownershipPercentage)); // Transfer Ownership of Asset from core to investor
            else assert(Asset.transfer(msg.sender, ownershipPercentage)); // Transfer Ownership of Asset from core to investor
        }
    }

    /// Post: Acount for investment/withdrawal amount; Create/Annihilate Shares
    function accounting(uint actualValue, uint shareAmount, bool isAllocation)
        internal
    {
        if (isAllocation) {
            sumInvested = safeAdd(sumInvested, actualValue);
            calculated.nav = safeAdd(calculated.nav, actualValue);
            balances[msg.sender] = safeAdd(balances[msg.sender], shareAmount);
            totalSupply = safeAdd(totalSupply, shareAmount);
        } else {
            sumWithdrawn = safeAdd(sumWithdrawn, actualValue);
            calculated.nav = safeSub(calculated.nav, actualValue);
            balances[msg.sender] = safeSub(balances[msg.sender], shareAmount);
            totalSupply = safeSub(totalSupply, shareAmount);
        }
    }

    // NON-CONSTANT METHODS - EXCHANGE

    /// Pre: Sufficient balance and spending has been approved
    /// Post: Make offer on selected Exchange
    function makeOffer(ExchangeProtocol onExchange,
        uint sell_how_much, ERC20 sell_which_token,
        uint buy_how_much,  ERC20 buy_which_token
    )
        only_owner
    {
        assert(isWithinKnownUniverse(onExchange, sell_which_token, buy_which_token));
        assert(module.riskmgmt.isExchangeMakePermitted(onExchange,
            sell_how_much, sell_which_token,
            buy_how_much, buy_which_token)
        );
        approveSpending(sell_which_token, onExchange, sell_how_much);
        onExchange.make(sell_how_much, sell_which_token, buy_how_much, buy_which_token);
    }

    /// Pre: Active offer (id) and valid buy amount on selected Exchange
    /// Post: Take offer on selected Exchange
    function takeOffer(ExchangeProtocol onExchange, uint id, uint wantedBuyAmount)
        only_owner
    {
        // Inverse variable terminology! Buying what another person is selling
        var (
            offeredBuyAmount, offeredBuyToken,
            offeredSellAmount, offeredSellToken
        ) = onExchange.getOrder(id);
        assert(wantedBuyAmount <= offeredBuyAmount);
        assert(isWithinKnownUniverse(onExchange, offeredSellToken, offeredBuyToken));
        assert(module.riskmgmt.isExchangeTakePermitted(onExchange,
            offeredSellAmount, offeredSellToken,
            offeredBuyAmount, offeredBuyToken)
        );
        uint wantedSellAmount = safeMul(wantedBuyAmount, offeredSellAmount) / offeredBuyAmount;
        approveSpending(offeredSellToken, onExchange, wantedSellAmount);
        onExchange.take(id, wantedBuyAmount);
    }

    /// Pre: Active offer (id) with owner of this contract on selected Exchange
    /// Post: Cancel offer on selected Exchange
    function cancel(ExchangeProtocol onExchange, uint id) only_owner { onExchange.cancel(id); }

    /// Pre: Universe has been defined
    /// Post: Whether buying and selling of tokens are allowed at given exchange
    function isWithinKnownUniverse(address onExchange, address sell_which_token, address buy_which_token)
        internal
        returns (bool)
    {
        // Asset pair defined in Universe and contains referenceAsset
        assert(module.universe.assetAvailability(buy_which_token));
        assert(module.universe.assetAvailability(sell_which_token));
        assert(buy_which_token == referenceAsset || sell_which_token == referenceAsset);
        // Exchange assigned to tokens in Universe
        assert(onExchange == module.universe.assignedExchange(buy_which_token));
        assert(onExchange == module.universe.assignedExchange(sell_which_token));
        return true;
    }

    /// Pre: To Exchange needs to be approved to spend Tokens on the Managers behalf
    /// Post: Token specific exchange as registered in universe, approved to spend ofToken
    function approveSpending(ERC20 ofToken, address onExchange, uint amount)
        internal
    {
        assert(ofToken.approve(onExchange, amount));
        SpendingApproved(ofToken, onExchange, amount);
    }

    // NON-CONSTANT METHODS - CORE

    /// Pre: Valid price feed data
    /// Post: Calculate Share Price in Wei and update calculated struct
    function calcSharePrice() returns (uint) { return calcDelta(); }

    /// Pre: Valid price feed data
    /// Post: Delta as a result of current and previous NAV
    function calcDelta() internal returns (uint delta) {
        uint nav = calcNAV();
        // Define or calcualte delta
        if (calculated.nav == 0 || nav == 0) { // First investment not made || First investment made; All funds withdrawn
            delta = 1 ether; // By definition
        } else { // First investment made; Not all funds withdrawn
            delta = (calculated.delta * nav) / calculated.nav;
        }
        // Update CalculatedValues
        calculated = CalculatedValues({ nav: nav, delta: delta, atTimestamp: now });
        CalculatedValuesUpdated(now, nav, delta);
    }

    /// Pre: Valid price feed data
    /// Post: Portfolio Net Asset Value in Wei, managment and performance fee allocated
    function calcNAV() internal returns (uint nav) {
        uint gav = calcGAV(); // Reflects value indepentent of managment and performance fee
        uint timeDifference = now - calculated.atTimestamp;
        uint managementFee = module.management_fee.calculateFee(timeDifference, gav);
        uint performanceFee = 0;
        if (calculated.nav != 0) {
            uint deltaGross = (calculated.delta * gav) / calculated.nav; // Performance (delta) indepentent of managment and performance fees
            uint deltaDifference = deltaGross - calculated.delta;
            performanceFee = module.performance_fee.calculateFee(deltaDifference, gav);
        }
        nav = gav - managementFee - performanceFee;
        NetAssetValueCalculated(nav, managementFee, performanceFee);
    }

    /// Pre: Decimals in Token must be equal to decimals in PriceFeed for all entries in Universe
    /// Post: Portfolio Gross Asset Value in Wei
    /* Rem 1:
     *  All prices are relative to the referenceAsset price. The referenceAsset must be
     *  equal to quoteAsset of corresponding PriceFeed.
     * Rem 2:
     *  For this version, the referenceAsset is set as EtherToken.
     *  The price of the EtherToken relative to Ether is defined to always be equal to one.
     * Rem 3:
     *  price input unit: [Wei / ( Asset * 10**decimals )] == Base unit amount of referenceAsset per base unit of asset
     *  coreHoldings input unit: [Asset * 10**decimals] == Base unit amount of asset this core holds
     *    ==> coreHoldings * price == value of asset holdings of this core relative to referenceAsset price.
     *  where 0 <= decimals <= 18 and decimals is a natural number.
     */
    function calcGAV() internal returns (uint gav) {
        uint numAssignedAssets = module.universe.numAssignedAssets();
        for (uint i = 0; i < numAssignedAssets; ++i) {
            // Holdings
            address ofAsset = address(module.universe.assetAt(i));
            AssetProtocol Asset = AssetProtocol(ofAsset);
            uint assetHoldings = Asset.balanceOf(this); // Amount of asset base units this core holds
            uint assetDecimals = Asset.getDecimals();
            // Price
            PriceFeedProtocol Price = PriceFeedProtocol(address(module.universe.priceFeedAt(i)));
            address quoteAsset = Price.getQuoteAsset();
            assert(referenceAsset == quoteAsset); // See Remark 1
            uint assetPrice;
            if (ofAsset == quoteAsset) {
              assetPrice = 1 * 10 ** assetDecimals; // See Remark 2
            } else {
              assetPrice = Price.getPrice(ofAsset); // Asset price given quoted to referenceAsset (and 'quoteAsset') price
            }
            gav = safeAdd(gav, assetHoldings * assetPrice / (10 ** assetDecimals)); // Sum up product of asset holdings of this core and asset prices
            PortfolioContent(assetHoldings, assetPrice, assetDecimals);
        }
    }
}
