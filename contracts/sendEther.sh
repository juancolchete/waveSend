source .env
cast send $RECIPIENT_ADDRESS --value $SEND_ETHER_VALUE --private-key $DEPLOYER_PRIVATE_KEY --rpc-url http://127.0.0.1:8545 --gas-limit 500000 
