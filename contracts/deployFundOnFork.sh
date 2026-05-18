source .env
docker compose -f ./local-blockchain.yml -d
cast rpc anvil_setBalance $DEPLOYER_ADDRESS  $(cast --to-hex $(cast --to-wei 1000000000 ether)) --rpc-url http://localhost:8545
forge script DeployWaveSendFund --rpc-url http://127.0.0.1:8545 --broadcast --gas-price 200000000000
