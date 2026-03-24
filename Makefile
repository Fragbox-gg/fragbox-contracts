-include .env

.PHONY: all test clean deploy fund help install snapshot format anvil 

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_RPC_URL := http://127.0.0.1:8545

help:
	@echo "Usage:"
	@echo "  make deploy [ARGS=...]\n    example: make deploy ARGS=\"--network sepolia\""
	@echo ""
	@echo "  make fund [ARGS=...]\n    example: make deploy ARGS=\"--network sepolia\""

all: clean remove install update build

# Clean the repo
clean :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install smartcontractkit/chainlink-brownie-contracts@1.3.0 && forge install Cyfrin/foundry-devops@0.4.0 && forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 

test :; forge test --match-contract FragBoxBettingTest --fork-url $(BASE_SEPOLIA_RPC_URL) --ffi -vv

test_fuzz :; forge test --match-contract FragBoxBettingFuzzTest --fork-url $(ANVIL_RPC_URL) --ffi -vv

test_invariant :; forge test --match-contract FragBoxBettingInvariantTest --fork-url $(ANVIL_RPC_URL) --ffi -vv

coverage :; forge coverage --ir-minimum --fork-url $(BASE_SEPOLIA_RPC_URL) # --report debug > coverage-report.txt

snapshot :; forge snapshot --fork-url $(BASE_SEPOLIA_RPC_URL) --ffi

format :; forge fmt

anvil :; anvil --fork-url $(BASE_SEPOLIA_RPC_URL)

NETWORK_ARGS := --rpc-url http://localhost:8545 --account defaultKey --broadcast

ifeq ($(findstring --network sepolia,$(ARGS)),--network sepolia)
	NETWORK_ARGS := --rpc-url $(BASE_SEPOLIA_RPC_URL) --account metamask-sepolia --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
endif

deploy:
	@forge script script/DeployFragBoxBetting.s.sol:DeployFragBoxBetting $(NETWORK_ARGS)


# ---------------------------------------------------------------------------- #
#                 CI-friendly targets (used by GitHub Actions)                 #
# ---------------------------------------------------------------------------- #

# Starts Anvil in background using a generous public RPC (saves your Alchemy quota)
anvil-ci:
	@echo "Starting Anvil (publicnode) in background..."
	anvil --fork-url $(BASE_SEPOLIA_RPC_URL) --no-rate-limit --silent & \
	echo $$! > anvil.pid
	sleep 5  # give Anvil time to start

# Runs your regular unit tests (fast, uses offline mode)
test-unit:
	@echo "Running unit tests..."
	forge test --match-contract FragBoxBettingTest --fork-url $(ANVIL_RPC_URL) --ffi -vv

# Runs fuzz tests against local Anvil
test-fuzz:
	@echo "Running fuzz tests..."
	forge test --match-contract FragBoxBettingFuzzTest --ffi --fork-url $(ANVIL_RPC_URL) -vv

# Runs invariant tests against local Anvil
test-invariant:
	@echo "Running invariant tests..."
	forge test --match-contract FragBoxBettingInvariantTest --ffi --fork-url $(ANVIL_RPC_URL) -vv

# Cleanup Anvil (called at the end)
kill-anvil:
	@if [ -f anvil.pid ]; then \
		kill `cat anvil.pid` 2>/dev/null || true; \
		rm -f anvil.pid; \
	fi