pragma solidity ^0.8.30;
import "forge-std/Test.sol";
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
contract CeloTransferTest is Test {
    function test_transfer() public {
        address celo = 0x471EcE3750Da237f93B8E339c536989b8978a438;
        vm.deal(address(this), 10 ether);
        IERC20(celo).approve(address(this), 5 ether);
        IERC20(celo).transferFrom(address(this), address(0x123), 5 ether);
        console.log("Success!");
    }
}
