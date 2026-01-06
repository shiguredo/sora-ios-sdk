.PHONY: build fmt fmt-lint lint

# すべてを実行
all: fmt fmt-lint lint

# swift-format
fmt:
	swift format --in-place --recursive Sora SoraTests

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
		PROVISIONING_PROFILE=

# swift-format lint
fmt-lint:
	swift format lint --strict --parallel --recursive Sora SoraTests

# SwiftLint
lint:
	swift package plugin --allow-writing-to-package-directory swiftlint --fix .
	swift package plugin --allow-writing-to-package-directory swiftlint --strict .

