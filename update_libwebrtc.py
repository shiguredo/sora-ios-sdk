"""
update-libwebrtc.md に従って Sora iOS SDK の libwebrtc バージョンを更新するスクリプト

このスクリプトが行うこと:
- 指定された libwebrtc バージョンの WebRTC.xcframework.zip をダウンロードする
- SHA-256 のチェックサムを計算する
- アーティファクトから build_info.json を読む
- Package.swift、Sora/PackageInfo.swift、CHANGES.md、README.md を更新する
- `--dry-run` を付けるとファイルを書き換えずに予定の処理と diff を表示する。
"""

import argparse
import difflib
import hashlib
import json
import pathlib
import re
import sys
import tempfile
import urllib.request
import zipfile
from typing import Dict, Tuple

ROOT = pathlib.Path(__file__).parent
PACKAGE_SWIFT = ROOT / "Package.swift"
PACKAGE_INFO = ROOT / "Sora" / "PackageInfo.swift"
CHANGES_MD = ROOT / "CHANGES.md"
README_MD = ROOT / "README.md"
WEBRTC_ZIP_NAME = "WebRTC.xcframework.zip"
BUILD_INFO_PATH = "WebRTC.xcframework/build_info.json"
DOWNLOAD_URL = (
    "https://github.com/shiguredo-webrtc-build/webrtc-build/releases/download/"
    "{version}/WebRTC.xcframework.zip"
)


class UpdateError(Exception):
    """Custom exception for update failures."""


def parse_version(version: str) -> Tuple[str, str, str, str]:
    """
    m143.7499.2.1 のような libwebrtc バージョンを要素に分解する。

    Returns:
        tuple: (major, branch, commit_position, maintenance_version)
    """
    match = re.fullmatch(r"m(\d+)\.(\d+)\.(\d+)\.(\d+)", version.strip())
    if not match:
        raise UpdateError(
            "libwebrtc version must look like m143.7499.1.0 (m.<branch>.<commit>.<maint>)"
        )
    return match.group(1), match.group(2), match.group(3), match.group(4)


def download_artifact(version: str, dry_run: bool) -> pathlib.Path:
    """指定バージョンの WebRTC.xcframework.zip をダウンロードする。"""
    url = DOWNLOAD_URL.format(version=version)
    destination = pathlib.Path(tempfile.mkstemp(prefix="webrtc_", suffix=".zip")[1])

    prefix = "[dry-run] " if dry_run else ""
    print(f"{prefix}Downloading {url}")
    with urllib.request.urlopen(url) as response, open(destination, "wb") as fp:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            fp.write(chunk)
    print(f"{prefix}Saved artifact to {destination}")
    return destination


def resolve_artifact(
    version: str, dry_run: bool, expected: Tuple[str, str, str]
) -> pathlib.Path:
    """
    手元に WebRTC.xcframework.zip があればそれを使い、なければダウンロードする。

    アーティファクトがある場合はオフラインでも --dry-run を使えるようにするため。
    """
    local_artifact = ROOT / WEBRTC_ZIP_NAME
    if local_artifact.exists():
        prefix = "[dry-run] " if dry_run else ""
        expected_major, expected_commit, expected_maint = expected
        if artifact_matches_version(local_artifact, expected_major, expected_commit, expected_maint):
            print(f"{prefix}Using existing artifact at {local_artifact}")
            return local_artifact
        print(
            f"{prefix}Local {local_artifact} does not match requested version; downloading correct artifact."
        )
    return download_artifact(version, dry_run)


def compute_sha256(file_path: pathlib.Path) -> str:
    """ファイルの SHA-256 チェックサムを計算する。"""
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1024 * 1024), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def load_build_info(zip_path: pathlib.Path) -> Dict[str, str]:
    """アーティファクト内の build_info.json を展開せずに読み取る。"""
    with zipfile.ZipFile(zip_path) as zf:
        if BUILD_INFO_PATH not in zf.namelist():
            raise UpdateError(f"{BUILD_INFO_PATH} not found in {zip_path}")
        with zf.open(BUILD_INFO_PATH) as build_info_fp:
            return json.load(build_info_fp)


