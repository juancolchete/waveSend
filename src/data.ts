  function hexToString(hex:string,leadingZeros:number) {
  hex = hex.substring(2+leadingZeros) // remove the '0x' part
  var string = ""

  while (hex.length % 4 != 0) { // we need it to be multiple of 8
    hex =  "0" + hex;
  }

  for (var i = 0; i < hex.length; i+= 8){
    string += String.fromCharCode(parseInt(hex.substring(i,i + 4), 16), parseInt(hex.substring(i + 4,i + 8), 16))
    console.log(`string-${String.fromCharCode(parseInt(hex.substring(i,i + 4), 16), parseInt(hex.substring(i + 4,i + 8), 16))}-${parseInt(hex.substring(i,i + 4), 16), parseInt(hex.substring(i + 4,i + 8), 16)}`)
  }
  for (let i =0;i < 100;i++){
    console.log(`${i}char-${String.fromCharCode(i)}`)
  }
  return string;
  }
function stringToHex(str:string,leadingZeros:number) {
  const string = str  
  var hex = ""
  for (var i=0; i < string.length; i++){ 
    hex += ( (i == 0 ? "" : "000") + string.charCodeAt(i).toString(16)).slice(-4) // get character ascii code and convert to hexa string, adding necessary 0s
  }
  let leading = "";
  for(let i=0;i<leadingZeros;i++){
    leading += "0"
  }
  return '0x'+ leading + hex;
}
const customBase182 = {
  characters: `0123456789@£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !#%&()*+-./:;<=>?ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà¤|[]{}~^€¡'"你好是的了不他在这一有大人中来国上到说生子出时年和那要以为望家个学也吗但后着老我们能力工作非常长问题`,
  base: BigInt(182),
};
function encodeToBase(number:bigint) {
  const { characters, base } = customBase182;
  let result = '';

  while (number > BigInt(0)) {
    const remainder = number % base;
    result = characters[Number(remainder)] + result;
    number = number / base;
  }

  return result;
}

function decodeFromBase(encoded:string,leadingZeros:number) {
  const { characters, base } = customBase182;
  let result = BigInt(0);

  for (let i = 0; i < encoded.length; i++) {
    const char = encoded.charAt(i);
    const charValue = BigInt(characters.indexOf(char));
    if (charValue === BigInt(-1)) {
      throw new Error(`Invalid character "${char}" in the encoded string.`);
    }
    result = result * base + charValue;
  }
  let leading = "";
  for(let i=0;i<leadingZeros;i++){
    leading += "0"
  }
  return '0x'+ leading +result.toString(16);
}

  function getMinifiedAddress(address: string | null): string {
  if (address) {
    return (
      address.slice(0, 10) +
      "...." +
      address.slice(address.length - 9, address.length)
    );
  } else {
    return "none";
  }
}
export { hexToString,stringToHex,encodeToBase,decodeFromBase, getMinifiedAddress };


