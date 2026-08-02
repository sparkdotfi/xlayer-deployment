const express = require("express");
const https = require("https");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const querystring = require("querystring");
const { URL } = require("url");
const { ethers } = require("ethers");
require("dotenv").config();

// Helper to generate signature and headers for OKLink requests
function getOklinkHeaders(method, requestPath, params = null, body = null) {
    const timestamp = new Date().toISOString().slice(0, -5) + "Z";

    let pathWithQuery = requestPath;
    if (method === "GET" && params && Object.keys(params).length > 0) {
        pathWithQuery += "?" + querystring.stringify(params);
    }

    let bodyStr = "";
    if (method === "POST" && body) {
        bodyStr = typeof body === "object" ? JSON.stringify(body) : body;
    }

    const preHash = timestamp + method + pathWithQuery + bodyStr;
    const secretKey = process.env.OKLINK_SECRET_KEY || "";
    const hmac = crypto.createHmac("sha256", secretKey);
    hmac.update(preHash);
    const signature = hmac.digest("base64");

    return {
        "Ok-Access-Key": process.env.OKLINK_API_KEY || "",
        "OK-ACCESS-KEY": process.env.OKLINK_API_KEY || "",
        "OK-ACCESS-SIGN": signature,
        "OK-ACCESS-TIMESTAMP": timestamp,
        "OK-ACCESS-PASSPHRASE": process.env.OKLINK_PASSPHRASE || "",
    };
}

// Custom request helper using native https to preserve exact headers casing
function oklinkRequest(method, targetUrl, headers, body = null) {
    return new Promise((resolve, reject) => {
        const parsedUrl = new URL(targetUrl);
        const options = {
            hostname: parsedUrl.hostname,
            path: parsedUrl.pathname + parsedUrl.search,
            method: method,
            headers: headers,
        };

        const req = https.request(options, (res) => {
            let data = "";
            res.on("data", (chunk) => {
                data += chunk;
            });
            res.on("end", () => {
                resolve({
                    status: res.statusCode,
                    statusText: res.statusMessage,
                    headers: res.headers,
                    ok: res.statusCode >= 200 && res.statusCode < 300,
                    text: () => Promise.resolve(data),
                });
            });
        });

        req.on("error", (err) => {
            reject(err);
        });

        if (body) {
            req.write(typeof body === "object" ? JSON.stringify(body) : body);
        }
        req.end();
    });
}

// Helper to perform full signed fetch from OKX/OKLink and log details
async function fetchOklinkApi(method, targetUrl, body = null) {
    const parsedUrl = new URL(targetUrl);
    const pathName = parsedUrl.pathname;
    const params = Object.fromEntries(parsedUrl.searchParams.entries());

    const signatureHeaders = getOklinkHeaders(method, pathName, params, body);

    const targetHeaders = {
        Accept: "application/json",
        ...signatureHeaders,
    };

    console.log(
        `[OKLink Fetch] Sending request to OKLink: ${method} ${targetUrl}`,
    );
    const response = await oklinkRequest(
        method,
        targetUrl,
        targetHeaders,
        body,
    );
    const responseText = await response.text();

    console.log("\n" + "*".repeat(60));
    console.log(
        `[OKLINK RESPONSE] Status: ${response.status} ${response.statusText}`,
    );
    console.log(
        `Headers: ${JSON.stringify(response.headers && typeof response.headers.entries === "function" ? Object.fromEntries(response.headers.entries()) : response.headers, null, 2)}`,
    );
    console.log("Body:");
    let parsedJson = null;
    try {
        parsedJson = JSON.parse(responseText);
        console.log(JSON.stringify(parsedJson, null, 2));
    } catch {
        console.log(responseText);
    }
    console.log("*".repeat(60) + "\n");

    if (!response.ok) {
        throw new Error(`OKX API Error ${response.status}: ${responseText}`);
    }

    return parsedJson;
}

