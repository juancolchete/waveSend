"use client"

import type React from "react"
import { useEffect, useState } from "react"
import { Send, Wallet, Copy, Check } from "lucide-react"
import contracts from "@/contracts.json"
import { Button } from "./components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "./components/ui/card"
import { Input } from "./components/ui/input"
import { Label } from "./components/ui/label"
import { useToast } from "./components/ui/use-toast"
import { NetworkSelector, type Network } from "./components/network-selector"
import { getRawErc20, getRawETH } from "@/data"
import { ethers } from "ethers"
import { chains } from "@/constants"
import { getContract, formatEther, createPublicClient, http, parseUnits } from "viem";
import { celo } from "viem/chains";
import { stableTokenABI } from "@celo/abis";
import { createWalletClient, custom, encodeFunctionData } from "viem";



interface TransactionFormProps {
  isWalletConnected?: boolean,
  connectedType?: string
}

export default function TransactionForm({ isWalletConnected = false, connectedType = "" }: TransactionFormProps) {
  const [chain, setChain] = useState(42220)
  const [currency, setCurrency] = useState("CELO");
  const [balUSDm, setBalUSDm] = useState(0);
  const [amount, setAmount] = useState("")
  const [receiverWallet, setReceiverWallet] = useState("")
  const [nounce, setNounce] = useState("0")
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [selectedNetwork, setSelectedNetwork] = useState<Network>({
    id: "celo",
    name: "Celo",
    icon: "/celo.png?height=32&width=32",
  })
  const [showConfirmation, setShowConfirmation] = useState(false)
  const [smsMessage, setSmsMessage] = useState("")
  const [copiedToClipboard, setCopiedToClipboard] = useState(false)
  const { toast } = useToast()

  const handleNetworkChange = (network: Network) => {
    setSelectedNetwork(network)
  }

  const handleSetNounce = (nounce: string) => {
    setNounce(nounce)
    sessionStorage.setItem(`nounce${chain}`, nounce)
  }

  useEffect(() => {
    if (window) {
      const sNounce = sessionStorage.getItem(`nounce${chain}`)
      if (sNounce) {
        setNounce(sNounce)
      }
    }
    if (connectedType == "MiniPay") {
      setCurrency("USDm")
      const STABLE_TOKEN_ADDRESS = "0x765DE816845861e75A25fCA122bb6898B8B1282a";

      async function checkUSDmBalance() {
        const publicClient = createPublicClient({
          chain: celo,
          transport: http(),
        });
        const StableTokenContract = getContract({
          abi: stableTokenABI,
          address: STABLE_TOKEN_ADDRESS,
          client: publicClient,
        });
        const client = createWalletClient({
          chain: celo,
          transport: custom((window as any).ethereum),
        });
        const [address] = await client.request({ method: 'eth_requestAccounts' });

        const balanceInBigNumber = await StableTokenContract.read.balanceOf([
          address,
        ]);

        const balanceInEthers = formatEther(balanceInBigNumber);

        setBalUSDm(Number(balanceInEthers));
      }
      checkUSDmBalance();

    } else {
      setCurrency("CELO")
    }
  }, [chain, connectedType]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    if (!isWalletConnected && !connectedType) {
      toast({
        variant: "destructive",
        title: "Wallet not connected",
        description: "Please connect your wallet to send transactions",
      })
      return
    }

    // Basic validation
    if (!amount || isNaN(Number(amount)) || Number(amount) <= 0) {
      toast({
        variant: "destructive",
        title: "Invalid amount",
        description: "Please enter a valid WSND amount",
      })
      return
    }

    if (!receiverWallet || receiverWallet.length < 10) {
      toast({
        variant: "destructive",
        title: "Invalid wallet address",
        description: "Please enter a valid receiver wallet address",
      })
      return
    }

    setIsSubmitting(true)

    if (connectedType == "MiniPay") {
      const [account] = await (window as any).ethereum!.request({
        method: 'eth_requestAccounts'
      });
      const walletClient = createWalletClient({
        account,
        chain: celo, // For mainnet
        transport: custom((window as any).ethereum!),
      });

      const publicClient = createPublicClient({
        chain: celo, // For mainnet
        transport: http(),
      });

      async function requestTransfer(tokenAddress: any, transferValue: any, tokenDecimals: any, receiverAddress: any) {
        const hash = await walletClient.sendTransaction({
          to: tokenAddress,
          data: encodeFunctionData({
            abi: stableTokenABI, // Token ABI from @celo/abis
            functionName: "transfer",
            args: [
              receiverAddress,
              // Different tokens can have different decimals, USDm (18), USDC (6)
              parseUnits(`${Number(transferValue)}`, tokenDecimals),
            ],
          }),
        } as any);

        const transaction = await publicClient.waitForTransactionReceipt({
          hash, // Transaction hash that can be used to search transaction on the explorer.
        });

        if (transaction.status === "success") {
          // Do something after transaction is successful.
        } else {
          // Do something after transaction has failed.
        }
      }
      const STABLE_TOKEN_ADDRESS = "0x765DE816845861e75A25fCA122bb6898B8B1282a";
      requestTransfer(STABLE_TOKEN_ADDRESS, amount, 18, receiverWallet)
    } else {
      try {
        // Simulate processing (replace with actual offline transaction logic)
        await new Promise((resolve) => setTimeout(resolve, 1500))
        const privateKey = sessionStorage.getItem("pvk")
        let nounce = sessionStorage.getItem(`nounce${chain}`)
        if (!nounce) {
          sessionStorage.setItem(`nounce${chain}`, "0")
          nounce = sessionStorage.getItem(`nounce${chain}`)
        }
        if (privateKey && nounce) {
          if (currency == "WSND") {
            getRawErc20(chains[chain].token, ethers.parseEther(amount), receiverWallet, chain, parseInt(nounce), privateKey)
          } else {
            getRawETH(chains[chain].token, ethers.parseEther(amount), receiverWallet, chain, parseInt(nounce), privateKey)
          }
          sessionStorage.setItem(`nounce${chain}`, `${parseInt(nounce) + 1}`)
          setNounce(`${parseInt(nounce) + 1}`)
        }
        const txnRawEnc = sessionStorage.getItem("txnRawEnc")
        // Create transaction message
        const transactionMessage = `${txnRawEnc}`

        // Show confirmation dialog instead of immediately opening SMS
        setSmsMessage(transactionMessage)
        setShowConfirmation(true)
      } catch (err) {
        toast({
          variant: "destructive",
          title: "Transaction failed",
          description: "There was an error preparing your transaction.",
        })
        console.error("Transaction error:", err)
      } finally {
        setIsSubmitting(false)
      }

    }
  }

  const handleCopySMS = async () => {
    try {
      await navigator.clipboard.writeText(smsMessage)
      setCopiedToClipboard(true)
      setTimeout(() => setCopiedToClipboard(false), 2000)
      toast({
        title: "Copied!",
        description: "Message copied to clipboard",
      })
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Copy failed",
        description: "Could not copy message to clipboard",
      })
    }
  }

  const handleOpenSMS = () => {
    window.open(`sms:${process.env.NEXT_PUBLIC_TWILLIO_NUMBER}`)
    setShowConfirmation(false)
  }

  return (
    <>
      {showConfirmation && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <Card className="w-full max-w-sm">
            <CardHeader>
              <CardTitle>Confirm Transaction</CardTitle>
              <CardDescription>Your transaction details are ready to send via SMS</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <Label>Transaction Code</Label>
                <div className="relative">
                  <div className="bg-gray-50 dark:bg-gray-900 p-3 rounded-md border border-gray-200 dark:border-gray-800 break-all text-sm font-mono">
                    {smsMessage.substring(0, 100)}
                    {smsMessage.length > 100 && "..."}
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="mt-2 w-full"
                    onClick={handleCopySMS}
                  >
                    {copiedToClipboard ? (
                      <>
                        <Check className="h-4 w-4 mr-2" />
                        Copied!
                      </>
                    ) : (
                      <>
                        <Copy className="h-4 w-4 mr-2" />
                        Copy to Clipboard
                      </>
                    )}
                  </Button>
                </div>
              </div>
              <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-md p-3 text-sm text-blue-800 dark:text-blue-200">
                This code will be sent via SMS to {process.env.NEXT_PUBLIC_TWILLIO_NUMBER}
              </div>
            </CardContent>
            <CardFooter className="gap-2">
              <Button
                type="button"
                variant="outline"
                className="flex-1"
                onClick={() => {
                  setShowConfirmation(false)
                  setAmount("")
                  setReceiverWallet("")
                }}
              >
                Cancel
              </Button>
              <Button
                type="button"
                className="flex-1 bg-black hover:bg-gray-800 text-white"
                onClick={handleOpenSMS}
              >
                Open SMS App
              </Button>
            </CardFooter>
          </Card>
        </div>
      )}
    <Card className="w-full max-w-md mx-auto">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-lg">
          <Send className="h-5 w-5" />
          WaveSend {connectedType}
        </CardTitle>
        {
          connectedType == "MiniPay" ?
            (<CardDescription>Send stablecoins with almost no internet pay fees with USDm</CardDescription>) :
            (<CardDescription>Send WSND without internet connection</CardDescription>)
        }
      </CardHeader>
      <form onSubmit={handleSubmit}>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Network</Label>
            <NetworkSelector onNetworkChange={handleNetworkChange} />
          </div>
          {connectedType == "MiniPay" &&
            <div className="space-y-2">
              USDm bal: {balUSDm}
            </div>
          }
          <div className="space-y-2">
            <Label htmlFor="amount">Amount</Label>
            <div className="relative">
              <Input
                id="amount"
                type="number"
                placeholder="0.00"
                step="0.01"
                min="0.01"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                className="pr-16 bg-white dark:bg-gray-950"
                disabled={!isWalletConnected && !connectedType}
              />
              <div className="relative">
                {connectedType == "" &&
                  <select
                    value={currency}
                    onChange={(e) => setCurrency(e.target.value)}
                    className="absolute inset-y-0 right-0 flex items-center px-3 text-muted-foreground bg-gray-50 dark:bg-gray-900 border-l border-y-0 border-r-0 rounded-r-md cursor-pointer outline-none focus:ring-0"
                  >
                    <option value="CELO">CELO</option>
                    <option value="WSND">WSND</option>
                  </select>
                }
                <p className="mt-12 text-sm">You have selected to pay in: {currency}</p>
              </div>
            </div>
          </div>
          <div className="space-y-2">
            <Label htmlFor="wallet">Receiver Wallet</Label>
            <div className="relative">
              <Input
                id="wallet"
                placeholder="Enter wallet address"
                value={receiverWallet}
                onChange={(e) => setReceiverWallet(e.target.value)}
                className="pl-10 bg-white dark:bg-gray-950"
                disabled={!isWalletConnected && !connectedType}
              />
              <Wallet className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            </div>
          </div>
          {connectedType == "" &&
            <div className="space-y-2">
              <Label htmlFor="wallet">Nounce</Label>
              <div className="relative">
                <Input
                  id="wallet"
                  type="number"
                  placeholder="Enter wallet address"
                  value={nounce}
                  onChange={(e) => handleSetNounce(e.target.value)}
                  className="bg-white dark:bg-gray-950"
                  disabled={!isWalletConnected}
                />
              </div>
            </div>}
        </CardContent>
        <CardFooter>
          <Button
            type="submit"
            className="w-full bg-black hover:bg-gray-800 text-white"
            disabled={isSubmitting || !isWalletConnected && !connectedType}
            size="lg"
          >
            {isSubmitting ? "Processing..." : !isWalletConnected && !connectedType ? "Connect Wallet to Send" : "Send Transaction"}
          </Button>
        </CardFooter>
      </form>
    </Card>
    </>
  )
}

