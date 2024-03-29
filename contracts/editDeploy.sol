
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface Claim is IERC20 {    
    function mint(uint256 amount) external;
    function turnToDust() external;
}

interface deployerClaim {
    function deployClaim(string memory name, string memory acronym, address owner) external returns (Claim);
}

interface deployerPool {
        function removePool(address pool) external;        
}

contract Pool is ReentrancyGuard{
    using SafeERC20 for Claim;

    uint256 startDate;
    uint256 settlementDate;

    int256 price;
    address oracleAddress;

    uint256 decayFactor;
    // address decayAddress;
    // address capitalfactorAddress;
    // uint256 capitalFactor;

    uint256 POSmaxRatio;
    uint256 NEGmaxRatio;
    uint256 maxRatioDate;

    bool condition;
    bool withdraw;
    bool settled = false;

    uint256 turnToDustDate;

    uint256 numDepPos = 0;
    uint256 numDepNeg = 0;
    mapping (address => uint) PosAmtDeposited;
    mapping (address => uint) NegAmtDeposited;

    Claim public positiveSide;
    Claim public negativeSide;

    deployerPool public poolDeployer;

    event ClaimsCreated(address POS, address NEG);
    event DepNumNegChanged(uint256 num);
    event DepNumPosChanged(uint256 num);
    event ConditionChanged(bool condition);
    event WithdrawChanged(bool withdraw);
    event pastSettlementDateChanged(bool pastSettlementDate);
    event contractGone(bool gone);

    function getDepNumPOS() public view returns (uint256){
        return(numDepPos);
    }
    function getDepNumNEG() public view returns (uint256){
        return(numDepNeg);
    }
    function getCondition() public view returns (bool){
        return(condition);
    }
    function withdrawOn() public view returns (bool){
        return(withdraw);
    }
    function pastSettlementDate() public view returns (bool){
        return(block.timestamp > settlementDate);
    }
    function getDiscount() public view returns (uint256){
        uint256 temp = (block.timestamp - startDate);
        uint256 discount = temp * decayFactor;
        uint256 amt = (1e12 - discount);
        uint256 ret = (1000*amt)/1e12;
        return(ret);
    }
    
    AggregatorV3Interface public oracle;

    constructor(
        address _oracle, 
        int256 _price, 
        uint256 _settlementDate,
        uint256 _decay, 
        uint256 _POSmaxRatio,
        uint256 _NEGmaxRatio,
        uint256 _maxRatioDate,
        string memory name,
        string memory acronym,
        uint256 _turnToDustDate,
        address deployerContract
        ) 
        {
        startDate = block.timestamp;
        settlementDate = _settlementDate;

        price = _price;
        oracleAddress = _oracle;
        decayFactor = _decay;
        POSmaxRatio = _POSmaxRatio;
        NEGmaxRatio = _NEGmaxRatio;
        maxRatioDate = _maxRatioDate;
        turnToDustDate = _turnToDustDate;

        string memory over = "Over";
        string memory Over = string(bytes.concat(bytes(name), "-", bytes(over)));

        string memory under = "Under";
        string memory Under = string(bytes.concat(bytes(name), "-", bytes(under)));

        string memory Pacr = "POS";
        string memory PAC = string(bytes.concat(bytes(acronym), "-", bytes(Pacr)));

        string memory Nacr = "NEG";
        string memory NAC = string(bytes.concat(bytes(acronym), "-", bytes(Nacr)));

        deployerClaim claimDeployer = deployerClaim(0x2B2f2591DffDF260f43FDE8bC596A3e11814443e);
        //0xdDD8CA978533443a045fC332C2c19Cc7122B07dc -- optimism goerli

        positiveSide = claimDeployer.deployClaim(Over, PAC, address(this));
        negativeSide = claimDeployer.deployClaim(Under, NAC, address(this));

        poolDeployer = deployerPool(deployerContract);

        emit ClaimsCreated(address(positiveSide), address(negativeSide));

        condition = false;

        oracle = AggregatorV3Interface(oracleAddress);
    }

    function depositToPOS() public payable {
        require(block.timestamp < settlementDate, "Current time is after settlement date");
        require(msg.value > 0.001 ether, "Too little ETH deposited");
        
        uint256 temp = (block.timestamp - startDate);
        uint256 discount = temp * decayFactor;
        uint256 amt = (msg.value)*(1e12 - discount);
        uint256 tots = amt/1e12; 

        numDepPos = numDepPos + msg.value;
        PosAmtDeposited[msg.sender] = PosAmtDeposited[msg.sender] + msg.value;

        positiveSide.mint(tots);
        positiveSide.safeTransfer(msg.sender,amt);

        emit DepNumPosChanged(numDepPos);
    }

    function depositToNEG() public payable {
        require(block.timestamp < settlementDate, "Current time is after settlement date");
        require(msg.value > 0.001 ether, "Too little ETH deposited");
        
        negativeSide.mint(msg.value);
        negativeSide.safeTransfer(msg.sender,msg.value);

        uint256 temp = (block.timestamp - startDate);
        uint256 discount = temp * decayFactor;
        uint256 amt = (msg.value)*(1e12 - discount);
        uint256 tots = amt/1e12;

        // if temp = 86,400 1 day, then decay factor = 116,000 to decrease amt by 1% every day
        
        numDepNeg = numDepNeg + msg.value;
        NegAmtDeposited[msg.sender] = NegAmtDeposited[msg.sender] + msg.value;

        negativeSide.mint(tots);
        negativeSide.safeTransfer(msg.sender,amt);

        emit DepNumNegChanged(numDepNeg);
    }

    function settle() public {
        require(block.timestamp > settlementDate, "Current time is before settlement date");
        require(settled == false, "Contract has already been settled");

        (,int256 resultPrice,,,) = oracle.latestRoundData();

        if(resultPrice >= price){
            condition = true;
            emit ConditionChanged(condition);
        }
        settled = true;
        emit pastSettlementDateChanged(true);
    }

    function redeemWithPOS() public nonReentrant{ 
        require(block.timestamp > settlementDate, "Current time is before settlement date");
        require(condition == true,"The POS side did not win");
        require(positiveSide.balanceOf(msg.sender) > 0, "You have no tokens");

        uint256 saved = ((positiveSide.balanceOf(msg.sender)*(address(this).balance))/positiveSide.totalSupply());
        
        positiveSide.safeTransferFrom(msg.sender,address(this),positiveSide.balanceOf(msg.sender));

        (payable(msg.sender)).transfer(saved);
    }

    function redeemWithNEG() public nonReentrant {
        require(block.timestamp > settlementDate, "Current time is before settlement date");
        require(condition == false,"The NEG side did not win");
        require(negativeSide.balanceOf(msg.sender) > 0, "You have no tokens");

        uint256 saved = ((negativeSide.balanceOf(msg.sender)*(address(this).balance))/negativeSide.totalSupply());
        
        negativeSide.safeTransferFrom(msg.sender,address(this),negativeSide.balanceOf(msg.sender));

        (payable(msg.sender)).transfer(saved);
    }

    function turnWithdrawOn() public {
        require(block.timestamp < maxRatioDate, "The Withdrawal Date has passed");
        require(PosAmtDeposited[msg.sender] > 0 ||  NegAmtDeposited[msg.sender] > 0, "You have not deposited any funds");
        require((1000*numDepPos/numDepNeg) > (1000*POSmaxRatio)/NEGmaxRatio, "The minimum ratio has not been met");
        if((1000*numDepPos/numDepNeg) > (1000*POSmaxRatio)/NEGmaxRatio){
            withdraw = true;
            emit WithdrawChanged(withdraw);
        }
    }

    function withdrawWithPOS() public nonReentrant{
        require(withdraw == true,"Withdrawals have not been turned on");
        require(block.timestamp < maxRatioDate, "The Withdrawal Date has passed");
        require(positiveSide.balanceOf(msg.sender) > 0, "You have no tokens");

        if((1000*(numDepPos - PosAmtDeposited[msg.sender]))/(numDepNeg) > (1000*POSmaxRatio)/NEGmaxRatio){
            require(true == false, "You can't withdraw because it would increase the ratio above the max ratio");
        }

        uint256 placeholder = PosAmtDeposited[msg.sender];
        PosAmtDeposited[msg.sender] = 0;
        numDepPos = numDepPos - placeholder;

        positiveSide.safeTransferFrom(msg.sender,address(this),positiveSide.balanceOf(msg.sender));

        (payable(msg.sender)).transfer(placeholder);
        emit DepNumPosChanged(numDepPos);
    }

    function withdrawWithNEG() public nonReentrant{
        require(withdraw == true,"Withdrawals have not been turned on");
        require(block.timestamp < maxRatioDate, "The Withdrawal Date has passed");
        require(negativeSide.balanceOf(msg.sender) > 0, "You have no tokens");

        if(((1000*numDepPos)/(numDepNeg - NegAmtDeposited[msg.sender])) > (1000*POSmaxRatio)/NEGmaxRatio){
            require(true == false, "You can't withdraw because it would increase the ratio above the max ratio");
        }

        uint256 placeholder = NegAmtDeposited[msg.sender];
        NegAmtDeposited[msg.sender] = 0;
        numDepNeg = numDepNeg - placeholder;

        negativeSide.safeTransferFrom(msg.sender,address(this),negativeSide.balanceOf(msg.sender));

        (payable(msg.sender)).transfer(placeholder);
        emit DepNumNegChanged(numDepNeg);

    }

    function turnToDust() public {
        require(block.timestamp > turnToDustDate, "Current time is before Destruction date");

        positiveSide.turnToDust();
        negativeSide.turnToDust();

        poolDeployer.removePool(address(this));

        emit contractGone(true);
        selfdestruct(payable(0x10328D18901bE2278f8105D9ED8a2DbdE08e709f));
    }
}

