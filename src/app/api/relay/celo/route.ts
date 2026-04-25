import { chains } from "@/constants";
import { decodeFromBase } from "../../../../data";
import axios from "axios";
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const formData = await req.formData()
  console.log(formData)
  const rawBody = formData.get("Body")
  const rawTxn = decodeFromBase(rawBody!.toString(), 0)
  console.log(rawTxn)
  const validateTxn = (key: string) => {
    const privateKeyRegex = /^0x[0-9a-fA-F]{64}$/
    return privateKeyRegex.test(key)
  }
  const sendUserTxn = async (txnId: string) => {
    if (validateTxn(txnId)) {
      let nounce = 0;
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
      try {
        await axios.request(reqconfig)
      } catch (e) {
        console.log(eval("e.response"))
      }
    }
  }
  const response = await axios.post(chains["42220"].url, {
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
