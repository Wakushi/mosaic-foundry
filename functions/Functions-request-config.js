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

function getSourceConfig(source) {
  switch (source) {
    case "work-verification":
      return {
        source: fs
          .readFileSync("./functions/sources/work-verification-source.js")
          .toString(),
        args: [
          "Qmbi73JQdBVuLYUMDamKS3Z42uQf54MP1L2WFxKLUCmJuk", // CUSTOMER SUBMISSION HASH
          "QmUCMNYFoJAoaX21CeVBChvwXUqbXPSEBouAGci283Bi1d", // REPORT HASH
        ],
      }
    case "certificate-extraction":
      return {
        source: fs
          .readFileSync("./functions/sources/certificate-extraction-source.js")
          .toString(),
        args: [
          "QmcYLvdwSZXuoXiWCqW5xYhbXjvkU4QkfosqLfZQQiqoky", // CERTIFICATE IMAGE HASH
        ],
      }
    default:
      return {
        source: fs
          .readFileSync("./functions/sources/work-verification-source.js")
          .toString(),
        args: [
          "Qmbi73JQdBVuLYUMDamKS3Z42uQf54MP1L2WFxKLUCmJuk", // CUSTOMER SUBMISSION HASH
          "QmUCMNYFoJAoaX21CeVBChvwXUqbXPSEBouAGci283Bi1d", // REPORT HASH
        ],
      }
  }
}

const activeConfig = getSourceConfig("certificate-extraction")

const requestConfig = {
  codeLocation: Location.Inline,
  codeLanguage: CodeLanguage.JavaScript,
  source: activeConfig.source,
  secrets: {
    openaiApiKey: process.env["OPENAI_API_KEY"],
  },
  perNodeSecrets: [],
  walletPrivateKey: process.env["PRIVATE_KEY"],
  args: activeConfig.args,
  expectedReturnType: ReturnType.bytes,
  secretsURLs: [],
}

module.exports = requestConfig
