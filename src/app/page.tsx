"use client"

import { WalletConnect } from "./components/wallet-connect"
import TransactionForm from "./transaction-form"
import { Toaster } from "./components/ui/toaster"
import { useState } from "react"

export default function Page() {
  const [isWalletConnected, setIsWalletConnected] = useState(false)
  const [connectionType, setConnectionType] = useState("")

  return (
    <div className="min-h-screen flex flex-col p-4 bg-gray-50">
      <header className="w-full max-w-md mx-auto mb-8">
        <div className="flex justify-end">
          <WalletConnect onConnected={(connected) => setIsWalletConnected(connected)} onConnectedType={(connectedType) => setConnectionType(connectedType)} />
        </div>
      </header>
      <main className="flex-1 flex items-start justify-center">
        <TransactionForm isWalletConnected={isWalletConnected} connectedType={connectionType} />
      </main>
      <Toaster />
    </div>
  )
}


