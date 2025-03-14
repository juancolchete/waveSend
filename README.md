# Wave send
The wallet that can send transactions with SMS, super composable and prepared for disasters, crisis and low reliable infraestructure.

## Technical solution
Transactions are signed offline, then are codified in base188 to reduce its size and sms costs, on relay api the transaction is decodified and sent to blockchain.
Users receive the transaction ID and nounce via SMS.

## Verified contract
https://sepolia.scrollscan.com/address/0x0a1baA514fbE93BbCDa420aB43DfB085C70223D4#code

## Deploy WaveSend
Copy enviroment sample 
```
cp env.sample .env
```
Edit environment variable following these tips
```bash
NEXT_PUBLIC_PVK_DEPLOYER=[ETH private key]
TWILLIO_TOKEN=Basic [encoded base64 user:secret]
TWILLIO_ACCOUNT=[twillio account id]
NEXT_PUBLIC_TWILLIO_NUMBER=[twillio number formatted]
```
Install dependecies
```bash
yarn install
```
Build Application
```bash
yarn build
```
Test locally the app
```bash
yarn dev
```
Build your image
```bash
docker build . -f ./Dockerfile -t yourregistry/wavesend:latest
```
Upload to your registry
```bash
docker push yourregistry/wavesend:latest
```
* Deploy app in a cloud and point a DNS to it 
* Configure Twillio webhook to call `/api/relay`
