// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


contract Launchpad is Ownable, ReentrancyGuard{
    using SafeMath for uint256;

    enum PoolStatus {
        UPCOMING,
        ONGOING,
        FINISHED
    }

    uint256 private _hardCap;
    uint256 private _startTime;
    uint256 private _endTime;
    IERC20 private _token_address;
    PoolStatus private _status;
    uint256 private _tokenprice;
    uint256 private _tokenamount;
    uint256 private _totalRaised;
    uint8 _decimals;
    address internal initializer;
    mapping(address => uint256) private _balanceOf;
    mapping(address => uint256) private _tokenBalanceOf;


    modifier LaunchpadIsOnGoing() {
        require(_status == PoolStatus.ONGOING, "Pool is not ONGOING");
        _;
    }

    modifier LaunchpadIsFinished() {
        require(_status == PoolStatus.FINISHED, "Pool is not FINISHED");
        _;
    }

    modifier nonZero(uint256 value) {
        require(value > 0, "sender must send some ETH");
        _;
    }

    event LaunchpadUpcoming();
    event LaunchpadOnGoing();
    event LaunchpadFinished();
    event Deposit(address indexed buyer, uint amount);
    event Withdraw(address indexed withdrawer, uint256 token);

    constructor(
    ) {
        initializer = msg.sender;
    }
    
    function initialize(
        uint256 hardCap_,
        uint256 startTime_,
        uint256 endTime_,
        IERC20 token_address_,
        uint8 decimals_,
        uint256 tokenamount_
    ) public {
        require(initializer == msg.sender);

        _hardCap = hardCap_;
        _startTime = startTime_;
        _endTime = endTime_;
        _token_address = token_address_;
        _decimals = decimals_;
        _tokenamount = tokenamount_;
        _tokenprice = _hardCap * (10 ** 18) * (10 ** 18)/ _tokenamount / (10 ** _decimals);
        initializer = address(0);
        emit LaunchpadUpcoming();
    }

    function startTime() public view returns (uint256) {
        return _startTime;
    }

    function endTime() public view returns (uint256) {
        return _endTime;
    }

    function hardCap() public view returns (uint256) {
        return _hardCap;
    }

    function status() public view returns (uint256) {
        return uint256(_status);
    }

    function totalRaised() public view returns (uint256) {
        return _totalRaised;
    }

    function tokenamount() public view returns (uint256) {
        return _tokenamount;
    }

    function tokenprice() public view returns (uint256) {
        return _tokenprice;
    }

    function balanceOf(address addr_) public view returns (uint256) {
        return _balanceOf[addr_];
    }

    function tokenBalanceOf(address addr_) public view returns (uint256) {
        return _tokenBalanceOf[addr_];
    }

    function remain() public view returns (uint256) {
        uint256 _remain = _hardCap - _totalRaised;
        return _remain;
    }

    function updateStatus() external onlyOwner returns (bool) {
        if (
            _startTime < block.timestamp &&
            _endTime > block.timestamp &&
            _status == PoolStatus.UPCOMING
        ) {
            _status = PoolStatus.ONGOING;
            emit LaunchpadOnGoing();
            return true;
        } else if (
            _endTime < block.timestamp && _status == PoolStatus.ONGOING
        ) {
            _status = PoolStatus.FINISHED;
            emit LaunchpadFinished();
            return true;
        }
        return false;
    }

    function deposit()
        external
        payable
        LaunchpadIsOnGoing
        nonZero(msg.value)
        nonReentrant
        returns (bool)
    {
        uint256 value = msg.value;
        require(_totalRaised.add(value) <= _hardCap, "Launchpad is oversubscribed");
        

        _totalRaised = _totalRaised.add(value);
        _balanceOf[msg.sender] = _balanceOf[msg.sender].add(value);

        emit Deposit(msg.sender, msg.value);
        return true;
    }

    function withdraw() external LaunchpadIsFinished nonReentrant returns (bool) {
        uint256 ethersToSpend = _balanceOf[msg.sender];
        require(ethersToSpend > 0, "No amount present to withdraw");

        uint256 tokensToReceive = (ethersToSpend * 10 ** 18 /_tokenprice );


        require(
            (IERC20(_token_address).allowance(owner(), address(this))) >=
                tokensToReceive,
            "Not enough allowance for project tokens"
        );

        IERC20(_token_address).transferFrom(
            owner(),
            msg.sender,
            tokensToReceive
        );

        emit Withdraw(msg.sender, tokensToReceive);
        
        _balanceOf[msg.sender] = 0;
        tokensToReceive = 0;

        
        

        return true;
    } 
    

    function withdrawETH() external LaunchpadIsFinished onlyOwner {
        (bool success, ) = payable(msg.sender).call{
            value: _totalRaised
        }("");

        require(success, "Transfer failed.");
    }

    receive() external payable {}
}