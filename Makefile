# HTP local operator shortcuts.
# Anvil is bound to 127.0.0.1 only. Do not expose it to the network.

.DEFAULT_GOAL := help

FORGE := forge
CAST := cast
NPM := npm
CONTRACTS := contracts
ANVIL_HOST := 127.0.0.1
ANVIL_PORT := 8545
ANVIL_URL := http://127.0.0.1:8545
ANVIL_PID := deploy/out/anvil.pid
ANVIL_LOG := deploy/out/anvil.log
ANVIL_TIMESTAMP := 1780000100
# anvil 的 --timestamp 只设创世时间，之后区块时间跟着真实时钟走。成交窗口受
# ProtocolSecurityLimits.MAX_QUOTE_LIFETIME（1 小时）约束，链上时钟一旦漂出这个
# 范围，settle 会以 InvalidSettlementTimeWindow 失败，而现象埋在很深的 trace 里。
ANVIL_MAX_CLOCK_DRIFT := 300
RPC_URL ?= http://127.0.0.1:8545
E2E_SCRIPT := script/e2e/UsdyOperatorPipeline.s.sol:UsdyOperatorPipeline
# Anvil default account[0]. Local node only.
ANVIL0_ADDR := 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

.PHONY: help setup toolchain fmt fmt-fix build size \
	test-unit test-integration test-e2e test-fuzz test-invariant test-all test-contracts \
	e2e e2e-fork anvil anvil-stop \
	phase17 phase18 fork-usdy deploy-config

help:
	@echo "HTP make targets"
	@echo ""
	@echo "  make setup              submodule + npm ci + toolchain check"
	@echo "  make toolchain          check pinned Foundry/solc/node versions"
	@echo "  make fmt / fmt-fix      check or apply forge fmt"
	@echo "  make build / size       compile / print contract sizes"
	@echo ""
	@echo "  make anvil              start local node on 127.0.0.1:8545"
	@echo "  make e2e                start Anvil, broadcast pipeline, then stop Anvil"
	@echo "  make e2e-fork           broadcast onto an already running Anvil"
	@echo "  make anvil-stop         stop the make-started anvil process"
	@echo "  make test-e2e           simulate the pipeline locally (no Anvil)"
	@echo ""
	@echo "  make test-unit          npm run contracts:unit"
	@echo "  make test-integration   npm run contracts:integration"
	@echo "  make test-fuzz          npm run contracts:fuzz"
	@echo "  make test-invariant     npm run contracts:invariant"
	@echo "  make test-all           every forge test (incl. audit/fuzz/invariant)"
	@echo "  make test-contracts     test-all + e2e simulation"
	@echo ""
	@echo "  make phase17            schema/vector gate"
	@echo "  make phase18            deploy config + USDY fork skip/verify"
	@echo "  make fork-usdy          USDY fixed-block fork (skips without approval)"
	@echo "  make deploy-config      validate local deploy JSON"

setup:
	git submodule sync --recursive
	git submodule update --init --recursive
	$(NPM) ci
	$(NPM) run toolchain:check

toolchain:
	$(NPM) run toolchain:check

fmt:
	$(NPM) run contracts:fmt

fmt-fix:
	$(FORGE) fmt --root $(CONTRACTS)

build:
	$(NPM) run contracts:build

size:
	$(NPM) run contracts:size

test-unit:
	$(NPM) run contracts:unit

test-integration:
	$(NPM) run contracts:integration

test-e2e:
	cd $(CONTRACTS) && $(FORGE) script $(E2E_SCRIPT) -vvv

test-fuzz:
	$(NPM) run contracts:fuzz

test-invariant:
	$(NPM) run contracts:invariant

test-all:
	$(NPM) run contracts:test

# 跑整个 forge test 而不是枚举目录：按目录枚举会随着新增目录静默失效，
# audit / fuzz / invariant / validation 四类正是这样长期落在聚合目标之外的。
test-contracts: test-all test-e2e