def artifact_matches_version(
    zip_path: pathlib.Path, expected_major: str, expected_commit: str, expected_maint: str
) -> bool:
    """build_info.json の内容が指定バージョンと一致するかを確認する。"""
    build_info = load_build_info(zip_path)
    expected_branch = f"M{expected_major}"
    branch_ok = str(build_info.get("branch")) == expected_branch
    commit_ok = str(build_info.get("commit")) == str(expected_commit)
    maint_ok = str(build_info.get("maint")) == str(expected_maint)
    return branch_ok and commit_ok and maint_ok


def read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def write_or_preview(path: pathlib.Path, new_content: str, dry_run: bool) -> None:
    """dry-run なら差分を表示し、通常時は内容を書き込む。"""
    current = read_text(path)
    if current == new_content:
        print(f"No changes for {path}")
        return

    diff = "\n".join(
        difflib.unified_diff(
            current.splitlines(), new_content.splitlines(), fromfile=str(path), tofile=str(path)
        )
    )

    if dry_run:
        print(f"[dry-run] Diff for {path}:")
        print(diff)
    else:
        path.write_text(new_content + ("\n" if not new_content.endswith("\n") else ""), encoding="utf-8")
        print(f"Updated {path}")


def update_package_swift(version: str, checksum: str) -> str:
    """Package.swift の libwebrtcVersion と checksum を更新する。"""
    content = read_text(PACKAGE_SWIFT)
    updated = content

    version_pattern = r'(let\s+libwebrtcVersion\s*=\s*")[^"]+(")'
    replacement_version = rf"\g<1>{version}\g<2>"
    updated, version_subs = re.subn(
        version_pattern, replacement_version, updated, count=1, flags=re.MULTILINE
    )
    if version_subs == 0:
        raise UpdateError("Failed to update libwebrtcVersion in Package.swift")

    checksum_pattern = r'(checksum:\s*")[^"]+(")'
    replacement_checksum = rf"\g<1>{checksum}\g<2>"
    updated, checksum_subs = re.subn(
        checksum_pattern, replacement_checksum, updated, count=1, flags=re.MULTILINE
    )
    if checksum_subs == 0:
        raise UpdateError("Failed to update checksum in Package.swift")

    return updated


def update_package_info(
    build_info: Dict[str, str], branch_number: str, current_content: str
) -> str:
    """Sora/PackageInfo.swift の WebRTCInfo の各値を更新する。"""
    updated = current_content

    def replace_field(field: str, value: str, text: str) -> Tuple[str, int]:
        pattern = re.compile(
            rf"(public enum WebRTCInfo\s*{{[\s\S]*?public\s+static\s+let\s+{field}\s*=\s*\")"
            r'([^"\n]+)(")',
            flags=re.MULTILINE,
        )
        replacement = rf"\g<1>{value}\g<3>"
        return pattern.subn(replacement, text, count=1)

    replacements = [
        ("version", str(build_info["branch"])),
        ("branch", str(branch_number)),
        ("commitPosition", str(build_info["commit"])),
        ("maintenanceVersion", str(build_info["maint"])),
        ("revision", str(build_info["revision"])),
    ]

    for field, value in replacements:
        updated, count = replace_field(field, value, updated)
        if count == 0:
            raise UpdateError(f"Failed to update PackageInfo.swift for field: {field}")

    return updated


