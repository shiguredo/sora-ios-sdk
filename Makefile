.PHONY: all api-baseline api-check api-check-fresh build consumer-build consumer-check-negative fmt fmt-lint lint

# Swift 6 consumer package のディレクトリ
CONSUMER_DIR := TestConsumers/Swift6Consumer

# swift-format の対象
FORMAT_PATHS := Sora SoraTests $(CONSUMER_DIR)/Sources $(CONSUMER_DIR)/NegativeChecks $(CONSUMER_DIR)/Package.swift

# すべてを実行
all: fmt fmt-lint lint

# swift-format
fmt:
	swift format --in-place --recursive $(FORMAT_PATHS)

# build
build:
	xcodebuild \
		-scheme 'Sora' \
		-sdk iphoneos26.2 \
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
	swift format lint --strict --parallel --recursive $(FORMAT_PATHS)

# SwiftLint
lint:
	swift package plugin --allow-writing-to-package-directory swiftlint --fix .
	swift package plugin --allow-writing-to-package-directory swiftlint --strict .

# Swift 6 consumer package
# Xcode と SDK は CI の matrix から XCODE=... XCODE_SDK=... として渡す
XCODE ?= /Applications/Xcode.app
XCODE_SDK ?= iphoneos26.5
CONFIGURATION := Release
DERIVED_DATA ?= $(CURDIR)/build/consumer
# DERIVED_DATA を相対パスで上書きされても cd の影響を受けないよう絶対パスから導出する
DERIVED_DATA_ABS := $(abspath $(DERIVED_DATA))
PRODUCTS := $(DERIVED_DATA_ABS)/Build/Products/$(CONFIGURATION)-iphoneos
MODULE_CACHE := $(DERIVED_DATA_ABS)/module-cache
API_CHECK_LOG := $(DERIVED_DATA_ABS)/api-check.log
NEGATIVE_CHECK_LOG := $(DERIVED_DATA_ABS)/negative-check.log
API_BASELINE_DUMP := $(DERIVED_DATA_ABS)/api-baseline.json
# 現在の module から取った fresh な dump と、その比較結果の log。どちらも build 配下に置く
API_BASELINE_FRESH := $(DERIVED_DATA_ABS)/api-baseline-fresh.json
API_CHECK_FRESH_LOG := $(DERIVED_DATA_ABS)/api-check-fresh.log
API_TARGET := arm64-apple-ios14.0
# baseline の file 名は SDK 名から導出する。SDK を変えるときは XCODE_SDK だけを変える
API_BASELINE ?= $(CONSUMER_DIR)/ApiBaseline/$(XCODE_SDK).json
API_BASELINE_INFO ?= $(CONSUMER_DIR)/ApiBaseline/$(XCODE_SDK).info.txt
# baseline を生成する Xcode と SDK。api-check は実行環境が baseline と同じであることを確認する
# (XCODE の path (CI は Xcode_26.6.app) とは別に、版だけをここで管理する)
API_XCODE ?= 26.6
API_SDK_VERSION := $(patsubst iphoneos%,%,$(XCODE_SDK))
API_BASELINE_MIN_BYTES := 1048576
SCHEME ?= ConsumerCore

# baseline の JSON が比較に使えるかを検証する (module を読めずに書かれた NO_MODULE や切り詰めを弾く)
API_VALIDATE = python3 -c "import json,os,sys; p=sys.argv[1]; \
	d=json.load(open(p)); r=d['ABIRoot']; assert r['name'] == 'Sora'; \
	assert len(r['children']) >= 100; \
	assert os.path.getsize(p) >= $(API_BASELINE_MIN_BYTES)"

# commit 済み baseline と fresh な dump の差分を宣言単位で要約し、整形した JSON の行差分を log に書く。
# 終了コードは 0 = 一致、1 = 比較失敗、2 = 差分あり。差分の全量は log に、標準出力には先頭 200 行を出す。
# export した値をレシピから参照するため、直接展開しない (改行がシェルの行区切りとして解釈される)。
# `$` はここでは書かない (export 時に make が展開するため)。`"` はそのまま書いてよい。
define API_BASELINE_DIFF
import difflib, json, sys

def fail(message):
    print("Error: " + message, file=sys.stderr)
    sys.exit(1)

def collect(value):
    found = {}
    def walk(node):
        if isinstance(node, dict):
            if "declKind" in node:
                decl_kind = node.get("declKind", "")
                printed = node.get("printedName", node.get("name", ""))
                usr = node.get("usr")
                if usr:
                    key = ("usr", usr)
                else:
                    key = ("decl", decl_kind, printed)
                found[key] = (decl_kind, printed)
            for child in node.get("children") or []:
                walk(child)
    walk(value)
    return found

if len(sys.argv) != 4:
    fail("usage: api-check-fresh <committed baseline> <fresh dump> <log>")

