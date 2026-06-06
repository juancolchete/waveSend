source .env
cast rpc anvil_impersonateAccount $CELO_WHALE_SENDER
cast send $RECIPIENT_ADDRESS --value $SEND_ETHER_VALUE --from $CELO_WHALE_SENDER --unlocked --rpc-url http://127.0.0.1:8545 --gas-limit 500000