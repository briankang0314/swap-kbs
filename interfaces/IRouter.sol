pragma solidity 0.8.13;

interface IRouter {
    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
        struct route {
        address from;
        address to;
        bool stable;
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

}
