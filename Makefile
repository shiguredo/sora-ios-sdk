.PHONY: all api-baseline api-check build consumer-build consumer-check-negative fmt fmt-lint lint

# すべてを実行
all: fmt fmt-lint lint

# swift-format
fmt:
	swift format --in-place --recursive Sora SoraTests \
		Fixtures/Swift6Consumer/Sources \
		Fixtures/Swift6Consumer/NegativeChecks \
		Fixtures/Swift6Consumer/Package.swift

# build
build:
	xcodebuild \
		-scheme 'Sora' \
		-sdk iphoneos26.1 \
		-configuration Release \
		-derivedDataPath build \
		-destination 'generic/platform=iOS' \
		clean build \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		PROVISIONING_PROFILE= \
		SWIFT_VERSION=6

# swift-format lint
fmt-lint:
	swift format lint --strict --parallel --recursive Sora SoraTests \
		Fixtures/Swift6Consumer/Sources \
		Fixtures/Swift6Consumer/NegativeChecks \
		Fixtures/Swift6Consumer/Package.swift

# SwiftLint
lint:
	swift package plugin --allow-writing-to-package-directory swiftlint --fix .
	swift package plugin --allow-writing-to-package-directory swiftlint --strict .

# Swift 6 consumer fixture
# Xcode と SDK は CI の matrix から XCODE=... XCODE_SDK=... として渡す
XCODE ?= /Applications/Xcode.app
XCODE_SDK ?= iphoneos26.5
DERIVED_DATA ?= $(CURDIR)/build/consumer
# DERIVED_DATA を相対パスで上書きされても cd の影響を受けないよう絶対パスから導出する
DERIVED_DATA_ABS := $(abspath $(DERIVED_DATA))
CONSUMER_DIR := Fixtures/Swift6Consumer
PRODUCTS := $(DERIVED_DATA_ABS)/Build/Products/Release-iphoneos
MODULE_CACHE := $(DERIVED_DATA_ABS)/module-cache
API_CHECK_LOG := $(DERIVED_DATA_ABS)/api-check.log
NEGATIVE_CHECK_LOG := $(DERIVED_DATA_ABS)/negative-check.log
API_BASELINE_DUMP := $(DERIVED_DATA_ABS)/api-baseline.json
API_TARGET := arm64-apple-ios14.0
API_BASELINE ?= $(CONSUMER_DIR)/ApiBaseline/iphoneos26.5.json
API_BASELINE_INFO ?= $(CONSUMER_DIR)/ApiBaseline/iphoneos26.5.info.txt
# baseline を生成する Xcode と SDK。api-check は実行環境が baseline と同じであることを確認する
API_XCODE ?= 26.6
API_SDK_VERSION ?= 26.5
SCHEME ?= ConsumerCore

# xcodebuild は XCODE という引数を解釈しないため、環境変数として渡す。
# fixture 系の target にだけ効かせる (既存の build / fmt / fmt-lint / lint の
# toolchain 選択と、利用者が指定した DEVELOPER_DIR を変えないため)
consumer-build consumer-check-negative api-baseline api-check: export DEVELOPER_DIR = $(XCODE)/Contents/Developer

# 1 scheme だけを Release で build する。CI は scheme ごとに step を分ける
consumer-build:
	cd $(CONSUMER_DIR) && xcodebuild \
		-scheme '$(SCHEME)' \
		-sdk $(XCODE_SDK) \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DATA_ABS)" \
		-destination 'generic/platform=iOS' \
		build \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		PROVISIONING_PROFILE=