contract deploy1776 {
    event PoolCreated(
        address _oracle, 
        int256 _price, 
        uint256 _settlementDate,
        uint256 decay,
        uint256 maxRatioPOS,
        uint256 maxRatioNEG,
        uint256 maxRatioDate,
        string name,
        string acronym,
        address poolAddress, 
        uint256 turnToDustDate,
        address deployerContract);

    event PoolRemoved(address poolAddress);

    mapping(address => bool) public poolExists;
    mapping(bytes32 => address) public poolAddresses;

    function createPool(
        address oracle, 
        int256 price, 
        uint256 settlementDate,
        uint256 decay,
        uint256 maxRatioPOS,
        uint256 maxRatioNEG,
        uint256 maxRatioDate,
        string memory name,
        string memory acronym, 
        uint256 turnToDustDate
        ) 

            public returns (address newPool)
            {
                newPool = address(new Pool(oracle,price,settlementDate,decay,maxRatioPOS,maxRatioNEG,maxRatioDate,name,acronym,turnToDustDate,address(this)));
                bytes32 poolHash = keccak256(abi.encodePacked(newPool));
                require(poolAddresses[poolHash] == address(0), "Pool already exists");
                poolExists[newPool] = true;
                poolAddresses[poolHash] = newPool;                
                emit PoolCreated(oracle,price,settlementDate,decay,maxRatioPOS,maxRatioNEG,maxRatioDate,name,acronym,newPool, turnToDustDate, address(this));                
                return(newPool);
            }

        function removePool(address pool) public {
            require(poolExists[pool] == true, "Pool does not exist");
            require(msg.sender == pool, "Only pool itself can remove itself");
            poolExists[pool] = false;
            bytes32 poolHash = keccak256(abi.encodePacked(pool));
            poolAddresses[poolHash] = address(0);
            emit PoolRemoved(pool);
    }
}
