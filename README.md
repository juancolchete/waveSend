# Wave send
The wallet that can send transactions with SMS, super composable and prepared for disasters, crisis and low reliable infraestructure.

## Technical solution
Transactions are signed offline, then are codified in base188 to reduce its size and sms costs, on relay api the transaction is decodified and sent to blockchain.
Users receive the transaction ID and nounce via SMS.

## Verified contract
https://sepolia.scrollscan.com/address/0x0a1baA514fbE93BbCDa420aB43DfB085C70223D4#code
