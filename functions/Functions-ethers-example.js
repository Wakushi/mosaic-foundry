const { ethers } = await import("npm:ethers@6.10.0")
const abiCoder = ethers.AbiCoder.defaultAbiCoder()
const apiResponse = await Functions.makeHttpRequest({
  url: `https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/QmRSdqx45aauK98krtT3fwg6jfRbE4QecDAhMt6YhNWXBU`,
})
const address = apiResponse.data.address
const name = String(apiResponse.data.name)
const email = String(apiResponse.data.email)

console.log("address: ", address)
console.log("name: ", name)
console.log("email: ", email)

const encoded = abiCoder.encode(
  [`address`, `string`, `string`],
  [address, name, email]
)
return ethers.getBytes(encoded)