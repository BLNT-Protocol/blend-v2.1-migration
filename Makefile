V2_DIR := blend-contracts-v2
COMET_DIR := comet-contracts-v1.1
ORACLE_DIR := test-sep40-oracle
RECEIVER_DIR := blend-v2.1-receiver
MIGRATION_HARNESS_DIR := migration-harness

.PHONY: build test receiver-test localnet-plan localnet-validate localnet-start localnet-deploy \
	localnet-run localnet-status localnet-stop testnet-plan testnet-validate \
	testnet-start testnet-deploy testnet-enable-emissions testnet-run testnet-status \
	testnet-resume testnet-activate-pool testnet-keeper-plan testnet-keeper-once \
	testnet-keeper localnet-activate-pool localnet-enable-emissions \
	mainnet-keeper-plan mainnet-keeper-once mainnet-keeper mainnet-keeper-status \
	mainnet-keeper-stop

build:
	bash scripts/build-v2.sh
	$(MAKE) -C $(ORACLE_DIR) build

test: build
	cd $(V2_DIR) && cargo test --all --tests --locked
	$(MAKE) -C $(COMET_DIR) test
	$(MAKE) -C $(ORACLE_DIR) test
	$(MAKE) receiver-test

receiver-test:
	$(MAKE) -C $(RECEIVER_DIR) test
	$(MAKE) -C $(RECEIVER_DIR) build
	cd $(MIGRATION_HARNESS_DIR) && cargo fmt --all -- --check
	cd $(MIGRATION_HARNESS_DIR) && cargo clippy --all-targets --locked -- -D warnings
	cd $(MIGRATION_HARNESS_DIR) && cargo test --locked

localnet-plan:
	bash scripts/deploy-v2.1.sh plan

localnet-validate:
	bash scripts/deploy-v2.1.sh validate

localnet-start:
	bash scripts/deploy-v2.1.sh start

localnet-deploy:
	bash scripts/deploy-v2.1.sh deploy

localnet-run:
	bash scripts/deploy-v2.1.sh run

localnet-status:
	bash scripts/deploy-v2.1.sh status

localnet-activate-pool:
	bash scripts/deploy-v2.1.sh activate-pool

localnet-enable-emissions:
	bash scripts/deploy-v2.1.sh enable-emissions

localnet-stop:
	bash scripts/deploy-v2.1.sh stop

testnet-plan:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh plan

testnet-validate:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh validate

testnet-start:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh start

testnet-deploy:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh deploy

testnet-resume:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh resume

testnet-activate-pool:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh activate-pool

testnet-enable-emissions:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh enable-emissions

testnet-run:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh run

testnet-status:
	BLEND_V21_NETWORK=testnet bash scripts/deploy-v2.1.sh status

testnet-keeper-plan:
	BLEND_V21_NETWORK=testnet bash scripts/emissions-keeper.sh plan

testnet-keeper-once:
	BLEND_V21_NETWORK=testnet bash scripts/emissions-keeper.sh once

testnet-keeper:
	BLEND_V21_NETWORK=testnet bash scripts/emissions-keeper.sh run

mainnet-keeper-plan:
	bash scripts/mainnet-emissions-keeper.sh plan

mainnet-keeper-once:
	bash scripts/mainnet-emissions-keeper.sh once

mainnet-keeper:
	bash scripts/mainnet-emissions-keeper.sh run

mainnet-keeper-status:
	bash scripts/mainnet-emissions-keeper.sh status

mainnet-keeper-stop:
	bash scripts/mainnet-emissions-keeper.sh stop
