// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Escrow is Ownable{

    enum STATE { AWAITING_DELIVERY, AWAITING_FUND_RELEASE, COMPLETE }
    struct ProductItem
    {
        string chatRoomNumber;
        string productName;
        string productLink;
        address payable buyer;
        address payable seller;
        uint256 price;
        STATE currentState;
        uint256 createTime;
        uint256 deliverTime;
        bool fundsWithdrawn;
        bool appeal;
    }

    struct ServiceItem
    {
        string chatRoomNumber;
        string serviceName;
        string serviceLink;
        address payable buyer;
        address payable seller;
        uint256 price;
        STATE currentState;
        uint256 createTime;
        uint256 duration;
        uint256 deliverTime;
        bool fundsWithdrawn;
        bool appeal;
    }

    struct CryptoItem
    {
        address payable buyer;
        address payable seller;
        address currency;
        uint8 decimals;
        uint256 amount;
        uint256 price;
        uint256 createTime;
        bool completed;
    }

    address public priceFeedAddress;
    AggregatorV3Interface internal priceFeed;

    mapping(uint256 => ProductItem) public productTrades;
    mapping(uint256 => ServiceItem) public serviceTrades;
    mapping(uint256 => CryptoItem) public cryptoTrades;

    uint256 public currentProductTradeId;
    uint256 public currentServiceTradeId;
    uint256 public currentCryptoTradeId;

    uint256 public constant LOCK_TIME = 300; // 5 min
    address payable public teamWallet1 = payable(0x4b4a0CBB2A7c971D51Ae7dE040a7a290498Df74E);
    address payable public teamWallet2 = payable(0xCb10616fDfd7a5f3e3e144Aad8e7D7821DFAb6A2);
    address payable public teamWallet3 = payable(0x936A0cA35971Fe8A48000829f952e41293ea0DC8);
    address payable public teamWallet4 = payable(0x595F21963feDbc4f5BA4A11b76359dEe916040c0);
    address payable public teamWallet5 = payable(0xd136EB70B571cEf8Db36FAd5be07cB4F76905B64);

    event NewTradeCreated(uint256 tradeId, uint256 category);
    event ProductDelivered(uint256 tradeId, string productLink, uint256 category);
    event FundReleased(uint256 tradeId, uint256 category);
    event AppealRequested(uint256 tradeId, uint256 category);
    event AppealResolved(uint256 tradeId, bool buyerWin, uint256 category);
    event CryptoSold(uint256 cryptoTradeId);

    constructor ()
    {
        // Ethereum mainnet: 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4
        // Rinkeby testnet: 0xdCA36F27cbC4E38aE16C4E9f99D39b42337F6dcf
        priceFeedAddress = 0xdCA36F27cbC4E38aE16C4E9f99D39b42337F6dcf;
        priceFeed = AggregatorV3Interface(priceFeedAddress);
    }

    function getLatestPrice() public view returns (uint256) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    /** 
     * @dev We always start a new trade from this function which will be called by Buyer
     */
    function createNewTrade (string memory _chatRoomNumber, string memory _productName, uint256 _price, address _seller, uint256 _duration, uint256 category) external payable {
        require(msg.value >= _price, "Not enough deposit");
        require(category == 0 || category == 1, "invalid category value");

        if (category == 0) {
            ProductItem memory product;
            product.chatRoomNumber = _chatRoomNumber;
            product.productName = _productName;
            product.price = _price;
            product.buyer = payable(msg.sender);
            product.seller = payable(_seller);
            product.createTime = block.timestamp;
            product.currentState = STATE.AWAITING_DELIVERY;

            currentProductTradeId ++;
            productTrades[currentProductTradeId] = product;

            emit NewTradeCreated(currentProductTradeId, category);
        } else {
            ServiceItem memory service;
            service.chatRoomNumber = _chatRoomNumber;
            service.serviceName = _productName;
            service.price = _price;
            service.buyer = payable(msg.sender);
            service.seller = payable(_seller);
            service.createTime = block.timestamp;
            service.duration = _duration;
            service.currentState = STATE.AWAITING_DELIVERY;

            currentServiceTradeId ++;
            serviceTrades[currentServiceTradeId] = service;

            emit NewTradeCreated(currentServiceTradeId, category);
        }        
    }

    /** 
     * @dev As soon as a new trade is created by Buyer, the seller should deliver the product
     */
    function deliverProduct(uint256 tradeId, string memory _productLink, uint256 category) external {
        require(category == 0 || category == 1, "invalid category value");
        if (category == 0) {
            ProductItem storage product = productTrades[tradeId];
            require(product.seller == msg.sender, "You are not the seller of this trade");
            require(product.currentState == STATE.AWAITING_DELIVERY, "Invalid state");
            
            product.productLink = _productLink;
            product.currentState = STATE.AWAITING_FUND_RELEASE;
            product.deliverTime = block.timestamp;
        } else {
            ServiceItem storage service = serviceTrades[tradeId];
            require(service.seller == msg.sender, "You are not the seller of this trade");
            require(service.currentState == STATE.AWAITING_DELIVERY, "Invalid state");
            require(service.createTime + service.duration >= block.timestamp, "Deadline expired");
            
            service.serviceLink = _productLink;
            service.currentState = STATE.AWAITING_FUND_RELEASE;
            service.deliverTime = block.timestamp;
        }
        emit ProductDelivered(tradeId, _productLink, category);
    }

    /** 
     * @dev The buyer finally check the product and release the fund
     */
    function releaseFunds(uint256 tradeId, uint256 category) external {
        require(category == 0 || category == 1, "invalid category value");
        if (category == 0) {
            ProductItem storage product = productTrades[tradeId];
            require(product.buyer == msg.sender, "You are not the buyer of this trade");
            require(product.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");

            uint256 payAmount = payTax(product.price, true);
            (product.seller).transfer(payAmount);

            product.currentState = STATE.COMPLETE;
            product.fundsWithdrawn = true;
        } else {
            ServiceItem storage service = serviceTrades[tradeId];
            require(service.buyer == msg.sender, "You are not the buyer of this trade");
            require(service.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");

            uint256 payAmount = payTax(service.price, true);
            (service.seller).transfer(payAmount);

            service.currentState = STATE.COMPLETE;
            service.fundsWithdrawn = true;
        }

        emit FundReleased(tradeId, category);
    }

    function payTax(uint256 price, bool success) internal returns(uint256 payAmount) {
        uint256 currentPrice = getLatestPrice();
        uint256 tax1 = currentPrice / 2; // $ 0.5
        uint256 tax2 = currentPrice / 2; // $ 0.5
        uint256 tax3 = currentPrice / 2; // $ 0.5
        uint256 tax4 = currentPrice * 3 / 2; // $ 1.5
        uint256 tax5 = currentPrice * 2; // $ 2

        (teamWallet1).transfer(tax1);
        (teamWallet2).transfer(tax2);
        (teamWallet3).transfer(tax3);
        (teamWallet4).transfer(tax4);
        (teamWallet5).transfer(tax5);

        uint256 tax6;
        if (success)
            tax6 = price / 100;
        else
            tax6 = price / 200;
        payAmount = price - tax1 - tax2 - tax3 - tax4 - tax5 - tax6;
    }

    /** 
     * @dev The buyer review the link and decide to appeal
     */
    function appeal(uint256 tradeId, uint256 category) external {
        require(category == 0 || category == 1, "invalid category value");
        if (category == 0) {
            ProductItem storage product = productTrades[tradeId];
            require(product.buyer == msg.sender, "You are not the buyer of this trade");
            require(product.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");

            product.appeal = true;
        } else {
            ServiceItem storage service = serviceTrades[tradeId];
            require(service.buyer == msg.sender, "You are not the buyer of this trade");
            require(service.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");

            service.appeal = true;
        }
        
        emit AppealRequested(tradeId, category);
    }

    /** 
     * @dev The buyer appealed and the admin review it
     * @param tradeId Id of the trade in which the buyer and seller agreed for the trade
     * @param buyerWin denotes whether buyer won: true for the buyer and false for the seller
     * @param category denotes 0: product, 1: service
     */
    function resolveAppeal(uint256 tradeId, bool buyerWin, uint256 category) external onlyOwner {
        require(category == 0 || category == 1, "invalid category value");
        
        if (category == 0) {
            ProductItem storage product = productTrades[tradeId];
            require(product.appeal, "This trade is not set appeal");
            require(product.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");
            
            // implement tax policy
            uint256 payAmount = payTax(product.price, false);
            if (buyerWin)
                (product.buyer).transfer(payAmount);
            else
                (product.seller).transfer(payAmount);

            product.currentState = STATE.COMPLETE;
        }
        else {
            ServiceItem storage service = serviceTrades[tradeId];
            require(service.appeal, "This trade is not set appeal");
            require(service.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");

            // implement tax policy
            uint256 payAmount = payTax(service.price, false);
            if (buyerWin)
                (service.buyer).transfer(payAmount);
            else
                (service.seller).transfer(payAmount);

            service.currentState = STATE.COMPLETE;
        }
        emit AppealResolved(tradeId, buyerWin, category);
    }

    /** 
     * @dev The seller tries to withdraw funds
     * @param tradeId Id of the trade in which the buyer and seller agreed for the trade
     */
    function getFundsBack(uint256 tradeId) external {
        ServiceItem storage service = serviceTrades[tradeId];
        require(service.createTime + service.duration < block.timestamp, "You should wait until the deadline is met");
        require(service.buyer == msg.sender, "You are not the buyer of this trade");
        require(!service.fundsWithdrawn, "Funds already withdrawn");
        require(service.currentState == STATE.AWAITING_DELIVERY, "Invalid state");
        
        uint256 payAmount = payTax(service.price, false);
        (service.buyer).transfer(payAmount);

        service.fundsWithdrawn = true;
        service.currentState = STATE.COMPLETE;

        emit FundReleased(tradeId, 1);
    }

    /** 
     * @dev The seller tries to withdraw funds
     * @param tradeId Id of the trade in which the buyer and seller agreed for the trade
     */
    function withdrawFunds(uint256 tradeId, uint256 category) external {
        require(category == 0 || category == 1, "invalid category value");
        
        if (category == 0) {
            ProductItem storage product = productTrades[tradeId];
            require(!product.appeal, "This trade is set appeal");
            require(product.seller == msg.sender, "You are not the seller of this trade");
            require(product.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");
            require(!product.fundsWithdrawn, "Funds already withdrawn");
            require(block.timestamp - product.deliverTime >= LOCK_TIME, "Lock time is not passed yet");

            (product.seller).transfer(product.price);

            product.fundsWithdrawn = true;
            product.currentState = STATE.COMPLETE;
        } else {
            ServiceItem storage service = serviceTrades[tradeId];
            require(!service.appeal, "This trade is set appeal");
            require(service.seller == msg.sender, "You are not the seller of this trade");
            require(service.currentState == STATE.AWAITING_FUND_RELEASE, "Invalid state");
            require(!service.fundsWithdrawn, "Funds already withdrawn");
            require(block.timestamp - service.deliverTime >= LOCK_TIME, "Lock time is not passed yet");

            (service.seller).transfer(service.price);

            service.fundsWithdrawn = true;
            service.currentState = STATE.COMPLETE;
        }
        

        emit FundReleased(tradeId, category);
    }

    /** 
     * @dev We always start a new crypto trade from this function which will be called by seller
     * @param _currencyAddress crypto currency address
     * @param _amount amount of crypto currency
     * @param _price price of crypto currency in BNB
     */
    function createNewCryptoTrade (address _currencyAddress, uint256 _amount, uint256 _price) external {
        IERC20Metadata token = IERC20Metadata(_currencyAddress);
        uint256 allowance = token.allowance(msg.sender, address(this));
        require(allowance >= _amount, "Check the token allowance");
        token.transferFrom(msg.sender, address(this), _amount);

        CryptoItem memory cryptoProduct;
        cryptoProduct.seller = payable(msg.sender);
        cryptoProduct.currency = _currencyAddress;
        cryptoProduct.amount = _amount;
        cryptoProduct.price = _price;
        cryptoProduct.createTime = block.timestamp;
        cryptoProduct.decimals = token.decimals();

        currentCryptoTradeId ++;
        cryptoTrades[currentCryptoTradeId] = cryptoProduct;
    }

    /** 
     * @dev Seller already sets the crypto item, now it's time to buy this crypto
     * @param cryptoTradeId crypto trade id
     */
    function buyCrypto (uint256 cryptoTradeId) external payable{
        CryptoItem storage cryptoProduct = cryptoTrades[cryptoTradeId];
        require(msg.value >= cryptoProduct.price, "Not enough paid");
        require(!cryptoProduct.completed, "Already completed");

        // tax policy
        (cryptoProduct.seller).transfer(cryptoProduct.price);

        IERC20Metadata token = IERC20Metadata(cryptoProduct.currency);
        token.transfer(msg.sender, cryptoProduct.amount);

        cryptoProduct.buyer = payable(msg.sender);
        cryptoProduct.completed = true;

        emit CryptoSold(cryptoTradeId);
    }
}