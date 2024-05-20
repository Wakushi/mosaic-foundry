const { ethers } = await import("npm:ethers@6.10.0")
const abiCoder = ethers.AbiCoder.defaultAbiCoder()

///////////////////////// CONSTANTS  /////////////////////////
const IPFS_BASE_URL = "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs"

async function analyzeCertificate(imageURL) {
  const openAIRequest = await Functions.makeHttpRequest({
    url: `https://api.openai.com/v1/chat/completions`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${secrets.openaiApiKey}`,
    },
    data: {
      model: "gpt-4o",
      seed: 7,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: "Analyze the image which is an artwork certificate of authenticity and extract the following information in a JSON format: { artist: 'value', title: 'value', year: 'value' }",
            },
            {
              type: "image_url",
              image_url: {
                url: imageURL,
              },
            },
          ],
        },
      ],
    },
    timeout: 40_000,
  })

  if (openAIRequest.error) {
    console.log(openAIRequest)
    throw new Error(openAIRequest.error)
  }
  const stringResult = openAIRequest.data.choices[0].message.content
  return stringResult
}

///////////////////////// MAIN /////////////////////////
const certificateImageHash = args[0]

if (!secrets.openaiApiKey) {
  throw new Error("OpenAI API key is required")
}

const imageURL = `${IPFS_BASE_URL}/${certificateImageHash}`
const result = await analyzeCertificate(imageURL)
const analyzedData = JSON.parse(result)
const { artist, title, year } = analyzedData

const encoded = abiCoder.encode(["string", "string"], [artist, title])
return ethers.getBytes(encoded)
