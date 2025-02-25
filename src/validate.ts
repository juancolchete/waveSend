function validateEthAddress(address: string): boolean {
  const reAddress = /^0x[a-fA-F0-9]{40}$/;
  const isAddressValid = reAddress.exec(address);
  if (!isAddressValid) {
    return false;
  }

  return true;
}
export { validateEthAddress };