def update_changes_md(version: str, author: str, current_content: str) -> str:
    """develop セクションの libwebrtc の項目を更新または追加する。"""
    lines = current_content.splitlines()
    entry_pattern = re.compile(r"- \[UPDATE\] libwebrtc [mM]\d+\.\d+\.\d+\.\d+ に上げる")
    author_line_pattern = re.compile(r"(\s*- @)(.+)")

    for idx, line in enumerate(lines):
        if entry_pattern.fullmatch(line):
            lines[idx] = f"- [UPDATE] libwebrtc {version} に上げる"
            if not author:
                return "\n".join(lines)

            author_line_idx = idx + 1
            if author_line_idx < len(lines) and author_line_pattern.fullmatch(lines[author_line_idx]):
                prefix, authors_str = author_line_pattern.fullmatch(lines[author_line_idx]).groups()
                authors = authors_str.split()
                normalized_author = author.lstrip("@")
                target = f"@{normalized_author}"
                normalized_existing = [a.lstrip("@") for a in authors]

                if normalized_author in normalized_existing:
                    for i, existing in enumerate(authors):
                        if existing.lstrip("@") == normalized_author and existing != target:
                            authors[i] = target
                            break
                else:
                    authors.append(target)

                lines[author_line_idx] = f"{prefix}{' '.join(authors)}"
            else:
                normalized_author = author.lstrip("@")
                lines.insert(author_line_idx, f"  - @{normalized_author}")
            return "\n".join(lines)

    try:
        develop_idx = next(i for i, line in enumerate(lines) if line.strip() == "## develop")
    except StopIteration:
        raise UpdateError("## develop section not found in CHANGES.md")

    # 挿入前にヘッダー直後が空行 1 行になるように整える。
    insert_idx = develop_idx + 1
    if insert_idx >= len(lines) or lines[insert_idx].strip() != "":
        lines.insert(insert_idx, "")
    insert_idx += 1

    new_entry = [f"- [UPDATE] libwebrtc {version} に上げる", f"  - @{author or 'your-github-id'}"]
    lines[insert_idx:insert_idx] = new_entry
    return "\n".join(lines)


def update_readme(version_major: str, branch_number: str, current_content: str) -> str:
    """README のバッジとリンクにある libwebrtc 情報を更新する。"""
    badge_pattern = (
        r"(libwebrtc-)\d+\.\d+(-blue\.svg\)\]\(https://chromium\.googlesource\.com/"
        r"external/webrtc/\+/branch-heads/)\d+(\))"
    )
    replacement = rf"\g<1>{version_major}.{branch_number}\g<2>{branch_number}\g<3>"

    updated, count = re.subn(badge_pattern, replacement, current_content, count=1)
    if count == 0:
        raise UpdateError("Failed to update libwebrtc badge in README.md")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update libwebrtc version across Sora iOS SDK files."
    )
    parser.add_argument("version", help='libwebrtc version like "m143.7499.1.0"')
    parser.add_argument(
        "--author",
        help="GitHub ID to record in CHANGES.md when adding a new entry",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned actions and diffs without writing files",
    )

    args = parser.parse_args()

    try:
        major, branch_number, commit_position, maintenance_version = parse_version(args.version)
    except UpdateError as exc:
        print(exc, file=sys.stderr)
        return 1

    artifact_path = resolve_artifact(
        args.version, args.dry_run, (major, commit_position, maintenance_version)
    )

    if not artifact_path.exists():
        print(f"Artifact {artifact_path} is required but missing", file=sys.stderr)
        return 1

    try:
        checksum = compute_sha256(artifact_path)
        build_info = load_build_info(artifact_path)
    except Exception as exc:
        print(f"Failed to read artifact: {exc}", file=sys.stderr)
        return 1

    if not artifact_matches_version(
        artifact_path, major, commit_position, maintenance_version
    ):
        print(
            f"Artifact at {artifact_path} does not match requested version {args.version}.",
            file=sys.stderr,
        )
        return 1

    try:
        package_swift_updated = update_package_swift(args.version, checksum)
        package_info_updated = update_package_info(
            build_info, branch_number, read_text(PACKAGE_INFO)
        )
        changes_md_updated = update_changes_md(args.version, args.author or "", read_text(CHANGES_MD))
        readme_updated = update_readme(major, branch_number, read_text(README_MD))
    except UpdateError as exc:
        print(exc, file=sys.stderr)
        return 1

    write_or_preview(PACKAGE_SWIFT, package_swift_updated, args.dry_run)
    write_or_preview(PACKAGE_INFO, package_info_updated, args.dry_run)
    write_or_preview(CHANGES_MD, changes_md_updated, args.dry_run)
    write_or_preview(README_MD, readme_updated, args.dry_run)

    if args.dry_run:
        print("Dry run complete. No files were modified.")
    else:
        print("libwebrtc update completed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
