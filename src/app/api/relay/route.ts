
import { chains } from "@/constants";
import { decodeFromBase } from "../../../data";
import axios from "axios";
import { NextRequest, NextResponse } from "next/server";
import { ethers } from "ethers";

export async function POST(req: NextRequest) {
  const formData = await req.formData()
  console.log(formData)
  const rawBody = formData.get("Body")
  console.log(rawBody)
  let sepBody = rawBody?.toString().split(",")
  sepBody = sepBody ? sepBody : []
  console.log(sepBody[2])
  const rawTxn = decodeFromBase(sepBody[2], parseInt(sepBody[0]))
  console.log(rawTxn)
  const config = {
    method: 'get',
    maxBodyLength: Infinity,
    url: '',
    headers: {}
  };
  const validatePrivateKey = (key: string) => {
    // Basic validation: check if it's a valid hex string of correct length
    const privateKeyRegex = /^0x[0-9a-fA-F]{64}$/
    return privateKeyRegex.test(key)
  }
  const sendUserTxn = async (txnId: string) => {
    let nounce = 0; 
    if (validatePrivateKey(txnId)) {
      const provider = new ethers.JsonRpcProvider(chains[sepBody[1]].url)
      const txn = await provider.waitForTransaction(txnId)
      if(txn){
        const response:any = await axios.post(chains[sepBody[1]].url, {
          "jsonrpc": "2.0",
          "id": "1",
          "method": "eth_sendRawTransaction",
          "params": [
            txn.from
          ]
        })
        console.log("nouce",response )
        nounce = parseInt(response.result)
      }
    }
    const reqconfig = {
      method: 'post',
      maxBodyLength: Infinity,
      url: `https://api.twilio.com/2010-04-01/Accounts/${process.env.TWILLIO_ACCOUNT}/Messages.json`,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': process.env.TWILLIO_TOKEN
      },
      data: {
        To: formData.get("From"),
        From: process.env.NEXT_PUBLIC_TWILLIO_NUMBER,
        Body: `txnId ${txnId}`
      }
    };
    console.log(reqconfig)
    try {
      await axios.request(reqconfig)
    } catch (e) {
      console.log(eval("e.response"))
    }
    const reqconfig2 = {
      method: 'post',
      maxBodyLength: Infinity,
      url: `https://api.twilio.com/2010-04-01/Accounts/${process.env.TWILLIO_ACCOUNT}/Messages.json`,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': process.env.TWILLIO_TOKEN
      },
      data: {
        To: formData.get("From"),
        From: process.env.NEXT_PUBLIC_TWILLIO_NUMBER,
        Body: `nounce ${nounce}`
      }
    };
    console.log(reqconfig2)
    try {
      await axios.request(reqconfig2)
    } catch (e) {
      console.log(eval("e.response"))
    }
  }
  const response = await axios.post(chains[sepBody[1]].url, {
    "jsonrpc": "2.0",
    "id": "1",
    "method": "eth_sendRawTransaction",
    "params": [
      rawTxn
    ]
  })
  const data = response.data;
  console.log(data)
  await sendUserTxn(data.result)
  return NextResponse.json({ data });
}