// Helper to extract constructor arguments from creation tx input data
function extractConstructorArgs(inputData, abiJson) {
    if (!inputData) return "";
    let abi;
    try {
        abi = typeof abiJson === "string" ? JSON.parse(abiJson) : abiJson;
    } catch {
        return "";
    }

    if (!Array.isArray(abi)) return "";

    const constructorAbi = abi.find((a) => a.type === "constructor");
    if (
        !constructorAbi ||
        !constructorAbi.inputs ||
        constructorAbi.inputs.length === 0
    ) {
        return "";
    }

    const types = constructorAbi.inputs.map((i) => i.type);
    const minBytes = types.length * 32;
    const minHexChars = minBytes * 2;

    const dataStr = inputData.startsWith("0x") ? inputData.slice(2) : inputData;
    const abiCoder = new ethers.AbiCoder();

    for (let i = minHexChars; i <= dataStr.length; i += 64) {
        const slice = "0x" + dataStr.slice(dataStr.length - i);
        try {
            abiCoder.decode(types, slice);
            return slice.slice(2);
        } catch {
            // Keep trying larger suffixes
        }
    }

    return "";
}

// Helper to extract constructor arguments specifically for ERC1967Proxy which requires the implementation address
function extractERC1967ProxyConstructorArgs(
    inputData,
    abiJson,
    implementationAddr,
) {
    if (!inputData) return "";
    let abi;
    try {
        abi = typeof abiJson === "string" ? JSON.parse(abiJson) : abiJson;
    } catch {
        return "";
    }

    if (!Array.isArray(abi)) return "";

    const constructorAbi = abi.find((a) => a.type === "constructor");
    if (
        !constructorAbi ||
        !constructorAbi.inputs ||
        constructorAbi.inputs.length === 0
    ) {
        return "";
    }

    const types = constructorAbi.inputs.map((i) => i.type);
    const minBytes = types.length * 32;
    const minHexChars = minBytes * 2;

    const dataStr = inputData.startsWith("0x") ? inputData.slice(2) : inputData;
    const abiCoder = new ethers.AbiCoder();

    const cleanImplAddr = implementationAddr.toLowerCase().replace("0x", "");
    const expectedPrefix = cleanImplAddr.padStart(64, "0");

    for (let i = minHexChars; i <= dataStr.length; i += 64) {
        const slice = dataStr.slice(dataStr.length - i);
        if (!slice.startsWith(expectedPrefix)) {
            continue;
        }

        try {
            abiCoder.decode(types, "0x" + slice);
            return slice;
        } catch {
            // Keep trying larger suffixes
        }
    }

    return "";
}

const app = express();
const PORT = process.env.PORT || 8443;

const KEY_FILE = path.join(__dirname, "key.pem");
const CERT_FILE = path.join(__dirname, "cert.pem");

// Check if HTTPS mode should be used (default is HTTP, enabled with --https or --http flags)
const useHttps =
    process.argv.includes("--https") || process.argv.includes("--http");

if (useHttps) {
    // Auto-generate certificates if missing
    if (!fs.existsSync(KEY_FILE) || !fs.existsSync(CERT_FILE)) {
        console.log("Certificates missing, generating...");
        try {
            const generateCerts = require("./generate-certs");
            generateCerts();
        } catch (err) {
            console.error("Failed to auto-generate certificates:", err);
        }
    }
}

// Set up body parsers to capture all incoming content types
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.text({ type: "*/*" }));

// Logger middleware to log every single incoming request
app.use((req, res, next) => {
    const timestamp = new Date().toISOString();
    console.log("\n" + "=".repeat(80));
    console.log(
        `[${timestamp}] INCOMING REQUEST: ${req.method} ${req.originalUrl}`,
    );
    console.log("-".repeat(40));
    console.log("HEADERS:");
    console.log(JSON.stringify(req.headers, null, 2));
    console.log("-".repeat(40));
    console.log("QUERY PARAMS:");
    console.log(JSON.stringify(req.query, null, 2));
    console.log("-".repeat(40));
    console.log("BODY:");
    if (req.body) {
        if (typeof req.body === "object") {
            console.log(JSON.stringify(req.body, null, 2));
        } else {
            console.log(req.body);
        }
    } else {
        console.log("[No Body]");
    }
    console.log("=".repeat(80) + "\n");
    next();
});

