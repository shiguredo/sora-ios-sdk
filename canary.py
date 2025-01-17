import argparse
import re
import subprocess

# 更新対象のpodspecファイル
PODSPEC_FILE = "Sora.podspec"

# 更新対象のPackageInfoファイル
PACKAGEINFO_FILE = "Sora/PackageInfo.swift"


def update_sdk_version(podspec_content):
    """
    Sora.podspecファイルの内容からバージョンを更新する

    Args:
        podspec_content (list): podspecファイルの各行を要素とするリスト

    Returns:
        tuple: (更新後のファイル内容のリスト, 新しいバージョン文字列)

    Raises:
        ValueError: バージョン指定が見つからない場合
    """
    updated_content = []
    sdk_version_updated = False
    new_version = None

    for line in podspec_content:
        line = line.rstrip()  # 末尾の改行のみを削除
        if "s.version" in line:
            # バージョン行のパターンマッチング
            # 例: s.version = "1.0.0" や s.version = "1.0.0-canary.1" にマッチ
            version_match = re.match(
                r'\s*s\.version\s*=\s*[\'"](\d+\.\d+\.\d+)(-canary\.(\d+))?[\'"]', line
            )
            if version_match:
                major_minor_patch = version_match.group(1)  # 基本バージョン (例: 1.0.0)
                canary_suffix = version_match.group(2)  # canaryサフィックス部分

                # canaryサフィックスが無い場合は.0から開始、ある場合は番号をインクリメント
                if canary_suffix is None:
                    new_version = f"{major_minor_patch}-canary.0"
                else:
                    canary_number = int(version_match.group(3))
                    new_version = f"{major_minor_patch}-canary.{canary_number + 1}"

                # podspecのバージョン行を更新
                updated_content.append(f'  s.version = "{new_version}"')
                sdk_version_updated = True
            else:
                updated_content.append(line)
        else:
            updated_content.append(line)

    if not sdk_version_updated:
        raise ValueError("Version specification not found in Sora.podspec file.")

    return updated_content, new_version


def update_packageinfo_version(packageinfo_content):
    """
    PackageInfo.swiftファイルの内容からバージョンを更新する

    Args:
        packageinfo_content (list): PackageInfo.swiftファイルの各行を要素とするリスト

    Returns:
        tuple: (更新後のファイル内容のリスト, 新しいバージョン文字列)

    Raises:
        ValueError: バージョン指定が見つからない場合
    """
    updated_content = []
    sdk_version_updated = False
    new_version = None

    for line in packageinfo_content:
        line = line.rstrip()  # 末尾の改行のみを削除
        if "public static let version" in line:
            # バージョン行のパターンマッチング
            version_match = re.match(
                r'\s*public\s+static\s+let\s+version\s*=\s*[\'"](\d+\.\d+\.\d+)(-canary\.(\d+))?[\'"]',
                line,
            )
            if version_match:
                major_minor_patch = version_match.group(1)  # 基本バージョン (例: 1.0.0)
                canary_suffix = version_match.group(2)  # canaryサフィックス部分

                # canaryサフィックスが無い場合は.0から開始、ある場合は番号をインクリメント
                if canary_suffix is None:
                    new_version = f"{major_minor_patch}-canary.0"
                else:
                    canary_number = int(version_match.group(3))
                    new_version = f"{major_minor_patch}-canary.{canary_number + 1}"

                # PackageInfoのバージョン行を更新
                updated_content.append(
                    f'    public static let version = "{new_version}"'
                )
                sdk_version_updated = True
            else:
                updated_content.append(line)
        else:
            updated_content.append(line)

    if not sdk_version_updated:
        raise ValueError("Version specification not found in PackageInfo.swift file.")

    return updated_content, new_version


def write_file(filename, updated_content, dry_run):
    """
    更新後の内容をファイルに書き込む

    Args:
        filename (str): 書き込み対象のファイル名
        updated_content (list): 更新後のファイル内容
        dry_run (bool): True の場合は実際の書き込みを行わない
    """
    if dry_run:
        print(f"Dry run: The following changes would be written to {filename}:")
        print("\n".join(updated_content))
    else:
        with open(filename, "w") as file:
            file.write("\n".join(updated_content) + "\n")
        print(f"{filename} updated.")


def git_operations(new_version, dry_run):
    """
    Git操作（コミット、タグ付け、プッシュ）を実行

    Args:
        new_version (str): 新しいバージョン文字列（タグとして使用）
        dry_run (bool): True の場合は実際のGit操作を行わない
    """
    commit_message = (
        f"[canary] Update Sora.podspec and PackageInfo.swift version to {new_version}"
    )

    if dry_run:
        # dry-run時は実行されるコマンドを表示のみ
        print(f"Dry run: Would execute git add {PODSPEC_FILE} {PACKAGEINFO_FILE}")
        print(f"Dry run: Would execute git commit -m '{commit_message}'")
        print(f"Dry run: Would execute git tag {new_version}")
        print(f"Dry run: Would execute git push origin develop")
        print(f"Dry run: Would execute git push origin {new_version}")
    else:
        # ファイルをステージング
        print(f"Executing: git add {PODSPEC_FILE} {PACKAGEINFO_FILE}")
        subprocess.run(["git", "add", PODSPEC_FILE, PACKAGEINFO_FILE], check=True)

        # 変更をコミット
        print(f"Executing: git commit -m '{commit_message}'")
        subprocess.run(["git", "commit", "-m", commit_message], check=True)

        # バージョンタグを作成
        print(f"Executing: git tag {new_version}")
        subprocess.run(["git", "tag", new_version], check=True)

        # developブランチをプッシュ
        print("Executing: git push origin develop")
        subprocess.run(["git", "push", "origin", "develop"], check=True)

        # タグをプッシュ
        print(f"Executing: git push origin {new_version}")
        subprocess.run(["git", "push", "origin", new_version], check=True)


def main():
    """
    メイン処理:
    1. コマンドライン引数の解析
    2. Sora.podspec ファイルの読み込みと更新
    3. PackageInfo.swiftファイルの読み込みと更新
    4. Git操作の実行
    """
    parser = argparse.ArgumentParser(
        description="Update Sora.podspec & PackageInfo.swift version and push changes with git."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Perform a dry run without making any changes.",
    )
    args = parser.parse_args()

    # podspecファイルを読み込んでバージョンを更新
    with open(PODSPEC_FILE, "r") as file:
        podspec_content = file.readlines()
    updated_podspec_content, new_version = update_sdk_version(podspec_content)
    write_file(PODSPEC_FILE, updated_podspec_content, args.dry_run)

    # PackageInfoファイルを読み込んでバージョンを更新
    with open(PACKAGEINFO_FILE, "r") as file:
        packageinfo_content = file.readlines()
    updated_packageinfo_content, _ = update_packageinfo_version(packageinfo_content)
    write_file(PACKAGEINFO_FILE, updated_packageinfo_content, args.dry_run)

    # Git操作の実行
    git_operations(new_version, args.dry_run)


if __name__ == "__main__":
    main()
