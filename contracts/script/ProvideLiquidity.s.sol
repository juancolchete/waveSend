pragma solidity ^0.8.30;
import "forge-std/Script.sol";
import "forge-std/Test.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ProvideLiquidity is Script, Test {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        
        address celo = 0x471EcE3750Da237f93B8E339c536989b8978a438;
        address wbtc = 0x8aC2901Dd8A1F17a1A4768A6bA4C3751e3995B2D;
        
        vm.deal(admin, 500000 ether); // Deal way more than needed to cover gas!
        deal(wbtc, admin, 100 * 1e8);
        
        vm.startBroadcast(deployerPrivateKey);
        
        IERC20(celo).approve(0x3d79EdAaBC0EaB6F08ED885C05Fc0B014290D95A, type(uint256).max);
        IERC20(wbtc).approve(0x3d79EdAaBC0EaB6F08ED885C05Fc0B014290D95A, type(uint256).max);
        
        INonfungiblePositionManager(0x3d79EdAaBC0EaB6F08ED885C05Fc0B014290D95A).mint(
            INonfungiblePositionManager.MintParams({
                token0: celo,
                token1: wbtc,
                fee: 3000,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: 100000 ether,
                amount1Desired: 100 * 1e8,
                amount0Min: 0,
                amount1Min: 0,
                recipient: admin,
                deadline: block.timestamp + 1000
            })
        );
        
        vm.stopBroadcast();
        
        console.log("Liquidity provided successfully!");
    }
}
