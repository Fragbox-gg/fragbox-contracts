const { SecretsManager } = require("@chainlink/functions-toolkit");
const { ethers } = require("ethers");
require("dotenv").config();

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error("❌ PRIVATE_KEY must be passed via shell (see command below)");
    process.exit(1);
  }

  const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL;
  if (!rpcUrl) {
    console.error("❌ BASE_SEPOLIA_RPC_URL is missing from .env")
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const signer = new ethers.Wallet(privateKey, provider);

  const secretsManager = new SecretsManager({
    signer,
    functionsRouterAddress: "0xf9B8fc078197181C841c296C876945aaa425B278", // Base Sepolia Router
    donId: "0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000", // fun-base-sepolia-1
  });

  await secretsManager.initialize();

  const secrets = { apiKey: process.env.FACEIT_CLIENT_API_KEY };
  if (!secrets.apiKey) {
    console.error("❌ FACEIT_CLIENT_API_KEY not provided");
    process.exit(1);
  }

  console.log("🔐 Encrypting your Faceit API key...");
  const encryptedSecrets = await secretsManager.encryptSecrets(secrets);

  console.log("📤 Uploading to DON (using your gateway)...");
  const uploadResult = await secretsManager.uploadEncryptedSecretsToDON({
    encryptedSecrets,
    gatewayUrls: ["https://01.functions-gateway.testnet.chain.link/", "https://02.functions-gateway.testnet.chain.link/"], // both for reliability
    slotId: 0, // you can reuse slot 0 forever
    minutesUntilExpiration: 60 * 24 * 90, // 90 days
  });

  console.log("✅ SUCCESS! Secrets are now on the DON");
  console.log("Slot ID :", uploadResult.slotId);
  console.log("Version  :", uploadResult.version);
  console.log("\nNext: Call updateDonSecrets(" + uploadResult.slotId + ", " + uploadResult.version + ") on your contract");
}

main().catch((error) => {
  console.error("💥 Error:", error.message);
  process.exit(1);
});
