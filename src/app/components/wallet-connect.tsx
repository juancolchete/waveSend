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

// Add this to the props interface at the top of the file
interface WalletConnectProps {
  onConnected?: (connected: boolean) => void
}

// Update the component definition
export function WalletConnect({ onConnected }: WalletConnectProps) {
  const [address, setAddress] = useState<string | null>(null)
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [privateKey, setPrivateKey] = useState("")
  const [showPrivateKey, setShowPrivateKey] = useState(false)
  const [isGenerating, setIsGenerating] = useState(false)
  const { toast } = useToast()

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
      const pvk =sessionStorage.getItem("pvk")
      if(pvk){
        const hdNode = new ethers.Wallet(pvk)
        setAddress(hdNode.address)
        setIsDialogOpen(false)
        setPrivateKey("")
        onConnected?.(true) // Emit connected status
        toast({
          title: "Wallet Connected",
          description: "Successfully connected to WaveSend",
        })
      }
    } catch (err) {
      toast({
        variant: "destructive",
        title: "Connection Failed",
        description: "Failed to connect to WaveSend",
      })
    }
  }

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
    try {
      const nodeWallet = ethers.Wallet.createRandom()
      setPrivateKey(nodeWallet.privateKey)
      sessionStorage.setItem("pvk",nodeWallet.privateKey)
      setShowPrivateKey(true)
      toast({
        title: "Private Key Generated",
        description: "Please save this key securely. It will not be shown again!",
      })
    } catch (err) {
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
              <TabsList className="grid w-full grid-cols-2">
                <TabsTrigger value="generate">Generate New</TabsTrigger>
                <TabsTrigger value="import">Import Key</TabsTrigger>
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
          <DropdownMenuItem className="gap-2 cursor-pointer" asChild>
            <a href={`https://sepolia.scrollscan.com/${address}`} target="_blank" rel="noopener noreferrer">
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
    </div>
  )
}

