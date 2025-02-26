"use client"

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
    icon: (
      <svg width="24" height="24" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path
          d="M16 0C7.164 0 0 7.164 0 16s7.164 16 16 16 16-7.164 16-16S24.836 0 16 0zm-3.847 21.456H9.692v-10.91h2.461v10.91zm5.692-7.384h-2.153v4.86h2.153c1.538 0 2.308-.923 2.308-2.43 0-1.508-.77-2.43-2.308-2.43zm-.23-3.526h-1.923v2.122h1.923c.769 0 1.23-.385 1.23-1.061s-.461-1.06-1.23-1.06zm3.076 5.833c0 2.553-1.846 5.199-5.23 5.199h-4.46v-10.91h4.46c2.954 0 4.646 1.754 4.646 3.876 0 1.57-.923 2.43-1.384 2.738.769.308 1.968 1.108 1.968 3.097z"
          fill="#FFFFFF"
        />
        <path
          d="M16 0C7.164 0 0 7.164 0 16s7.164 16 16 16 16-7.164 16-16S24.836 0 16 0zm-3.847 21.456H9.692v-10.91h2.461v10.91zm5.692-7.384h-2.153v4.86h2.153c1.538 0 2.308-.923 2.308-2.43 0-1.508-.77-2.43-2.308-2.43zm-.23-3.526h-1.923v2.122h1.923c.769 0 1.23-.385 1.23-1.061s-.461-1.06-1.23-1.06zm3.076 5.833c0 2.553-1.846 5.199-5.23 5.199h-4.46v-10.91h4.46c2.954 0 4.646 1.754 4.646 3.876 0 1.57-.923 2.43-1.384 2.738.769.308 1.968 1.108 1.968 3.097z"
          fill="#0052FF"
        />
      </svg>
    ),
  },
  {
    id: "arbitrum",
    name: "Arbitrum",
    icon: (
      <svg width="24" height="24" viewBox="0 0 32 32" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path
          d="M16 0C7.164 0 0 7.164 0 16s7.164 16 16 16 16-7.164 16-16S24.836 0 16 0zm-3.384 23.384l-2.23-3.692.923-1.415 1.307 2.153 7.384-11.23h1.846l-8.461 12.923-.769 1.26zm9.23-5.846l-1.384 2.154-1.23-2.154h-1.846l2.153 3.692.923 1.415.923-1.415 2.154-3.692h-1.692z"
          fill="#FFFFFF"
        />
        <path
          d="M16 0C7.164 0 0 7.164 0 16s7.164 16 16 16 16-7.164 16-16S24.836 0 16 0zm-3.384 23.384l-2.23-3.692.923-1.415 1.307 2.153 7.384-11.23h1.846l-8.461 12.923-.769 1.26zm9.23-5.846l-1.384 2.154-1.23-2.154h-1.846l2.153 3.692.923 1.415.923-1.415 2.154-3.692h-1.692z"
          fill="#2D374B"
        />
      </svg>
    ),
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


