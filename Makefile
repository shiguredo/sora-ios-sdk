.PHONY: fmt fmt-lint lint

# すべてを実行
all: fmt fmt-lint lint

# swift-format
fmt:
	swift format --in-place --recursive Sora SoraTests

# swift-format lint
fmt-lint:
	swift format lint --strict --parallel --recursive Sora SoraTests

# SwiftLint
lint:
	swift package plugin --allow-writing-to-package-directory swiftlint --fix .
	swift package plugin --allow-writing-to-package-directory swiftlint --strict .

# Swift Package を xcodebuild でビルドする
.PHONY: xcodebuild
xcodebuild:
	xcodebuild \
		-scheme Sora \
		-sdk iphoneos18.4 \
		-configuration Release \
		-derivedDataPath build \
		-disableAutomaticPackageResolution \
		clean build \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		PROVISIONING_PROFILE=

.PHONY: webrtc
webrtc:
	xcodebuild \
		-scheme Sora-Package \
		-sdk iphoneos18.4 \
		-configuration Release \
		-derivedDataPath build \
		-disableAutomaticPackageResolution \
		clean build \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		PROVISIONING_PROFILE=

# Swift Package を xcodebuild でビルドする
.PHONY: test
test:
	xcodebuild \
		-scheme Sora \
		-sdk iphonesimulator \
		-configuration Release \
		-derivedDataPath build \
		-disableAutomaticPackageResolution \
		clean build \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		PROVISIONING_PROFILE=


.PHONY: build
build:
	swift build -Xswiftc "-sdk" -Xswiftc "`xcrun --sdk iphonesimulator --show-sdk-path`" -Xswiftc "-target" -Xswiftc "arm64-apple-ios18.4-simulator"

#xcodebuild \
#	-scheme 'Sora' \
#	-sdk iphoneos18.2 \
#	-configuration Release \
#	-derivedDataPath build \
#	clean build \
#	CODE_SIGNING_REQUIRED=NO \
#	CODE_SIGN_IDENTITY= \
#	PROVISIONING_PROFILE=
#		-destination 'generic/platform=iOS' \
