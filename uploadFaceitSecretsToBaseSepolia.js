const { SecretsManager } = require("@chainlink/functions-toolkit");
const { ethers } = require("ethers");
require("dotenv").config();

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error("❌ PRIVATE_KEY must be passed via shell (use your upload-faceit.sh script)");
    process.exit(1);
  }

  const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL;
  if (!rpcUrl) {
    console.error("❌ BASE_SEPOLIA_RPC_URL is missing from .env");
    process.exit(1);
  }

  // ethers v5 syntax (required by the toolkit)
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const signer = new ethers.Wallet(privateKey).connect(provider);

  const secretsManager = new SecretsManager({
    signer,
    functionsRouterAddress: "0xf9B8fc078197181C841c296C876945aaa425B278", // Base Sepolia Router
    donId: "fun-base-sepolia-1",   // string version (not hex)
  });

  await secretsManager.initialize();

  const secrets = { apiKey: process.env.FACEIT_CLIENT_API_KEY };
  if (!secrets.apiKey) {
    console.error("❌ FACEIT_CLIENT_API_KEY not provided");
    process.exit(1);
  }

  console.log("🔐 Encrypting your Faceit API key...");
  const encryptedSecretsObj = await secretsManager.encryptSecrets(secrets);   // ← now an object

  console.log("📤 Uploading to DON (using your gateway)...");
  const uploadResult = await secretsManager.uploadEncryptedSecretsToDON({
    encryptedSecretsHexstring: encryptedSecretsObj.encryptedSecrets,   // ← THIS WAS THE FIX
    gatewayUrls: [
      "https://01.functions-gateway.testnet.chain.link/",
      "https://02.functions-gateway.testnet.chain.link/"
    ],
    slotId: 0, // you can reuse slot 0 forever
    minutesUntilExpiration: 60 * 24 * 2,  // 2 days = max safe on testnet (4320 minutes)
  });

  console.log("✅ SUCCESS! Secrets are now on the DON");
  console.log("Slot ID :", 0);
  console.log("Version  :", uploadResult.version);
  console.log("\nNext: Call updateDonSecrets(0, " + uploadResult.version + ") on your contract");
}

main().catch((error) => {
  console.error("💥 Error:", error.message);
  process.exit(1);
});