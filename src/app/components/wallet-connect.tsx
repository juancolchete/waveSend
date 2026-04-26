"use client"

import { useState } from "react"
import { Copy, ExternalLink, Eye, EyeOff, KeyRound, Wallet } from "lucide-react"

import { Button } from "./ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "./ui/dialog"
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "./ui/dropdown-menu"
import { Input } from "./ui/input"
import { Label } from "./ui/label"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "./ui/tabs"
import { useToast } from "./ui/use-toast"
import { ethers } from "ethers"
import axios from "axios"
import { chains } from "@/constants"
import QRCode from "react-qr-code";
import { createWalletClient, custom } from "viem";
import { celo, celoSepolia } from "viem/chains";
import contracts from "@/contracts.json"
// Add this to the props interface at the top of the file
interface WalletConnectProps {
  onConnected?: (connected: boolean) => void
}

// Update the component definition
export function WalletConnect({ onConnected }: WalletConnectProps) {
  const [address, setAddress] = useState<string | null>(null)
  const [connectType, setConnectType] = useState<string | null>(null)
  const [miniPayAddress, setMiniPayAddress] = useState<string | null>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [privateKey, setPrivateKey] = useState("")
  const [showPrivateKey, setShowPrivateKey] = useState(false)
  const [isGenerating, setIsGenerating] = useState(false)
  const { toast } = useToast()
  const [isModalOpen, setIsModalOpen] = useState(false);

  const validatePrivateKey = (key: string) => {
    // Basic validation: check if it's a valid hex string of correct length
    const privateKeyRegex = /^0x[0-9a-fA-F]{64}$/
    return privateKeyRegex.test(key)
  }

  // Update these functions to emit connection status
  const connectWithPrivateKey = async (key: string) => {
    if (!validatePrivateKey(key)) {
      toast({
        variant: "destructive",
        title: "Invalid Private Key",
        description: "Please enter a valid private key (64 characters hex)",
      })
      return
    }

    try {
      // Here you would normally use the private key to derive the address
      // This is a mock implementation
      sessionStorage.setItem("pvk", key)
      const hdNode = new ethers.Wallet(key)
      setAddress(hdNode.address)
      setIsDialogOpen(false)
      onConnected?.(true) // Emit connected status
      toast({
        title: "Wallet Connected",
        description: "Successfully connected to WaveSend",
      })
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Connection Failed",
        description: "Failed to connect to WaveSend",
      })
    }
  }