anvil:
	@mkdir -p deploy/out
	@if [ -f "$(ANVIL_PID)" ] && kill -0 "$$(cat $(ANVIL_PID))" 2>/dev/null; then \
		echo "anvil already running pid=$$(cat $(ANVIL_PID)) $(ANVIL_URL)"; \
	else \
		nohup anvil --host $(ANVIL_HOST) --port $(ANVIL_PORT) --timestamp $(ANVIL_TIMESTAMP) \
			--auto-impersonate > $(ANVIL_LOG) 2>&1 & \
		echo $$! > $(ANVIL_PID); \
		ready=0; \
		for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
			if curl -s -o /dev/null --connect-timeout 1 -X POST $(ANVIL_URL) \
				-H 'content-type: application/json' \
				--data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'; then \
				ready=1; \
				break; \
			fi; \
			sleep 0.2; \
		done; \
		if [ "$$ready" != "1" ]; then \
			echo "anvil failed to listen on $(ANVIL_URL)"; \
			exit 1; \
		fi; \
		echo "anvil started pid=$$(cat $(ANVIL_PID)) $(ANVIL_URL)"; \
	fi
	@# 就绪探测只证明「有 anvil 在应答」，不证明是我们刚起的那一个。校验链上时钟，
	@# 把「跑在了别的链上」变成此处一条明确的失败，而不是深藏在结算 trace 里的时间窗错误。
	@ts=$$($(CAST) block latest --field timestamp --rpc-url $(ANVIL_URL) 2>/dev/null); \
	if [ -z "$$ts" ]; then \
		echo "cannot read block timestamp from $(ANVIL_URL)"; \
		exit 1; \
	fi; \
	drift=$$(( ts - $(ANVIL_TIMESTAMP) )); \
	if [ "$$drift" -lt 0 ] || [ "$$drift" -gt $(ANVIL_MAX_CLOCK_DRIFT) ]; then \
		echo "anvil clock drifted $$drift s from --timestamp $(ANVIL_TIMESTAMP) (max $(ANVIL_MAX_CLOCK_DRIFT) s)."; \
		echo "多半是端口上有残留的 anvil 实例。先 make anvil-stop 再重试。"; \
		exit 1; \
	fi

anvil-stop:
	@if [ -f "$(ANVIL_PID)" ]; then \
		kill "$$(cat $(ANVIL_PID))" 2>/dev/null || true; \
		rm -f $(ANVIL_PID); \
		echo "anvil stopped"; \
	else \
		echo "no $(ANVIL_PID); nothing to stop"; \
	fi
	@# pid 文件丢失或进程换过身份时按端口兜底。残留实例会占住端口让新 anvil 起不来，
	@# 而旧链的时钟已经漂了几十小时——e2e 会静默跑在上面，报出难以归因的结算错误。
	@stale=$$(lsof -nP -iTCP:$(ANVIL_PORT) -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $$1 ~ /anvil/ { print $$2 }'); \
	if [ -n "$$stale" ]; then \
		echo "killing stale anvil holding port $(ANVIL_PORT): $$stale"; \
		kill $$stale 2>/dev/null || true; \
		sleep 1; \
	fi

e2e:
	@$(MAKE) anvil-stop
	@$(MAKE) anvil
	@trap '$(MAKE) -C "$(CURDIR)" anvil-stop' EXIT; \
	$(CAST) rpc anvil_autoImpersonateAccount true --rpc-url $(ANVIL_URL) >/dev/null; \
	cd $(CONTRACTS) && $(FORGE) script $(E2E_SCRIPT) \
		--rpc-url $(ANVIL_URL) \
		--broadcast \
		--unlocked \
		--slow \
		--sender $(ANVIL0_ADDR) \
		-vvv

e2e-fork:
	@if ! curl -s -o /dev/null --connect-timeout 1 -X POST $(ANVIL_URL) \
		-H 'content-type: application/json' \
		--data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'; then \
		echo "anvil is not reachable at $(ANVIL_URL). Run: make anvil"; \
		exit 1; \
	fi
	@$(CAST) rpc anvil_autoImpersonateAccount true --rpc-url $(ANVIL_URL) >/dev/null
	cd $(CONTRACTS) && $(FORGE) script $(E2E_SCRIPT) \
		--rpc-url $(ANVIL_URL) \
		--broadcast \
		--unlocked \
		--slow \
		--sender $(ANVIL0_ADDR) \
		-vvv

phase17:
	$(NPM) run phase17:test

phase18:
	$(NPM) run phase18:test

fork-usdy:
	$(NPM) run phase18:fork:usdy

deploy-config:
	$(NPM) run phase18:config
