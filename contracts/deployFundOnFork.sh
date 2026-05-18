docker compose -f ./local-blockchain.yml down
source .env
docker compose -f ./local-blockchain.yml up -d

RPC_URL="http://127.0.0.1:8545" 

echo "Waiting for RPC connection at: $RPC_URL..."
STARTING_BLOCKCHAIN=true
while $STARTING_BLOCKCHAIN; do
  RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$RPC_URL")

  if echo "$RESPONSE" | grep -q '"result"'; then
    echo "" 
    echo "✅ Fork chain online"
    echo "Response: $RESPONSE"
    STARTING_BLOCKCHAIN=false
    break
  else
    echo -n "."
  fi
  sleep 1
done
cast rpc anvil_setBalance $DEPLOYER_ADDRESS  $(cast --to-hex $(cast --to-wei 1000000000 ether)) --rpc-url $RPC_URL
forge script DeployWaveSendFund --rpc-url $RPC_URL --broadcast --gas-price 200000000000