# compile 失敗を期待する file を 1 file ずつ typecheck する
# file 名の接頭辞で既定隔離を決め、1 行目の EXPECT-DIAGNOSTIC で診断名を確認する
consumer-check-negative: consumer-build
	@set -e; \
		cd $(CONSUMER_DIR); \
		sdk_path="$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)"; \
		count=0; \
		for file in NegativeChecks/*.swift; do \
			name="$$(basename "$$file" .swift)"; \
			case "$$name" in \
				core-*) isolation=nonisolated ;; \
				ui-*) isolation=MainActor ;; \
				*) echo "Error: NegativeChecks file name must start with 'core-' or 'ui-': $$file"; exit 1 ;; \
			esac; \
			expected="$$(sed -n '1s|^// EXPECT-DIAGNOSTIC: ||p' "$$file")"; \
			if [ -z "$$expected" ]; then \
				echo "Error: EXPECT-DIAGNOSTIC is missing: $$file"; exit 1; \
			fi; \
			echo "typecheck (expect failure): $$file [$$expected]"; \
			if xcrun swiftc -typecheck -swift-version 6 -default-isolation "$$isolation" \
				-sdk "$$sdk_path" -target $(API_TARGET) \
				-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
				-module-cache-path "$(MODULE_CACHE)" \
				"$$file" > "$(NEGATIVE_CHECK_LOG)" 2>&1; then \
				echo "Error: compilation succeeded but a failure is expected: $$file"; exit 1; \
			fi; \
			if ! grep -Eq "error: .*\[#$$expected\]" "$(NEGATIVE_CHECK_LOG)"; then \
				echo "Error: no 'error' diagnostic with '[#$$expected]' was reported: $$file"; \
				cat "$(NEGATIVE_CHECK_LOG)"; \
				exit 1; \
			fi; \
			count=$$((count + 1)); \
		done; \
		echo "$(CONSUMER_DIR): $$count negative check(s) failed as expected"

# 公開 API の baseline を生成する。commit 済み baseline を書き換える唯一の target
api-baseline: consumer-build
	@set -e; \
		actual_xcode="$$(xcodebuild -version | head -1)"; \
		actual_sdk="$$(xcrun --sdk $(XCODE_SDK) --show-sdk-version)"; \
		if [ "$$actual_xcode" != "Xcode $(API_XCODE)" ] || [ "$$actual_sdk" != "$(API_SDK_VERSION)" ]; then \
			echo "Error: the baseline must be generated with Xcode $(API_XCODE) and $(XCODE_SDK) ($(API_SDK_VERSION)) (current: $$actual_xcode / SDK $$actual_sdk)"; \
			exit 1; \
		fi
	@mkdir -p "$(DERIVED_DATA_ABS)" "$(MODULE_CACHE)"
	@xcrun swift-api-digester -dump-sdk -module Sora -o "$(API_BASELINE_DUMP)" \
		-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
		-sdk "$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)" -target "$(API_TARGET)" \
		-module-cache-path "$(MODULE_CACHE)" -avoid-location -avoid-tool-args
	@set -e; python3 -c "import json,os,sys; p=sys.argv[1]; \
		d=json.load(open(p)); assert d['ABIRoot']['name'] == 'Sora'; \
		assert os.path.getsize(p) >= 1048576" "$(API_BASELINE_DUMP)"
	@mkdir -p "$(dir $(API_BASELINE))"
	@cp "$(API_BASELINE_DUMP)" "$(API_BASELINE)"
	@set -e; \
		echo "xcodebuild: $$(xcodebuild -version | head -1)" > "$(API_BASELINE_INFO)"; \
		echo "sdk: $$(xcrun --sdk $(XCODE_SDK) --show-sdk-version)" >> "$(API_BASELINE_INFO)"; \
		echo "target: $(API_TARGET)" >> "$(API_BASELINE_INFO)"
	@echo "generated: $(API_BASELINE)"

# commit 済み baseline と build 済み module を比較する。CI が呼ぶ唯一の API target
api-check: consumer-build
	@set -e; python3 -c "import json,os,sys; p=sys.argv[1]; \
		d=json.load(open(p)); assert d['ABIRoot']['name'] == 'Sora'; \
		assert os.path.getsize(p) >= 1048576" "$(API_BASELINE)"
	@set -e; \
		if [ ! -f "$(API_BASELINE_INFO)" ]; then \
			echo "Error: $(API_BASELINE_INFO) is missing"; exit 1; \
		fi; \
		baseline_xcode="$$(sed -n 's/^xcodebuild: //p' "$(API_BASELINE_INFO)")"; \
		baseline_sdk="$$(sed -n 's/^sdk: //p' "$(API_BASELINE_INFO)")"; \
		actual_xcode="$$(xcodebuild -version | head -1)"; \
		actual_sdk="$$(xcrun --sdk $(XCODE_SDK) --show-sdk-version)"; \
		if [ "$$baseline_xcode" != "$$actual_xcode" ] || [ "$$baseline_sdk" != "$$actual_sdk" ]; then \
			echo "Error: the baseline was generated with $$baseline_xcode / SDK $$baseline_sdk but the current environment is $$actual_xcode / SDK $$actual_sdk"; \
			echo "Error: run api-check with the same Xcode and SDK that generated the baseline"; \
			exit 1; \
		fi
	@mkdir -p "$(MODULE_CACHE)"
	@set -o pipefail; \
		xcrun swift-api-digester -diagnose-sdk -module Sora \
			-baseline-path "$(API_BASELINE)" \
			-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
			-sdk "$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)" \
			-target "$(API_TARGET)" -module-cache-path "$(MODULE_CACHE)" \
			-compiler-style-diags 2>&1 | tee "$(API_CHECK_LOG)"
	@if grep -Fq 'API breakage' "$(API_CHECK_LOG)"; then \
		echo 'Error: public API breakage detected.'; exit 1; \
	fi
