"use client"

import Image from "next/image"

import * as React from "react"

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "./ui/select"

export type Network = {
  id: string
  name: string
  icon: React.ReactNode
}

const networks: Network[] = [
  {
    id: "scroll",
    name: "Scroll",
    icon: <Image width="24" height="24" src={"/scroll.png"} alt={"scroll"}/>
  },
  {
    id: "arbitrum",
    name: "Arbitrum",
    icon: <Image width="24" height="24" src={"/arbitrum.png"} alt={"scroll"}/>
  },
]

interface NetworkSelectorProps {
  onNetworkChange: (network: Network) => void
}

export function NetworkSelector({ onNetworkChange }: NetworkSelectorProps) {
  const [selectedNetwork, setSelectedNetwork] = React.useState<Network>(networks[0])

  const handleValueChange = (value: string) => {
    const network = networks.find((n) => n.id === value) || networks[0]
    setSelectedNetwork(network)
    onNetworkChange(network)
  }

  return (
    <Select value={selectedNetwork.id} onValueChange={handleValueChange}>
      <SelectTrigger className="w-full">
        <SelectValue>
          <div className="flex items-center gap-2">
            <div className="rounded-full bg-gray-100 p-1">{selectedNetwork.icon}</div>
            <span>{selectedNetwork.name}</span>
          </div>
        </SelectValue>
      </SelectTrigger>
      <SelectContent>
        {networks.map((network) => (
          <SelectItem key={network.id} value={network.id}>
            <div className="flex items-center gap-2">
              <div className="rounded-full bg-gray-100 p-1">{network.icon}</div>
              <span>{network.name}</span>
            </div>
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}


