"use client"

import { useState } from "react"
import { Coins } from "lucide-react"
import { Button } from "../components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "../components/ui/card"
import { useToast } from "../components/ui/use-toast"
import { createPublicClient, createWalletClient, custom, http, parseUnits, encodeFunctionData } from "viem"
import { celo } from "viem/chains"
import waveSendFundAbi from "./waveSendFundAbi.json"

// WaveSendFund contract address - update this with the actual deployed address
const WAVESEND_FUND_ADDRESS = "0x0000000000000000000000000000000000000000" as const

// USDT contract address on Celo
const USDT_ADDRESS = "0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e" as const

// ERC20 ABI for approval
const ERC20_ABI = [
  {
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" }
    ],
    name: "approve",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
    type: "function"
  },
  {
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" }
    ],
    name: "allowance",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function"
  }
] as const

interface FundDepositFormProps {
  isWalletConnected?: boolean
  connectedType?: string
}

export function FundDepositForm({ isWalletConnected = false, connectedType = "" }: FundDepositFormProps) {
  const [isDepositing, setIsDepositing] = useState<string | null>(null)
  const { toast } = useToast()

  const handleDeposit = async (amount: number, buttonId: string) => {
    if (!isWalletConnected && !connectedType) {
      toast({
        variant: "destructive",
        title: "Wallet not connected",
        description: "Please connect your wallet to deposit",
      })
      return
    }

    setIsDepositing(buttonId)

    try {
      if (typeof window === "undefined" || !(window as any).ethereum) {
        throw new Error("No wallet detected")
      }

      const [account] = await (window as any).ethereum.request({
        method: "eth_requestAccounts",
      })

      const walletClient = createWalletClient({
        account,
        chain: celo,
        transport: custom((window as any).ethereum),
      })

      const publicClient = createPublicClient({
        chain: celo,
        transport: http(),
      })

      // Convert amount to USDT units (6 decimals for USDT)
      const usdtAmount = parseUnits(amount.toString(), 6)
      
      // minWbtcOut set to 0 - in production this should use a price oracle
      const minWbtcOut = BigInt(0)

      // Check allowance first
      const currentAllowance = await publicClient.readContract({
        address: USDT_ADDRESS,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [account, WAVESEND_FUND_ADDRESS],
      })

      // Approve if needed
      if (currentAllowance < usdtAmount) {
        toast({
          title: "Approval Required",
          description: "Please approve USDT spending...",
        })

        const approveHash = await walletClient.sendTransaction({
          to: USDT_ADDRESS,
          data: encodeFunctionData({
            abi: ERC20_ABI,
            functionName: "approve",
            args: [WAVESEND_FUND_ADDRESS, usdtAmount],
          }),
        })

        await publicClient.waitForTransactionReceipt({ hash: approveHash })

        toast({
          title: "Approved",
          description: "USDT spending approved. Processing deposit...",
        })
      }

      // Call the deposit function
      const depositHash = await walletClient.sendTransaction({
        to: WAVESEND_FUND_ADDRESS,
        data: encodeFunctionData({
          abi: waveSendFundAbi,
          functionName: "deposit",
          args: [usdtAmount, minWbtcOut],
        }),
      })

      const receipt = await publicClient.waitForTransactionReceipt({ hash: depositHash })

      if (receipt.status === "success") {
        toast({
          title: "Deposit Successful",
          description: `Successfully deposited ${amount} USDT to WaveSend Fund`,
        })
      } else {
        throw new Error("Transaction failed")
      }
    } catch (err: any) {
      console.error("Deposit error:", err)
      toast({
        variant: "destructive",
        title: "Deposit Failed",
        description: err.message || "There was an error processing your deposit",
      })
    } finally {
      setIsDepositing(null)
    }
  }

  const isDisabled = !isWalletConnected && !connectedType

  return (
    <Card className="w-full max-w-md mx-auto">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-lg">
          <Coins className="h-5 w-5" />
          WaveSend Fund Deposit
        </CardTitle>
        <CardDescription>
          Deposit USDT to the WaveSend Fund and earn yield
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid grid-cols-1 gap-3">
          <Button
            onClick={() => handleDeposit(1, "one")}
            disabled={isDisabled || isDepositing !== null}
            className="w-full bg-black hover:bg-gray-800 text-white h-14 text-lg"
            size="lg"
          >
            {isDepositing === "one" ? "Processing..." : "Deposit 1 USDT"}
          </Button>

          <Button
            onClick={() => handleDeposit(10, "ten")}
            disabled={isDisabled || isDepositing !== null}
            className="w-full bg-black hover:bg-gray-800 text-white h-14 text-lg"
            size="lg"
          >
            {isDepositing === "ten" ? "Processing..." : "Deposit 10 USDT"}
          </Button>

          <Button
            onClick={() => handleDeposit(100, "hundred")}
            disabled={isDisabled || isDepositing !== null}
            className="w-full bg-black hover:bg-gray-800 text-white h-14 text-lg"
            size="lg"
          >
            {isDepositing === "hundred" ? "Processing..." : "Deposit 100 USDT"}
          </Button>
        </div>

        {isDisabled && (
          <p className="text-sm text-center text-muted-foreground">
            Connect your wallet to deposit
          </p>
        )}
      </CardContent>
    </Card>
  )
}
