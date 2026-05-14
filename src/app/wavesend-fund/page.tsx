"use client"

import { useState } from "react"
import { WalletConnect } from "../components/wallet-connect"
import { Toaster } from "../components/ui/toaster"
import { FundDepositForm } from "./fund-deposit-form"

export default function WaveSendFundPage() {
  const [isWalletConnected, setIsWalletConnected] = useState(false)
  const [connectionType, setConnectionType] = useState("")

  return (
    <div className="min-h-screen flex flex-col p-4 bg-gray-50">
      <header className="w-full max-w-md mx-auto mb-8">
        <div className="flex justify-between items-center">
          <h1 className="text-xl font-semibold text-gray-900">WaveSend Fund</h1>
          <WalletConnect 
            onConnected={(connected) => setIsWalletConnected(connected)} 
            onConnectedType={(connectedType) => setConnectionType(connectedType)} 
          />
        </div>
      </header>
      <main className="flex-1 flex items-start justify-center">
        <FundDepositForm 
          isWalletConnected={isWalletConnected} 
          connectedType={connectionType} 
        />
      </main>
      <Toaster />
    </div>
  )
}
