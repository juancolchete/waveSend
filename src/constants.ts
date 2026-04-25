interface Chains {
  [index: string]: {url: string,token:string};
}

export const chains: Chains = {
  "534351":{
    url: "https://sepolia-rpc.scroll.io",
    token: "0xB3BF79Cc114926ED20b57f1fB8066fFEc56748EC"
  },
  "42220":{
    url: "https://forno.celo.org",
    token: "0xbF87edCcB90B4911Ec076380717E4a530d9Aff3A"
  } 
} 