// Definition of explicit translation routes
const translators = [
    {
        method: "GET",
        path: "/",
        match: (req) => {
            const { module: mod, action, contractaddresses } = req.query;
            return (
                mod === "contract" &&
                action === "getcontractcreation" &&
                !!contractaddresses
            );
        },
        handle: async (req, res) => {
            const contractaddresses = req.query.contractaddresses;
            console.log(
                `[Route Match] Intercepted getcontractcreation request for: ${contractaddresses}`,
            );

            const targetAddress = contractaddresses.toLowerCase();
            const targetPath = "/api/v5/xlayer/address/information-evm";
            const targetParams = {
                address: targetAddress,
                chainShortName: "xlayer",
            };

            const targetUrl = `https://web3.okx.com${targetPath}?${querystring.stringify(targetParams)}`;
            console.log(
                `[Route Match] Translating to OKLink/OKX: GET ${targetUrl}`,
            );

            const oklinkData = await fetchOklinkApi("GET", targetUrl);

            let result = [];
            let dataItem = null;
            if (oklinkData && oklinkData.data) {
                if (
                    Array.isArray(oklinkData.data) &&
                    oklinkData.data.length > 0
                ) {
                    dataItem = oklinkData.data[0];
                } else if (
                    typeof oklinkData.data === "object" &&
                    !Array.isArray(oklinkData.data)
                ) {
                    dataItem = oklinkData.data;
                }
            }

            if (dataItem) {
                const creator = dataItem.createContractAddress || "";
                const txHash = dataItem.createContractTransactionHash || "";
                result.push({
                    contractAddress: contractaddresses,
                    contractCreator: creator,
                    txHash: txHash,
                });
            } else {
                result.push({
                    contractAddress: contractaddresses,
                    contractCreator: "",
                    txHash: "",
                });
            }

            const reshaped = {
                status: "1",
                message: "OK",
                result: result,
            };

            console.log("[Reshape] Reshaped Response:");
            console.log(JSON.stringify(reshaped, null, 2));

            res.setHeader("Content-Type", "application/json");
            return res.json(reshaped);
        },
    },
    {
        method: "GET",
        path: "/",
        match: (req) => {
            const { module: mod, action, address } = req.query;
            return (
                mod === "contract" && action === "getsourcecode" && !!address
            );
        },
        handle: async (req, res) => {
            const address = req.query.address;
            console.log(
                `[Route Match] Intercepted getsourcecode request for: ${address}`,
            );

            const targetAddress = address.toLowerCase();

            // Step 1: Get source code info
            const sourceCodeParams = {
                chainShortName: "xlayer",
                contractAddress: targetAddress,
            };
            const sourceCodeUrl = `https://web3.okx.com/api/v5/xlayer/contract/verify-contract-info?${querystring.stringify(sourceCodeParams)}`;
            console.log(
                `[Step 1] Fetching source code info: GET ${sourceCodeUrl}`,
            );
            const sourceCodeData = await fetchOklinkApi("GET", sourceCodeUrl);

            // Step 2: Get contract creation txid from address info
            const addressInfoParams = {
                address: targetAddress,
                chainShortName: "xlayer",
            };
            const addressInfoUrl = `https://web3.okx.com/api/v5/xlayer/address/information-evm?${querystring.stringify(addressInfoParams)}`;
            console.log(
                `[Step 2] Fetching address info to get creation tx: GET ${addressInfoUrl}`,
            );
            const addressInfoData = await fetchOklinkApi("GET", addressInfoUrl);

            let createTxId = "";
            if (addressInfoData && addressInfoData.data) {
                let addrItem = Array.isArray(addressInfoData.data)
                    ? addressInfoData.data[0]
                    : addressInfoData.data;
                if (addrItem) {
                    createTxId = addrItem.createContractTransactionHash || "";
                }
            }

            // Step 3: Fetch transaction fills using the extracted txid to get inputData
            let constructorArguments = "";
            let dataItem = null;
            if (sourceCodeData && sourceCodeData.data) {
                if (
                    Array.isArray(sourceCodeData.data) &&
                    sourceCodeData.data.length > 0
                ) {
                    dataItem = sourceCodeData.data[0];
                } else if (
                    typeof sourceCodeData.data === "object" &&
                    !Array.isArray(sourceCodeData.data)
                ) {
                    dataItem = sourceCodeData.data;
                }
            }

            if (createTxId) {
                const txParams = {
                    chainShortName: "xlayer",
                    txid: createTxId,
                };
                const txUrl = `https://web3.okx.com/api/v5/xlayer/transaction/transaction-fills?${querystring.stringify(txParams)}`;
                console.log(
                    `[Step 3] Fetching transaction fills: GET ${txUrl}`,
                );
                try {
                    const txData = await fetchOklinkApi("GET", txUrl);
                    if (txData && txData.data && txData.data.length > 0) {
                        const inputData = txData.data[0].inputData;
                        const contractAbi = dataItem
                            ? dataItem.contractAbi
                            : "";
                        const contractName = dataItem
                            ? dataItem.contractName
                            : "";
                        const implementation = dataItem
                            ? dataItem.implementation
                            : "";

                        if (contractName === "ERC1967Proxy" && implementation) {
                            constructorArguments =
                                extractERC1967ProxyConstructorArgs(
                                    inputData,
                                    contractAbi,
                                    implementation,
                                );
                        } else {
                            constructorArguments = extractConstructorArgs(
                                inputData,
                                contractAbi,
                            );
                        }
                    }
                } catch (err) {
                    console.log(
                        `[Step 3] Error fetching tx fills: ${err.message}`,
                    );
                }
            } else {
                console.log(
                    `[Step 3] Skipped transaction fills fetch since createContractTransactionHash was empty.`,
                );
            }

            // Reshape the source code data to Etherscan format
            let result = [];

            if (dataItem) {
                result.push({
                    SourceCode: dataItem.sourceCode || "",
                    ABI: dataItem.contractAbi || "",
                    ContractName: dataItem.contractName || "",
                    CompilerVersion: dataItem.compilerVersion || "",
                    CompilerType: dataItem.compilerType || "solc",
                    OptimizationUsed: dataItem.optimization || "",
                    Runs: dataItem.optimizationRuns || "",
                    ConstructorArguments: constructorArguments,
                    EVMVersion: dataItem.evmVersion || "",
                    Library: dataItem.libraryInfo || "",
                    ContractFileName: "",
                    LicenseType: dataItem.licenseType || "",
                    Proxy: dataItem.proxy || "",
                    Implementation: dataItem.implementation || "",
                    SwarmSource: dataItem.swarmSource || "",
                    SimilarMatch: "",
                });
            } else {
                result.push({
                    SourceCode: "",
                    ABI: "",
                    ContractName: "",
                    CompilerVersion: "",
                    CompilerType: "solc",
                    OptimizationUsed: "",
                    Runs: "",
                    ConstructorArguments: "",
                    EVMVersion: "",
                    Library: "",
                    ContractFileName: "",
                    LicenseType: "",
                    Proxy: "",
                    Implementation: "",
                    SwarmSource: "",
                    SimilarMatch: "",
                });
            }

            const reshaped = {
                status: "1",
                message: "OK",
                result: result,
            };

            console.log("[Reshape] Reshaped Response:");
            console.log(JSON.stringify(reshaped, null, 2));

            res.setHeader("Content-Type", "application/json");
            return res.json(reshaped);
        },
    },
];

