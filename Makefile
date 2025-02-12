.PHONY: fmt fmt-lint lint

# フォーマット (swift-format)
fmt:
	swift format --in-place --recursive Sora SoraTests

# swift-format lint
fmt-lint:
	swift format lint --strict --parallel --recursive Sora SoraTests

# Lint (SwiftLint)
lint:
	swift package plugin --allow-writing-to-package-directory swiftlint --fix .
	swift package plugin --allow-writing-to-package-directory swiftlint --strict .

# すべてを実行
all: fmt-lint fmt lint