const connectWithMiniPay = async () => {
  if (typeof window !== 'undefined' && (window as any).ethereum) {
    try {
      const isMiniPay = Boolean((window as any).ethereum.isMiniPay);
      if (!isMiniPay) {
        console.warn("Wallet detected, but it does not appear to be MiniPay.");
      }

      const client = createWalletClient({
        chain: celo, // Switch to celoSepolia for testing
        transport: custom((window as any).ethereum),
      });

      const [address] = await client.request({ method: 'eth_requestAccounts' });
      setAddress(address)
      setConnectType("MiniPay")
      return address;
      
    } catch (error) {
      console.error("User rejected the request or connection failed:", error);
    }
  } else {
    alert("No Web3 wallet detected. Please open this in MiniPay!");
  }
};

  const disconnectWallet = () => {
    setAddress(null)
    setPrivateKey("")
    onConnected?.(false) // Emit disconnected status
    toast({
      title: "Wallet Disconnected",
      description: "Your wallet has been disconnected",
    })
  }

  const generateNewPrivateKey = async () => {
    setIsGenerating(true)
    const chain = 534351
    try {
      const nodeWallet = ethers.Wallet.createRandom()
      setPrivateKey(nodeWallet.privateKey)
      sessionStorage.setItem("pvk", nodeWallet.privateKey)
      toast({
        title: "Private Key Generated",
        description: "Please save this key securely. It will not be shown again!",
      })
    } catch (err) {
      console.log(err)
      toast({
        variant: "destructive",
        title: "Generation Failed",
        description: "Failed to generate new private key",
      })
    } finally {
      setIsGenerating(false)
    }
  }

  const copyAddress = () => {
    if (address) {
      navigator.clipboard.writeText(address)
      toast({
        title: "Address Copied",
        description: "Wallet address copied to clipboard",
      })
    }
  }

  const copyPVK = () => {
    if (privateKey) {
      navigator.clipboard.writeText(privateKey)
      toast({
        title: "Private Key Copied",
        description: "Private key copied to clipboard",
      })
    }
  }

  const genQR = () => {
    if (address) {
      setIsModalOpen(true); // Open the modal

      navigator.clipboard.writeText(address);
      toast({
        title: "Address Copied",
        description: "Wallet address copied to clipboard",
      });
    }
  }

  const truncateAddress = (addr: string) => {
    return `${addr.slice(0, 6)}...${addr.slice(-4)}`
  }

  if (!address) {
    return (
      <>
        <Button variant="outline" className="gap-2" onClick={() => setIsDialogOpen(true)}>
          <Wallet className="h-4 w-4" />
          Connect Wallet
        </Button>

        <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
          <DialogContent className="sm:max-w-md">
            <DialogHeader>
              <DialogTitle>Connect Wallet</DialogTitle>
              <DialogDescription>Generate a new private key or import an existing one.</DialogDescription>
            </DialogHeader>
            <Tabs defaultValue="generate" className="w-full">
              <TabsList className="grid w-full grid-cols-3">
                <TabsTrigger value="generate">Generate New</TabsTrigger>
                <TabsTrigger value="import">Import Key</TabsTrigger>
                <TabsTrigger value="minipay">MiniPay</TabsTrigger>
              </TabsList>
              <TabsContent value="generate" className="mt-4">
                <div className="flex flex-col gap-4">
                  <div className="rounded-md bg-yellow-50 p-4">
                    <div className="flex">
                      <div className="flex-shrink-0">
                        <KeyRound className="h-5 w-5 text-yellow-400" aria-hidden="true" />
                      </div>
                      <div className="ml-3">
                        <h3 className="text-sm font-medium text-yellow-800">Important Security Notice</h3>
                        <div className="mt-2 text-sm text-yellow-700">
                          <p>
                            Your private key is your wallet&apos;s password. If you lose it, you&apos;ll lose access to
                            your funds. Make sure to:
                          </p>
                          <ul className="list-disc list-inside mt-2">
                            <li>Store it securely</li>
                            <li>Never share it with anyone</li>
                            <li>Keep a backup in a safe place</li>
                          </ul>
                        </div>
                      </div>
                    </div>
                  </div>
                  {privateKey && (
                    <div className="space-y-2">
                      <Label>Your New Private Key</Label>
                      <div className="relative">
                        <Input
                          type={showPrivateKey ? "text" : "password"}
                          value={privateKey}
                          readOnly
                          className="pr-10"
                        />
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="absolute right-0 top-0 h-full px-3 py-2 hover:bg-transparent"
                          onClick={() => setShowPrivateKey(!showPrivateKey)}
                        >
                          {showPrivateKey ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                        </Button>
                      </div>
                    </div>
                  )}
                  <DialogFooter className="flex flex-col sm:flex-row gap-2">
                    <Button type="button" onClick={generateNewPrivateKey} disabled={isGenerating} className="w-full">
                      {isGenerating ? "Generating..." : "Generate New Key"}
                    </Button>
                    {privateKey && (
                      <Button type="button" onClick={() => connectWithPrivateKey(privateKey)} className="w-full">
                        Use This Key
                      </Button>
                    )}
                  </DialogFooter>
                </div>
              </TabsContent>
              <TabsContent value="import" className="mt-4">
                <div className="flex flex-col gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="privateKey">Private Key</Label>
                    <div className="relative">
                      <Input
                        id="privateKey"
                        type={showPrivateKey ? "text" : "password"}
                        placeholder="Enter your private key"
                        value={privateKey}
                        onChange={(e) => setPrivateKey(e.target.value)}
                        className="pr-10"
                      />
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        className="absolute right-0 top-0 h-full px-3 py-2 hover:bg-transparent"
                        onClick={() => setShowPrivateKey(!showPrivateKey)}
                      >
                        {showPrivateKey ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                      </Button>
                    </div>
                  </div>
                  <Button type="button" onClick={() => connectWithPrivateKey(privateKey)} disabled={!privateKey}>
                    Connect
                  </Button>
                </div>
              </TabsContent>
              <TabsContent value="minipay" className="mt-4">
                <div className="flex flex-col gap-4">
                  {miniPayAddress}    
                  <Button type="button" onClick={() => connectWithMiniPay()}>
                    Connect
                  </Button>
                </div>
              </TabsContent>
            </Tabs>
          </DialogContent>
        </Dialog>
      </>
    )
  }

  return (
    <div className="flex items-center gap-2">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="outline" className="gap-2">
            <Wallet className="h-4 w-4" />
            {truncateAddress(address)}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-[200px]">
          <DropdownMenuItem onClick={copyAddress} className="gap-2 cursor-pointer">
            <Copy className="h-4 w-4" />
            Copy Address
          </DropdownMenuItem>
          {privateKey &&
          <DropdownMenuItem onClick={copyPVK} className="gap-2 cursor-pointer">
            <Copy className="h-4 w-4" />
            Copy Private Key 
          </DropdownMenuItem>
          }
          <DropdownMenuItem onClick={genQR} className="gap-2 cursor-pointer">
            <Copy className="h-4 w-4" />
            Gen qrcode
          </DropdownMenuItem>
          <DropdownMenuItem className="gap-2 cursor-pointer" asChild>
            <a href={`https://celoscan.io/address/${address}`} target="_blank" rel="noopener noreferrer">
              <ExternalLink className="h-4 w-4" />
              View on Explorer
            </a>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <Button variant="destructive" size="icon" onClick={disconnectWallet} title="Disconnect Wallet">
        <ExternalLink className="h-4 w-4 rotate-180" />
        <span className="sr-only">Disconnect Wallet</span>
      </Button>
      {isModalOpen && address && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm">

          {/* Modal Content Box */}
          <div className="relative p-8 bg-white rounded-2xl shadow-xl flex flex-col items-center gap-6 animate-in fade-in zoom-in duration-200">

            {/* Close Button (X) */}
            <button
              onClick={() => setIsModalOpen(false)}
              className="absolute top-3 right-3 text-gray-400 hover:text-gray-800"
              aria-label="Close modal"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
            </button>

            <h3 className="text-lg font-semibold text-gray-900">Scan to Pay</h3>

            <div className="p-2 bg-white rounded-xl border border-gray-100">
              <QRCode
                value={address}
                size={250}
              />
            </div>

            <p className="text-sm text-gray-500 break-all text-center max-w-[250px]">
              {address}
            </p>
          </div>
        </div>
      )}
    </div>
  )
}