// Register the translation routes
translators.forEach((route) => {
    const method = route.method.toLowerCase();
    app[method](route.path, async (req, res, next) => {
        try {
            if (route.match && !route.match(req)) {
                return next();
            }

            // Route matched, execute translator handle logic
            await route.handle(req, res);
        } catch (error) {
            console.error("[Error processing handled route]:", error);
            res.status(500).json({
                error: "Internal Server Error",
                message: error.message,
            });
        }
    });
});

// Catch-all for unhandled routes - respond with a 400-level error
app.use((req, res) => {
    console.log(
        `[Unhandled Route] No explicit translation route handled for ${req.method} ${req.originalUrl}`,
    );
    res.status(400).json({
        error: "Bad Request",
        message: `Route ${req.method} ${req.originalUrl} is not explicitly handled by this translator.`,
        instruction:
            "Inspect the translator console logs to see what endpoints need to be implemented.",
    });
});

// Start server (HTTPS if enabled, HTTP by default)
if (useHttps) {
    try {
        const options = {
            key: fs.readFileSync(KEY_FILE),
            cert: fs.readFileSync(CERT_FILE),
        };

        https.createServer(options, app).listen(PORT, () => {
            console.log(
                `OKLink Translator HTTPS Server running on https://localhost:${PORT}`,
            );
        });
    } catch (error) {
        console.error("Critical Error starting HTTPS server:", error);
        process.exit(1);
    }
} else {
    try {
        const http = require("http");
        http.createServer(app).listen(PORT, () => {
            console.log(
                `OKLink Translator HTTP Server running on http://localhost:${PORT}`,
            );
        });
    } catch (error) {
        console.error("Critical Error starting HTTP server:", error);
        process.exit(1);
    }
}