baseline_path = sys.argv[1]
fresh_path = sys.argv[2]
log_path = sys.argv[3]

try:
    with open(baseline_path) as handle:
        baseline = json.load(handle)
except Exception as error:
    fail("failed to load the committed API baseline: " + str(error))

try:
    with open(fresh_path) as handle:
        fresh = json.load(handle)
except Exception as error:
    fail("failed to load the fresh API baseline dump: " + str(error))

if baseline == fresh:
    print("The committed API baseline matches the current Sora module.")
    sys.exit(0)

try:
    baseline_declarations = collect(baseline["ABIRoot"])
    fresh_declarations = collect(fresh["ABIRoot"])
except Exception as error:
    fail("failed to collect declarations from the API baseline: " + str(error))

removed = sorted(set(baseline_declarations) - set(fresh_declarations))
added = sorted(set(fresh_declarations) - set(baseline_declarations))

print("Removed declarations ({}):".format(len(removed)))
for key in removed:
    decl_kind, printed = baseline_declarations[key]
    print("  - {} [{}]".format(printed, decl_kind))
print("Added declarations ({}):".format(len(added)))
for key in added:
    decl_kind, printed = fresh_declarations[key]
    print("  + {} [{}]".format(printed, decl_kind))

baseline_lines = json.dumps(baseline, indent=2, sort_keys=True).splitlines()
fresh_lines = json.dumps(fresh, indent=2, sort_keys=True).splitlines()
diff_lines = list(difflib.unified_diff(
    baseline_lines, fresh_lines, fromfile=baseline_path, tofile=fresh_path, lineterm=""))

try:
    with open(log_path, "w") as handle:
        handle.write("\n".join(diff_lines))
        if diff_lines:
            handle.write("\n")
except Exception as error:
    fail("failed to write the diff log: " + str(error))

preview_limit = 200
if len(diff_lines) <= preview_limit:
    if diff_lines:
        print("\n".join(diff_lines))
else:
    print("\n".join(diff_lines[:preview_limit]))
    print("... truncated: showing {} of {} diff lines. Full diff: {}".format(
        preview_limit, len(diff_lines), log_path))

sys.exit(2)
endef
export API_BASELINE_DIFF

# xcodebuild は XCODE という引数を解釈しないため、環境変数として渡す。
# consumer package 系の target にだけ効かせる (既存の build / fmt / fmt-lint / lint の
# toolchain 選択と、利用者が指定した DEVELOPER_DIR を変えないため)
consumer-build consumer-check-negative api-baseline api-check api-check-fresh: export DEVELOPER_DIR = $(XCODE)/Contents/Developer

# 1 scheme だけを Release で build する。CI は scheme ごとに step を分ける
consumer-build:
	cd $(CONSUMER_DIR) && xcodebuild \
		-scheme '$(SCHEME)' \
		-sdk $(XCODE_SDK) \
		-configuration $(CONFIGURATION) \
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
			if [ ! -e "$$file" ]; then \
				echo "Error: NegativeChecks/*.swift is empty"; exit 1; \
			fi; \
			name="$$(basename "$$file" .swift)"; \
			case "$$name" in \
				core-*) isolation=nonisolated ;; \
				ui-*) isolation=MainActor ;; \
				*) echo "Error: NegativeChecks file name must start with 'core-' or 'ui-': $$file"; exit 1 ;; \
			esac; \
			expected="$$(sed -n '1s|^// EXPECT-DIAGNOSTIC: ||p' "$$file" | tr -d '\r')"; \
			case "$$expected" in \
				""|*[!A-Za-z0-9]*) echo "Error: EXPECT-DIAGNOSTIC must be a diagnostic group name: $$file"; exit 1 ;; \
			esac; \
			echo "typecheck (expect failure): $$file [$$expected]"; \
			if xcrun swiftc -typecheck -swift-version 6 -default-isolation "$$isolation" \
				-sdk "$$sdk_path" -target $(API_TARGET) \
				-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
				-module-cache-path "$(MODULE_CACHE)" \
				"$$file" > "$(NEGATIVE_CHECK_LOG)" 2>&1; then \
				echo "Error: compilation succeeded but a failure is expected: $$file"; exit 1; \
			fi; \
			if ! grep -Eq "^[^:]+:[0-9]+(:[0-9]+)?: error: .*\[#$$expected\]" "$(NEGATIVE_CHECK_LOG)"; then \
				echo "Error: no 'error' diagnostic with '[#$$expected]' was reported: $$file"; \
				cat "$(NEGATIVE_CHECK_LOG)"; \
				exit 1; \
			fi; \
			if grep -E "^[^:]+:[0-9]+(:[0-9]+)?: error:" "$(NEGATIVE_CHECK_LOG)" | grep -qvF "[#$$expected]"; then \
				echo "Error: an unexpected error diagnostic was reported: $$file"; \
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
	# 前回の dump を残したままだと、書き出しに失敗しても古い dump を検証してしまう
	@rm -f "$(API_BASELINE_DUMP)"
	@xcrun swift-api-digester -dump-sdk -module Sora -o "$(API_BASELINE_DUMP)" \
		-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
		-sdk "$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)" -target "$(API_TARGET)" \
		-module-cache-path "$(MODULE_CACHE)" -avoid-location -avoid-tool-args
	@$(API_VALIDATE) "$(API_BASELINE_DUMP)"
	@mkdir -p "$(dir $(API_BASELINE))"
	@cp "$(API_BASELINE_DUMP)" "$(API_BASELINE)"
	@set -e; \
		echo "xcodebuild: $$(xcodebuild -version | head -1)" > "$(API_BASELINE_INFO)"; \
		echo "sdk: $$(xcrun --sdk $(XCODE_SDK) --show-sdk-version)" >> "$(API_BASELINE_INFO)"; \
		echo "target: $(API_TARGET)" >> "$(API_BASELINE_INFO)"
	@echo "generated: $(API_BASELINE)"

