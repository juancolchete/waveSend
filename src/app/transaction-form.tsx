"use client"

import type React from "react"
import { useEffect, useState } from "react"
import { Send, Wallet } from "lucide-react"
import contracts from "@/contracts.json"
import { Button } from "./components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "./components/ui/card"
import { Input } from "./components/ui/input"
import { Label } from "./components/ui/label"
import { useToast } from "./components/ui/use-toast"
import { NetworkSelector, type Network } from "./components/network-selector"
import { getRawErc20 } from "@/data"
import { ethers } from "ethers"
import { chains } from "@/constants"

interface TransactionFormProps {
  isWalletConnected?: boolean
}

export default function TransactionForm({ isWalletConnected = false }: TransactionFormProps) {
  const [chain, setChain] = useState(534351)
  const [amount, setAmount] = useState("")
  const [receiverWallet, setReceiverWallet] = useState("")
  const [nounce, setNounce] = useState("0")
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [selectedNetwork, setSelectedNetwork] = useState<Network>({
    id: "scroll",
    name: "Scroll",
    icon: "/placeholder.svg?height=32&width=32",
  })
  const { toast } = useToast()

  const handleNetworkChange = (network: Network) => {
    setSelectedNetwork(network)
  }

  const handleSetNounce = (nounce: string) =>{
    setNounce(nounce)
    sessionStorage.setItem(`nounce${chain}`,nounce)
  }

   useEffect(() => {
      if(window){
        const sNounce = sessionStorage.getItem(`nounce${chain}`)
        if(sNounce){
          setNounce(sNounce)
        }
     }
   }, [chain]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    if (!isWalletConnected) {
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
        description: "Please enter a valid WSD amount",
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
        getRawErc20(chains[chain].token, ethers.parseEther(amount), receiverWallet, chain, parseInt(nounce), privateKey)
        sessionStorage.setItem(`nounce${chain}`, `${parseInt(nounce) + 1}`)
        setNounce(`${parseInt(nounce) + 1}`)
      }
      const txnRawEnc = sessionStorage.getItem("txnRawEnc")
      // Create transaction message
      const transactionMessage = `${txnRawEnc}`

      // Copy to clipboard
      await navigator.clipboard.writeText(transactionMessage)

      toast({
        title: "Transaction prepared",
        description: `${amount} WSD will be sent to ${receiverWallet} on ${selectedNetwork.name} when connection is available. Details copied to clipboard.`,
      })

      // Reset form
      setAmount("")
      setReceiverWallet("")
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

  return (
    <Card className="w-full max-w-md mx-auto">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-lg">
          <Send className="h-5 w-5" />
          WaveSend
        </CardTitle>
        <CardDescription>Send WSD without internet connection</CardDescription>
      </CardHeader>
      <form onSubmit={handleSubmit}>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Network</Label>
            <NetworkSelector onNetworkChange={handleNetworkChange} />
          </div>

          <div className="space-y-2">
            <Label htmlFor="amount">Amount (WSD)</Label>
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
                disabled={!isWalletConnected}
              />
              <div className="absolute inset-y-0 right-0 flex items-center px-3 pointer-events-none text-muted-foreground bg-gray-50 dark:bg-gray-900 border-l rounded-r-md">
                WSD
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
                disabled={!isWalletConnected}
              />
              <Wallet className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            </div>
          </div>
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
          </div>
        </CardContent>
        <CardFooter>
          <Button
            type="submit"
            className="w-full bg-black hover:bg-gray-800 text-white"
            disabled={isSubmitting || !isWalletConnected}
            size="lg"
          >
            {isSubmitting ? "Processing..." : !isWalletConnected ? "Connect Wallet to Send" : "Send Transaction"}
          </Button>
        </CardFooter>
      </form>
    </Card>
  )
}

