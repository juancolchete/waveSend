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
  return NextResponse.json({ data });
}
