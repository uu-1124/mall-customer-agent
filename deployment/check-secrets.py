"""Reject common credential and private-data leaks in Git-tracked files.

Run from the repository root: python deployment/check-secrets.py
This is a targeted release check, not a substitute for reviewing the staged tree.
"""

from __future__ import annotations

import ipaddress
import re
import runpy
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 2 * 1024 * 1024
TEXT_SUFFIXES = {
    ".md", ".py", ".json", ".yaml", ".yml", ".cjs", ".mjs", ".js", ".ts",
    ".vue", ".sh", ".ps1", ".sql", ".conf", ".env", ".example", ".txt", ".html",
    ".toml", ".ini", ".xml", ".dockerfile", ".pdm", ".pdb",
}
PUBLIC_ENV_FILES = {
    f"{project}/{name}"
    for project in ("mall-app-web", "mall-admin-web")
    for name in (".env", ".env.development", ".env.production")
}
PRIVATE_PATHS = re.compile(
    r"^(?:deployment/(?:offline/|\.run/|_incoming/|config/|evidence/|jars/|web/|"
    r"demo/backups/|(?:\.dev-ssh|secrets|build-manifest)\.json$|demo/demo\.env$|"
    r"init/02-demo-accounts\.sql$)|mall-agent/\.venv/)|(?:^|/)\.qoder/"
)
PRIVATE_SUFFIXES = (".pem", ".key", ".pfx", ".p12", ".tar", ".tgz", ".gz", ".dump", ".sqlite", ".sqlite3", ".log")
PUBLIC_SEEDS = {"deployment/init/01-mall.sql", "mall-swarm/document/sql/mall.sql"}
PUBLIC_SEED_INSERT = re.compile(r"^\s*(?:INSERT|REPLACE)(?:\s+IGNORE)?\s+INTO\s+`?([a-z_]+)\b", re.I | re.M)
PUBLIC_SEED_PERSONAL = (
    re.compile(r"[\w.+%-]+@[a-z0-9.-]+\.[a-z]{2,}", re.I),
    re.compile(r"(?<![\w./-])1[3-9]\d{9}(?![\w./-])"),
)
DEMO_SECRET_LITERAL = re.compile(
    r"(?:\bdemoPassword\s*:\s*|[\"']password[\"']\s*:\s*|"
    r"(?:os\.)?environ\.get\(\s*[\"']MALL_DEMO_(?:ADMIN_|MEMBER_)?PASSWORD[\"']\s*,\s*)"
    r"[\"'][^\"'\r\n]+[\"']"
)
BCRYPT_LITERAL = re.compile(r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}")
PATTERNS = [
    ("private-key", re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("openai-style-key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("url-credentials", re.compile(r"https?://[^\s/@:]+:[^\s/@]+@")),
    ("windows-user-path", re.compile(r"\b[A-Z]:[\\/]+Users[\\/]+[^\\/\s'\"<>;]+", re.I)),
]
# Known provider-specific host patterns are not permitted in example data.
_PROVIDER = bytes.fromhex("66757368656e6779756e7375616e").decode()
FORBIDDEN_HOSTS = re.compile(
    rf"[A-Za-z0-9.-]*(?:{_PROVIDER}|ws-[a-z0-9]{{10,}}\.cn-beijing\.maas)[A-Za-z0-9.-]*"
)
SELF = "deployment/check-secrets.py"
SKIP_PATH = re.compile(r"(^|/)(node_modules|tinymce[^/]*)/|/public/tinymce|\.min\.(?:js|css)$")
# Public upstream demo address and public DNS example addresses.
PUBLIC_IP_EXAMPLES = {"39.98.190.128", "1.1.1.1", "8.8.8.8"}


def tracked_files(root: Path) -> list[str]:
    result = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
    return [p for p in result.stdout.decode("utf-8").split("\0") if p]


def is_private_path(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    is_private_env = (
        (name == ".env" or name.startswith(".env."))
        and not name.endswith((".example", ".sample"))
        and path not in PUBLIC_ENV_FILES
    )
    return is_private_env or bool(PRIVATE_PATHS.search(path)) or path.endswith(PRIVATE_SUFFIXES)


def is_candidate(path: str) -> bool:
    return not SKIP_PATH.search(path) and (
        path in PUBLIC_ENV_FILES or Path(path).suffix in TEXT_SUFFIXES
    )


def public_ip(token: str) -> bool:
    try:
        addr = ipaddress.ip_address(token)
    except ValueError:
        return False
    return not (addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_reserved or addr.is_multicast)


def scan(path: str, root: Path, allowed_seed_tables: set[str]) -> list[str]:
    if is_private_path(path):
        return [f"{path}: local-only-file"]
    if path == SELF or not is_candidate(path):
        return []
    try:
        with (root / path).open("rb") as handle:
            raw = handle.read(MAX_BYTES + 1)
    except OSError:
        return [f"{path}: unreadable-file"]
    if len(raw) > MAX_BYTES or b"\0" in raw[:4096]:
        return []
    text = raw.decode("utf-8", "replace")
    findings: list[str] = []

    def report(offset: int, category: str) -> None:
        line = text.count("\n", 0, offset) + 1
        findings.append(f"{path}:{line}: {category}")

    for label, pattern in PATTERNS:
        for match in pattern.finditer(text):
            report(match.start(), label)
    for match in FORBIDDEN_HOSTS.finditer(text):
        report(match.start(), "provider-host")
    for match in re.finditer(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", text):
        ip = match.group()
        if public_ip(ip) and ip not in PUBLIC_IP_EXAMPLES:
            report(match.start(), "public-ip")
    if path.startswith("mall-agent/scripts/") or path == "deployment/prepare.cjs":
        for match in DEMO_SECRET_LITERAL.finditer(text):
            report(match.start(), "hardcoded-development-password")
    if path in PUBLIC_SEEDS:
        for match in PUBLIC_SEED_INSERT.finditer(text):
            if match[1].lower() not in allowed_seed_tables:
                report(match.start(), "non-allowlisted-seed-data")
        for pattern in PUBLIC_SEED_PERSONAL:
            for match in pattern.finditer(text):
                report(match.start(), "personal-data-shape-in-catalog-seed")
    if path in PUBLIC_SEEDS or path == "deployment/prepare.cjs":
        for match in BCRYPT_LITERAL.finditer(text):
            report(match.start(), "password-hash")
    return findings


def main() -> int:
    seed = runpy.run_path(str(ROOT / "deployment/demo/build-seed.py"))
    hits = [hit for path in tracked_files(ROOT) for hit in scan(path, ROOT, seed["PUBLIC_SOURCE_TABLES"])]
    if hits:
        print("Potential private data found in tracked files (values not printed):")
        for hit in hits:
            print(f"  {hit}")
        return 1
    print("No known credential, private-path or private-seed patterns found in tracked files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
