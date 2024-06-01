const { ethers } = await import("npm:ethers@6.10.0")
// const { Base64 } = await import("npm:js-base64")
const abiCoder = ethers.AbiCoder.defaultAbiCoder()

///////////////////////// CONSTANTS  /////////////////////////
const MOSAIC_API_BASE_URL =
  "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs"

///////////////////////// HELPERS  /////////////////////////
function formatArtistNameMW(artistName) {
  return artistName.split(" ").join("-").toLowerCase()
}

///////////////////////// FETCHERS /////////////////////////
async function fetchArtistData(artistId) {
  const response = await Functions.makeHttpRequest({
    url: "https://pricedb.ms.masterworks.io/graphql",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    data: {
      operationName: "artistDetails",
      variables: {
        artistId: artistId,
      },
      query:
        "query artistDetails($artistId: String, $permalink: String, $artistName: String, $yob: Int) {\n  artist(\n    artistId: $artistId\n    permalink: $permalink\n    artistName: $artistName\n    yob: $yob\n  ) {\n    artistId\n    permalink\n    artistName\n    bio\n    fallbackBio\n    yob\n    yod\n    recordPrice\n    historicalAppreciation\n    worksCount\n    coverImageLink\n    performance {\n      year\n      totalTurnover\n      maxPrice\n      lotsUnsold\n      lotsSold\n      averagePrice\n      __typename\n    }\n    works {\n      permalink\n      workTitle\n      imageLink\n      moic\n      sales {\n        priceUSD\n        date\n        __typename\n      }\n      __typename\n    }\n    __typename\n  }\n}",
    },
  })
  if (response.error) {
    throw new Error("Error fetching artist data")
  }
  return response.data.data.artist
}

async function fetchWorkDetails(permalink) {
  const response = await Functions.makeHttpRequest({
    url: `https://pricedb.ms.masterworks.io/graphql`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
    },
    data: {
      operationName: "ArtworkForAdmin",
      variables: {
        permalink: permalink, // ex: "w:038e7b184c25ad9"
      },
      query:
        "query ArtworkForAdmin($permalink: String) {\n  artwork: work(permalink: $permalink) {\n    permalink\n    artistPermalink\n    workTitle\n    imageLink\n    irr\n    totalReturn\n    notes\n    medium\n    heightCM\n    widthCM\n    spreadsheetId\n    internalNotes\n    sales {\n      date\n      permalink\n      priceUSD\n      lowEstimateUSD\n      highEstimateUSD\n      internalNotes\n      lotNumber\n      notes\n      currency\n      workTitle\n      __typename\n    }\n    moic\n    firstSaleDate\n    lastSaleDate\n    firstSalePrice\n    lastSalePrice\n    __typename\n  }\n}",
    },
  })
  if (response.error) {
    throw new Error("Error fetching work details")
  }
  return response.data.data.artwork
}

async function fetchWorkMarketData(work) {
  try {
    const artist = await fetchArtistData(formatArtistNameMW(work.artist))
    const externalWork = artist.works.find((workMW) => {
      return workMW.workTitle.replace(/^"|"$/g, "") === work.title
    })
    const { permalink } = externalWork
    const marketData = await fetchWorkDetails(permalink)
    return {
      title: marketData.workTitle.replace(/^"|"$/g, ""),
      artist: artist.artistName,
      lastSaleDate: marketData.lastSaleDate,
      lastSalePrice: marketData.lastSalePrice,
    }
  } catch (error) {
    console.log(error)
    throw new Error("Error fetching work market data")
  }
}

async function fetchCustomerWork(workHash) {
  try {
    const work = await Functions.makeHttpRequest({
      url: `${MOSAIC_API_BASE_URL}/${workHash}`,
    })
    return work.data
  } catch (error) {
    throw new Error("Error fetching customer work data")
  }
}

async function fetchReport(reportHash) {
  const report = await Functions.makeHttpRequest({
    url: `${MOSAIC_API_BASE_URL}/${reportHash}`,
  })
  return report.data
}

async function aggregateWorkData(workHash, reportHash) {
  const customerSubmission = await fetchCustomerWork(workHash)
  const marketData = await fetchWorkMarketData(customerSubmission)
  const report = await fetchReport(reportHash)
  const aggregatedData = {
    customerSubmission,
    market: marketData,
    report,
  }
  return aggregatedData
}

async function organizeData(aggregatedData) {
  const { customerSubmission, report, market } = aggregatedData
  const prompt = `Organize relevant data from three JSON data sources into categorized arrays. Extract data into four specific arrays: artist, title, owner, and price, and output them in a JSON structure as shown below: { "artist": [], "title": [], "price": [], "customerAndOwnerName": [] }. Recognize that some keys in the data sources may have different names but similar meanings; include these values under the appropriate categories. Sources :
    \n Source 1 : ${JSON.stringify(customerSubmission)}
    \n Source 2 : ${JSON.stringify(report)}
    \n Source 3 : ${JSON.stringify(market)}`

  const openAIRequest = await Functions.makeHttpRequest({
    url: `https://api.openai.com/v1/chat/completions`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${secrets.openaiApiKey}`,
    },
    data: {
      model: "gpt-4o",
      response_format: { type: "json_object" },
      seed: 1996,
      messages: [
        {
          role: "system",
          content: "You are a helpful assistant designed to output JSON.",
        },
        {
          role: "user",
          content: prompt,
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

function getDiscrepancies(organizedData) {
  const discrepancies = []
  Object.entries(organizedData).forEach(([key, collection]) => {
    if (collection.length > 0) {
      const validValues = collection.every(
        (value) =>
          String(value).trim().toLowerCase() ===
          String(collection[0]).trim().toLowerCase()
      )
      if (!validValues) {
        discrepancies.push({ key, collection })
      }
    }
  })
  return discrepancies
}

// function decodeBase64(encoded) {
//   return Base64.decode(encoded)
// }

///////////////////////// MAIN /////////////////////////
const customerSubmissionHash = args[0]
const reportHash = args[1]
const certificateArtistRaw = args[2]
const certificateWorkTitleRaw = args[3]

// const certificateArtist = decodeBase64(certificateArtistRaw)
// const certificateWorkTitle = decodeBase64(certificateWorkTitleRaw)

if (!secrets.openaiApiKey) {
  throw new Error("OpenAI API key is required")
}

try {
  const aggregatedData = await aggregateWorkData(
    customerSubmissionHash,
    reportHash
  )

  const organizedData = await organizeData(aggregatedData)
  const sanitizedData = {} // { "artist": [], "title": [], "price": [], "customerAndOwnerName": [] }

  Object.entries(JSON.parse(organizedData)).forEach(([key, collection]) => {
    collection = collection.filter((value) => value)
    sanitizedData[key] = collection
  })

  // sanitizedData.artist.push(certificateArtist)
  // sanitizedData.title.push(certificateWorkTitle)
  console.log(sanitizedData)
  const discrepancies = getDiscrepancies(sanitizedData)

  if (discrepancies.length > 0) {
    const encoded = abiCoder.encode(
      ["string", "uint256"],
      [JSON.stringify(discrepancies), 0]
    )
    return ethers.getBytes(encoded)
  } else {
    const encoded = abiCoder.encode(
      ["string", "uint256"],
      [sanitizedData.customerAndOwnerName[0], sanitizedData.price[0]]
    )
    return ethers.getBytes(encoded)
  }
} catch (error) {
  const encoded = abiCoder.encode(
    ["string", "uint256"],
    [JSON.stringify(error), 0]
  )
  return ethers.getBytes(encoded)
}