# commit 済み baseline と build 済み module を比較し、公開 API の削除・変更・準拠の削除を検出する
api-check: consumer-build
	@[ -f "$(API_BASELINE)" ] || { echo "Error: $(API_BASELINE) is missing"; exit 1; }
	@$(API_VALIDATE) "$(API_BASELINE)"
	@set -e; \
		if [ ! -f "$(API_BASELINE_INFO)" ]; then \
			echo "Error: $(API_BASELINE_INFO) is missing"; exit 1; \
		fi; \
		baseline_xcode="$$(sed -n 's/^xcodebuild: //p' "$(API_BASELINE_INFO)")"; \
		baseline_sdk="$$(sed -n 's/^sdk: //p' "$(API_BASELINE_INFO)")"; \
		baseline_target="$$(sed -n 's/^target: //p' "$(API_BASELINE_INFO)")"; \
		actual_xcode="$$(xcodebuild -version | head -1)"; \
		actual_sdk="$$(xcrun --sdk $(XCODE_SDK) --show-sdk-version)"; \
		if [ "$$baseline_xcode" != "$$actual_xcode" ] || [ "$$baseline_sdk" != "$$actual_sdk" ] || [ "$$baseline_target" != "$(API_TARGET)" ]; then \
			echo "Error: the baseline was generated with $$baseline_xcode / SDK $$baseline_sdk / target $$baseline_target but the current environment is $$actual_xcode / SDK $$actual_sdk / target $(API_TARGET)"; \
			echo "Error: run api-check with the same Xcode, SDK and target that generated the baseline"; \
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
	# 差分が無ければ digester の出力は空になる。出力があれば (breakage でも toolchain の
	# 仕様変更でも) 失敗させる。文言だけに依存すると無言で常に成功する gate になるため
	@if [ -s "$(API_CHECK_LOG)" ]; then \
		echo "Error: the API comparison produced output. See $(API_CHECK_LOG)."; \
		grep -Fq 'API breakage' "$(API_CHECK_LOG)" && echo 'Error: public API breakage detected.'; \
		exit 1; \
	fi

# commit 済み baseline が現在の module と一致していることを検証する。api-check が削除・変更を検出し、
# この target が fresh な dump との一致 (追加を含むすべての差分) を検証する。CI が呼ぶ API target
api-check-fresh: api-check
	# 前回の dump と log を残したままだと、書き出しに失敗しても古い内容を比較に使ってしまう
	@rm -f "$(API_BASELINE_FRESH)" "$(API_CHECK_FRESH_LOG)"
	@xcrun swift-api-digester -dump-sdk -module Sora -o "$(API_BASELINE_FRESH)" \
		-I "$(PRODUCTS)" -F "$(PRODUCTS)" \
		-sdk "$$(xcrun --sdk $(XCODE_SDK) --show-sdk-path)" -target "$(API_TARGET)" \
		-module-cache-path "$(MODULE_CACHE)" -avoid-location -avoid-tool-args
	@$(API_VALIDATE) "$(API_BASELINE_FRESH)"
	# 差分あり (終了コード 2) と比較失敗 (その他の非 0) を区別する。分岐内の echo だけでは
	# recipe の終了ステータスが 0 のままになり gate が無言で成功するため、必ず exit 1 する
	@if python3 -c "$$API_BASELINE_DIFF" "$(API_BASELINE)" "$(API_BASELINE_FRESH)" "$(API_CHECK_FRESH_LOG)"; then \
		:; \
	else \
		status=$$?; \
		if [ "$$status" -eq 2 ]; then \
			echo "Error: the committed API baseline does not match the current Sora module."; \
			echo "Error: run 'make api-baseline' and include the regenerated baseline in the same change."; \
		else \
			echo "Error: failed to compare the committed API baseline with the current Sora module."; \
		fi; \
		exit 1; \
	fi
