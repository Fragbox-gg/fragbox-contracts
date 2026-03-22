#!/bin/bash
echo "=== Uploading Faceit secrets to Chainlink Functions ==="

PRIVATE_KEY=$(cast wallet decrypt-keystore metamask-sepolia 2>/dev/null | grep -oE '0x[a-fA-F0-9]{64}' | tail -n1) \
node uploadFaceitSecretsToBaseSepolia.js