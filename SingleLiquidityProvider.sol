// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IPair} from "./interfaces/IPair.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Babylonian} from "./libraries/Babylonian.sol";

/*
 * @author Inspiration from the work of Slpper and Beefy.
 * Implemented and modified by EasySwap teams.
 */
contract SingleLiquidityProvider is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Interface for Wrapped ETH (WETH)
    IWETH public WETH;

    // EasyRouter interface
    IRouter public EasyRouter;

    // Maximum integer (used for managing allowance)
    uint256 public constant MAX_INT = 2**256 - 1;

    // Minimum amount for a swap (derived from EasySwap)
    uint256 public constant MINIMUM_AMOUNT = 1000;

    // Maximum reverse slp ratio (100 --> 1%, 1000 --> 0.1%)
    uint256 public maxSlpReverseRatio;

    // Address EasyRouter
    address private EasyRouterAddress;

    // Address Wrapped ETH (WETH)
    address private WETHAddress;

    //Route Struct
    struct Route {
        address from;
        address to;
        bool stable;
    }

    Route[] public routes;


    // Owner recovers token
    event AdminTokenRecovery(address indexed tokenAddress, uint256 amountTokens);

    // Owner changes the maxSlpReverseRatio
    event NewMaxSlpReverseRatio(uint256 maxSlpReverseRatio);

    // tokenToSlp = 0x00 address if ETH
    event SlpIn(
        address indexed tokenToSlp,
        address indexed lpToken,
        uint256 tokenAmountIn,
        uint256 lpTokenAmountReceived,
        address indexed user
    );

    // token0ToSlp = 0x00 address if ETH
    event SlpInRebalancing(
        address indexed token0ToSlp,
        address indexed token1ToSlp,
        address lpToken,
        uint256 token0AmountIn,
        uint256 token1AmountIn,
        uint256 lpTokenAmountReceived,
        address indexed user
    );

    // tokenToReceive = 0x00 address if ETH
    event SlpOut(
        address indexed lpToken,
        address indexed tokenToReceive,
        uint256 lpTokenAmount,
        uint256 tokenAmountReceived,
        address indexed user
    );

    /*
     * @notice Fallback for WETH
     */
    receive() external payable {
        assert(msg.sender == WETHAddress);
    }

    /*
     * @notice Constructor
     * @param _WETHAddress: address of the WETH contract
     * @param _EasyRouter: address of the EasyRouter
     * @param _maxSlpReverseRatio: maximum slp ratio
     */
    constructor(
        address _WETHAddress,
        address _EasyRouter,
        uint256 _maxSlpReverseRatio
    ) {
        WETHAddress = _WETHAddress;
        WETH = IWETH(_WETHAddress);
        EasyRouterAddress = _EasyRouter;
        EasyRouter = IRouter(_EasyRouter);
        maxSlpReverseRatio = _maxSlpReverseRatio;
    }

    /*
     * @notice Slp ETH in a WETH pool (e.g. WETH/token)
     * @param _lpToken: LP token address (e.g. Easy/ETH)
     * @param _tokenAmountOutMin: minimum token amount (e.g. Easy) to receive in the intermediary swap (e.g. ETH --> Easy)
     */
    function slpInETH(address _lpToken, uint256 _tokenAmountOutMin,uint slippagetolerance) external payable nonReentrant {
        WETH.deposit{value: msg.value}();

        // Call slp function
        uint256 lpTokenAmountTransferred = _slpIn(WETHAddress, msg.value, _lpToken, _tokenAmountOutMin, slippagetolerance);

        // Emit event
        emit SlpIn(
            address(0x0000000000000000000000000000000000000000),
            _lpToken,
            msg.value,
            lpTokenAmountTransferred,
            address(msg.sender)
        );
    }

    /*
     * @notice Slp a token in (e.g. token/other token)
     * @param _tokenToSlp: token to slp
     * @param _tokenAmountIn: amount of token to swap
     * @param _lpToken: LP token address (e.g. Easy/BUSD)
     * @param _tokenAmountOutMin: minimum token to receive (e.g. Easy) in the intermediary swap (e.g. BUSD --> Easy)
     */
    function slpInToken(
        address _tokenToSlp,
        uint256 _tokenAmountIn,
        address _lpToken,
        uint256 _tokenAmountOutMin,
        uint slippagetolerance
    ) external nonReentrant {
        // Transfer tokens to this contract
        IERC20(_tokenToSlp).safeTransferFrom(address(msg.sender), address(this), _tokenAmountIn);

        // Call slp function
        uint256 lpTokenAmountTransferred = _slpIn(_tokenToSlp, _tokenAmountIn, _lpToken, _tokenAmountOutMin, slippagetolerance);

        // Emit event
        emit SlpIn(_tokenToSlp, _lpToken, _tokenAmountIn, lpTokenAmountTransferred, address(msg.sender));
    }
    

    /*
     * @notice Slp a LP token out to receive ETH
     * @param _lpToken: LP token address (e.g. Easy/WETH)
     * @param _lpTokenAmount: amount of LP tokens to slp out
     * @param _tokenAmountOutMin: minimum amount to receive (in ETH/WETH) in the intermediary swap (e.g. Easy --> ETH)
     */
    function slpOutETH(
        address _lpToken,
        uint256 _lpTokenAmount,
        uint256 _tokenAmountOutMin
    ) external nonReentrant {
        // Transfer LP token to this address
        IERC20(_lpToken).safeTransferFrom(address(msg.sender), address(_lpToken), _lpTokenAmount);

        // Call slpOut
        uint256 tokenAmountToTransfer = _slpOut(_lpToken, WETHAddress, _tokenAmountOutMin);

        // Unwrap ETH
        WETH.withdraw(tokenAmountToTransfer);

        // Transfer ETH to the msg.sender
        (bool success, ) = msg.sender.call{value: tokenAmountToTransfer}(new bytes(0));
        require(success, "ETH: transfer fail");

        // Emit event
        emit SlpOut(
            _lpToken,
            address(0x0000000000000000000000000000000000000000),
            _lpTokenAmount,
            tokenAmountToTransfer,
            address(msg.sender)
        );
    }

    /*
     * @notice Slp a LP token out (to receive a token)
     * @param _lpToken: LP token address (e.g. Easy/BUSD)
     * @param _tokenToReceive: one of the 2 tokens from the LP (e.g. Easy or BUSD)
     * @param _lpTokenAmount: amount of LP tokens to slp out
     * @param _tokenAmountOutMin: minimum token to receive (e.g. Easy) in the intermediary swap (e.g. BUSD --> Easy)
     */
    function slpOutToken(
        address _lpToken,
        address _tokenToReceive,
        uint256 _lpTokenAmount,
        uint256 _tokenAmountOutMin
    ) external nonReentrant {
        // Transfer LP token to this address
        IERC20(_lpToken).safeTransferFrom(address(msg.sender), address(_lpToken), _lpTokenAmount);

        uint256 tokenAmountToTransfer = _slpOut(_lpToken, _tokenToReceive, _tokenAmountOutMin);

        IERC20(_tokenToReceive).safeTransfer(address(msg.sender), tokenAmountToTransfer);

        emit SlpOut(_lpToken, _tokenToReceive, _lpTokenAmount, tokenAmountToTransfer, msg.sender);
    }

    /**
     * @notice It allows the owner to change the risk parameter for quantities
     * @param _maxSlpInverseRatio: new inverse ratio
     * @dev This function is only callable by owner.
     */
    function updateMaxSlpInverseRatio(uint256 _maxSlpInverseRatio) external onlyOwner {
        maxSlpReverseRatio = _maxSlpInverseRatio;
        emit NewMaxSlpReverseRatio(_maxSlpInverseRatio);
    }

    /**
     * @notice It allows the owner to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw (18 decimals)
     * @param _tokenAmount: the number of token amount to withdraw
     * @dev This function is only callable by owner.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);
        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice View the details for single slp
     * @dev Use WETH for _tokenToSlp (if ETH is the input)
     * @param _tokenToSlp: address of the token to slp
     * @param _tokenAmountIn: amount of token to slp inputed
     * @param _lpToken: address of the LP token
     * @return swapAmountIn: amount that is expected to get swapped in intermediary swap
     * @return swapAmountOut: amount that is expected to get received in intermediary swap
     * @return swapTokenOut: token address of the token that is used in the intermediary swap
     */
    function estimateSlpInSwap(
        address _tokenToSlp,
        uint256 _tokenAmountIn,
        address _lpToken
    )
        external
        view
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut,
            address swapTokenOut
        )
    {
        address token0 = IPair(_lpToken).token0();
        address token1 = IPair(_lpToken).token1();

        require(_tokenToSlp == token0 || _tokenToSlp == token1, "Slp: Wrong tokens");

        if (token0 == _tokenToSlp) {
            swapTokenOut = token1;
            swapAmountIn = _calculateAmountToSwap(_lpToken, _tokenAmountIn);
            (swapAmountOut, ) = EasyRouter.getAmountOut(swapAmountIn, token0, token1);
        } else {
            swapTokenOut = token0;
            swapAmountIn = _calculateAmountToSwap(_lpToken, _tokenAmountIn);
            (swapAmountOut, ) = EasyRouter.getAmountOut(swapAmountIn, token1, token0);
        }

        return (swapAmountIn, swapAmountOut, swapTokenOut);
    }

    

    /*
     * @notice View the details for single slp
     * @dev Use WETH for _tokenToReceive (if ETH is the asset to be received)
     * @param _lpToken: address of the LP token to slp out
     * @param _lpTokenAmount: amount of LP token to slp out
     * @param _tokenToReceive: token address to receive
     * @return swapAmountIn: amount that is expected to get swapped for intermediary swap
     * @return swapAmountOut: amount that is expected to get received for intermediary swap
     * @return swapTokenOut: address of the token that is sold in the intermediary swap
     */
    function estimateSlpOutSwap(
        address _lpToken,
        uint256 _lpTokenAmount,
        address _tokenToReceive
    )
        external
        view
        returns (
            uint256 swapAmountIn,
            uint256 swapAmountOut,
            address swapTokenOut
        )
    {
        address token0 = IPair(_lpToken).token0();
        address token1 = IPair(_lpToken).token1();

        require(_tokenToReceive == token0 || _tokenToReceive == token1, "Slp: Token not in LP");

        // Convert to uint256 (from uint112)
        (uint256 reserveA, uint256 reserveB, ) = IPair(_lpToken).getReserves();

        if (token1 == _tokenToReceive) {
            // sell token0
            uint256 tokenAmountIn = (_lpTokenAmount * reserveA) / IPair(_lpToken).totalSupply();

            swapAmountIn = _calculateAmountToSwap(_lpToken, tokenAmountIn * 2);
            (swapAmountOut, ) = EasyRouter.getAmountOut(swapAmountIn, token0, token1);

            swapTokenOut = token0;
        } else {
            // sell token1
            uint256 tokenAmountIn = (_lpTokenAmount * reserveB) / IPair(_lpToken).totalSupply();

            swapAmountIn = _calculateAmountToSwap(_lpToken, tokenAmountIn * 2);
            (swapAmountOut, ) = EasyRouter.getAmountOut(swapAmountIn, token1, token0);

            swapTokenOut = token1;
        }

        return (swapAmountIn, swapAmountOut, swapTokenOut);
    }

    /*
     * @notice Slp a token in (e.g. token/other token)
     * @param _tokenToSlp: token to slp
     * @param _tokenAmountIn: amount of token to swap
     * @param _lpToken: LP token address
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     */

    // PeckShield - 3.2.
    function _slpIn(
        address _tokenToSlp,
        uint256 _tokenAmountIn,
        address _lpToken,
        uint256 _tokenAmountOutMin,
        uint slippagetolerance
    ) internal returns (uint256 lpTokenReceived) {



        // Retrieve the path
        IRouter.route[] memory routerRoutes = new IRouter.route[](1);
        

        routerRoutes[0].from = _tokenToSlp;

        // Initiates an estimation to swap
        uint256 swapAmountIn;

        {
            // Convert to uint256 (from uint112)
            (uint256 reserveA, uint256 reserveB, ) = IPair(_lpToken).getReserves();

            require((reserveA >= MINIMUM_AMOUNT) && (reserveB >= MINIMUM_AMOUNT), "Slp: Reserves too low");

            if (IPair(_lpToken).token0() == _tokenToSlp) {
                swapAmountIn = _calculateAmountToSwap(_lpToken, _tokenAmountIn);
                routerRoutes[0].to = IPair(_lpToken).token1();
                if(_tokenToSlp != WETHAddress){
                require(reserveA / swapAmountIn >= maxSlpReverseRatio, "Slp: Quantity higher than limit");
                }
            } else if (IPair(_lpToken).token1() == _tokenToSlp){
                swapAmountIn = _calculateAmountToSwap(_lpToken, _tokenAmountIn);
                routerRoutes[0].to = IPair(_lpToken).token0();
                if(_tokenToSlp != WETHAddress){
                require(reserveB / swapAmountIn >= maxSlpReverseRatio, "Slp: Quantity higher than limit");
                }
            } else {
                require(_tokenToSlp == IPair(_lpToken).token0() || _tokenToSlp == IPair(_lpToken).token1(), "Slp: Wrong tokens");

            }
        }
        _approveTokenIfNeeded(routerRoutes[0].from);
        _approveTokenIfNeeded(routerRoutes[0].to);


        routerRoutes[0].stable = IPair(_lpToken).isstable();

        {
        uint256[] memory swapedAmounts = EasyRouter.swapExactTokensForTokens(
            swapAmountIn,
            _tokenAmountOutMin,
            routerRoutes,
            address(this),
            block.timestamp + 600
        );
        uint256 amountin = _tokenAmountIn - swapedAmounts[0];

        // Add liquidity and retrieve the amount of LP received by the sender
        (, , lpTokenReceived) = EasyRouter.addLiquidity(
            routerRoutes[0].from,
            routerRoutes[0].to,
            routerRoutes[0].stable,
            amountin,
            swapedAmounts[1],
            amountin * slippagetolerance / 10000,
            swapedAmounts[1] * slippagetolerance /10000,
            address(msg.sender),
            block.timestamp
        );
    }

        return lpTokenReceived;
    }

    /*
     * @notice Slp two tokens in, rebalance them to 50-50, before adding them to LP
     * @param _token0ToSlp: address of token0 to slp
     * @param _token1ToSlp: address of token1 to slp
     * @param _token0AmountIn: amount of token0 to slp
     * @param _token1AmountIn: amount of token1 to slp
     * @param _lpToken: LP token address
     * @param _tokenAmountInMax: maximum token amount to sell (in token to sell in the intermediary swap)
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     */

    /*
     * @notice Slp a LP token out to a token (e.g. token/other token)
     * @param _lpToken: LP token address
     * @param _tokenToReceive: token address
     * @param _tokenAmountOutMin: minimum token to receive in the intermediary swap
     */
    function _slpOut(
        address _lpToken,
        address _tokenToReceive,
        uint256 _tokenAmountOutMin
    ) internal returns (uint256) {
        
        address token0 = IPair(_lpToken).token0();
        address token1 = IPair(_lpToken).token1();

        require(_tokenToReceive == token0 || _tokenToReceive == token1, "Slp: Token not in LP");

        // Burn all LP tokens to receive the two tokens to this address
        (uint256 amount0, uint256 amount1) = IPair(_lpToken).burn(address(this));

        if(token0 != WETHAddress || token1 != WETHAddress){
        require(amount0 >= MINIMUM_AMOUNT, "EasyRouter: INSUFFICIENT_A_AMOUNT");
        require(amount1 >= MINIMUM_AMOUNT, "EasyRouter: INSUFFICIENT_B_AMOUNT");
        }

        IRouter.route[] memory routerRoutes = new IRouter.route[](1);
        routerRoutes[0].to = _tokenToReceive;

        uint256 swapAmountIn;

        if (token0 == _tokenToReceive) {
            routerRoutes[0].from = token1;
            swapAmountIn = IERC20(token1).balanceOf(address(this));

            // Approve token to sell if necessary
            _approveTokenIfNeeded(token1);
        } else {
            routerRoutes[0].from = token0;
            swapAmountIn = IERC20(token0).balanceOf(address(this));

            // Approve token to sell if necessary
            _approveTokenIfNeeded(token0);
        }

        // Swap tokens
        EasyRouter.swapExactTokensForTokens(swapAmountIn, _tokenAmountOutMin, routerRoutes, address(this), block.timestamp);

        // Return full balance for the token to receive by the sender
        return IERC20(_tokenToReceive).balanceOf(address(this));
    }

    /*
     * @notice Allows to slp a token in (e.g. token/other token)
     * @param _token: token address
     */
    function _approveTokenIfNeeded(address _token) private {
        if (IERC20(_token).allowance(address(this), EasyRouterAddress) < 1e24) {
            // Re-approve
            IERC20(_token).safeApprove(EasyRouterAddress, MAX_INT);
        }
    }

    /*
     * @notice Calculate the swap amount to get the price at 50/50 split
     * @param _token0AmountIn: amount of token 0
     * @param _reserve0: amount in reserve for token0
     * @param _reserve1: amount in reserve for token1
     * @return amountToSwap: swapped amount (in token0)
     */
    function _calculateAmountToSwap(
        address _lpToken,
        uint256 _token0AmountIn
    ) private view returns (uint256 amountToSwap) {
        (uint256 _reserve0, uint256 _reserve1, ) = IPair(_lpToken).getReserves();
        address _token0 = IPair(_lpToken).token0();
        address _token1 = IPair(_lpToken).token1();
        uint256 halfToken0Amount = _token0AmountIn / 2;
        uint256 nominator;
        (nominator, ) = EasyRouter.getAmountOut(halfToken0Amount, _token0, _token1);
        uint256 denominator = halfToken0Amount * (_reserve1 - nominator) / (_reserve0 + halfToken0Amount);
        // Adjustment for price impact
        amountToSwap =
            _token0AmountIn -
            Babylonian.sqrt((halfToken0Amount * halfToken0Amount * nominator) / denominator);

        return amountToSwap;
    }

    function calculateAmountToSwap(
        address _lpToken,
        uint256 _token0AmountIn,
        address _tokenIn
    ) public view returns (uint256 amountToSwap) {
        address _token0 = IPair(_lpToken).token0();
        address _token1 = IPair(_lpToken).token1();
        
        if (_tokenIn == _token0){
        (uint256 _reserve0, uint256 _reserve1, ) = IPair(_lpToken).getReserves();

        uint256 halfToken0Amount = _token0AmountIn / 2;
        uint256 nominator;
        (nominator, ) = EasyRouter.getAmountOut(halfToken0Amount, _token0, _token1);
        uint256 denominator = halfToken0Amount * (_reserve1 - nominator) / (_reserve0 + halfToken0Amount);
        // Adjustment for price impact
        amountToSwap =
            _token0AmountIn -
            Babylonian.sqrt((halfToken0Amount * halfToken0Amount * nominator) / denominator);

        return amountToSwap;

        }

        else if (_tokenIn == _token1){
        (uint256 _reserve1, uint256 _reserve0, ) = IPair(_lpToken).getReserves();

        uint256 halfToken0Amount = _token0AmountIn / 2;
        uint256 nominator;
        (nominator, ) = EasyRouter.getAmountOut(halfToken0Amount, _token1, _token0);
        uint256 denominator = halfToken0Amount * (_reserve0 - nominator) / (_reserve1 + halfToken0Amount);
        // Adjustment for price impact
        amountToSwap =
            _token0AmountIn -
            Babylonian.sqrt((halfToken0Amount * halfToken0Amount * nominator) / denominator);

        return amountToSwap;


        }
    }
    /*
     * @notice Calculate the amount to swap to get the tokens at a 50/50 split
     * @param _token0AmountIn: amount of token 0
     * @param _token1AmountIn: amount of token 1
     * @param _reserve0: amount in reserve for token0
     * @param _reserve1: amount in reserve for token1
     * @param _isToken0Sold: whether token0 is expected to be sold (if false, sell token1)
     * @return amountToSwap: swapped amount in token0 (if _isToken0Sold is true) or token1 (if _isToken0Sold is false)
     */
    
}