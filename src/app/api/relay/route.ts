
import { decodeFromBase } from "../../../data";
import axios from "axios";
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  const formData = await req.formData()
  console.log(formData)
  // const rawBody =formData.get("Body")
  // let sepBody = rawBody?.toString().split(",")
  // sepBody = sepBody ? sepBody : []
  // console.log(sepBody[2])
  // const rawTxn = decodeFromBase(sepBody[2],parseInt(sepBody[0]))
  // const config = {
  //   method: 'get',
  //   maxBodyLength: Infinity,
  //   url:'',
  //   headers: { }
  // };
  // const sendUserTxn = async(txnId:string)=>{
  //   const reqconfig = {
  //     method: 'post',
  //     maxBodyLength: Infinity,
  //     url: `https://api.twilio.com/2010-04-01/Accounts/${process.env.TWILLIO_ACCOUNT}/Messages.json`,
  //     headers: { 
  //       'Content-Type': 'application/x-www-form-urlencoded', 
  //       'Authorization': process.env.TWILLIO_TOKEN
  //     },
  //     data : {
  //       To: formData.get("From"),
  //       From: process.env.NEXT_PUBLIC_TWILLIO_NUMBER,
  //       Body: txnId 
  //     }
  //   };

  //   await axios.request(reqconfig)
  // }
  // if(parseInt(sepBody[1]) == chains[1]){
  //   console.log(rawTxn)
  //   const urlBase = process.env.GOERLI_API_URL
  //   const apiKey = process.env.GOERLI_API_KEY
  //   config.url = `${urlBase}/api?module=proxy&action=eth_sendRawTransaction&hex=${rawTxn}&apikey=${apiKey}`
  //   const request = await axios.request(config);
  //   await sendUserTxn(`${request.data.result}`) 
  //   return NextResponse.json(request.data);
  // }else if(parseInt(sepBody[1]) == chains[2]){
  //   console.log(rawTxn);
  //   const config = {
  //     method: 'post',
  //     maxBodyLength: Infinity,
  //     url: BITFINITY_RPC,
  //     headers: { 
  //       'Content-Type': 'application/json'
  //     },
  //     data : {
  //     "jsonrpc": "2.0",
  //     "id": "1",
  //     "method": "eth_sendRawTransaction",
  //     "params": [
  //       rawTxn
  //     ]
  //   }
  //   };
  //   const request = await axios.request(config)
  //   await sendUserTxn(`${request.data.result}`)
  //   return NextResponse.json(request.data);
  // }else if(parseInt(sepBody[1]) == chains[3]){
  //   console.log(rawTxn)
  //   const urlBase = process.env.SEPOLIA_API_URL
  //   const apiKey = process.env.GOERLI_API_KEY
  //   config.url = `${urlBase}/api?module=proxy&action=eth_sendRawTransaction&hex=${rawTxn}&apikey=${apiKey}`
  //   const request = await axios.request(config);
  //   await sendUserTxn(`${request.data.result}`) 
  //   return NextResponse.json(request.data);
  // }
  // return NextResponse.json({rawTxn});
  return NextResponse.json("");
}
