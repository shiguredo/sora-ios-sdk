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

