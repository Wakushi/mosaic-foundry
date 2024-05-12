const fs = require("fs")

require("@chainlink/env-enc").config()

const Location = {
  Inline: 0,
  Remote: 1,
}

const CodeLanguage = {
  JavaScript: 0,
}

const ReturnType = {
  uint: "uint256",
  uint256: "uint256",
  int: "int256",
  int256: "int256",
  string: "string",
  bytes: "Buffer",
  Buffer: "Buffer",
}

const requestConfig = {
  codeLocation: Location.Inline,
  codeLanguage: CodeLanguage.JavaScript,
  source: fs.readFileSync("./sources/work-verification-source.js").toString(),
  secrets: {
    openaiApiKey: process.env["OPENAI_API_KEY"],
  },
  perNodeSecrets: [],
  walletPrivateKey: process.env["PRIVATE_KEY"],
  args: [
    "Qmbi73JQdBVuLYUMDamKS3Z42uQf54MP1L2WFxKLUCmJuk", // CUSTOMER SUBMISSION HASH
    "QmUCMNYFoJAoaX21CeVBChvwXUqbXPSEBouAGci283Bi1d", // REPORT HASH
  ],
  expectedReturnType: ReturnType.bytes,
  secretsURLs: [],
}

module.exports = requestConfig
