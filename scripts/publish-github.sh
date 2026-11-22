#!/bin/bash
# Založí veřejný repozitář github.com/<účet>/mac-canon-scanner a nahraje do něj tento projekt.
#
#   ./scripts/publish-github.sh            # účet micfold, repozitář mac-canon-scanner
#   ./scripts/publish-github.sh jinyucet jinynazev
#
# Potřebuje GitHub CLI (brew install gh). Bezpečné spustit opakovaně:
# když repozitář už existuje, jen do něj nahraje změny.
set -euo pipefail

OWNER="${1:-micfold}"
REPO="${2:-mac-canon-scanner}"
DESCRIPTION="Batch document scanning for macOS over the network (eSCL/AirScan) – built for Canon i-SENSYS/imageCLASS & PIXMA, no Canon drivers needed"
TOPICS="macos swiftui scanner escl airscan airprint canon document-scanning ocr pdf"

# Ze složky projektu, nebo ze složky, kde skript leží (scripts/).
if [ ! -f Package.swift ]; then cd "$(dirname "$0")/.."; fi
say() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f Package.swift ] && [ -d Sources/Skener ] || die "Spusťte skript ze složky projektu Skener."

# 1) GitHub CLI
if ! command -v gh >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        say "Instaluji GitHub CLI (brew install gh)…"
        brew install gh
    else
        die "Chybí GitHub CLI. Nainstalujte ho: https://cli.github.com (nebo 'brew install gh')."
    fi
fi

# 2) Přihlášení – k nahrání .github/workflows je potřeba oprávnění „workflow“
if ! gh auth status -h github.com >/dev/null 2>&1; then
    say "Přihlášení ke GitHubu (otevře se prohlížeč)…"
    gh auth login -h github.com -p https -w -s repo,workflow
elif ! gh auth status -h github.com 2>&1 | grep -q "workflow"; then
    say "Přidávám oprávnění 'workflow' (kvůli automatickému sestavení)…"
    gh auth refresh -h github.com -s workflow
fi
gh auth setup-git -h github.com >/dev/null

LOGIN="$(gh api user --jq .login)"
if [ "${LOGIN}" != "${OWNER}" ]; then
    die "Jste přihlášen jako '${LOGIN}', ale repozitář má patřit '${OWNER}'. Přihlaste se správným účtem: gh auth login"
fi

# 3) Git repozitář a commit
if [ ! -d .git ]; then
    say "Zakládám git repozitář…"
    git init -q -b main
fi
if [ -z "$(git config user.email || true)" ]; then
    ID="$(gh api user --jq .id)"
    git config user.name "${LOGIN}"
    git config user.email "${ID}+${LOGIN}@users.noreply.github.com"
fi
git add -A
if ! git rev-parse --verify -q HEAD >/dev/null; then
    git commit -q -m "Skener: batch scanning for Canon (eSCL/AirScan) printers on macOS"
elif ! git diff --cached --quiet; then
    git commit -q -m "Update"
fi
git branch -M main

# 4) Repozitář na GitHubu
if gh repo view "${OWNER}/${REPO}" >/dev/null 2>&1; then
    say "Repozitář ${OWNER}/${REPO} už existuje – jen nahraji změny."
else
    say "Zakládám veřejný repozitář ${OWNER}/${REPO}…"
    gh repo create "${OWNER}/${REPO}" --public --description "${DESCRIPTION}" --disable-wiki
fi

URL="https://github.com/${OWNER}/${REPO}.git"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "${URL}"
else
    git remote add origin "${URL}"
fi

say "Nahrávám kód…"
git push -u origin main

# 5) Štítky (topics), ať projekt lidé najdou
say "Nastavuji štítky…"
args=()
for t in ${TOPICS}; do args+=(--add-topic "$t"); done
gh repo edit "${OWNER}/${REPO}" "${args[@]}" >/dev/null || true

say "Hotovo!"
echo "  Repozitář:            https://github.com/${OWNER}/${REPO}"
echo "  Automatické sestavení: https://github.com/${OWNER}/${REPO}/actions"
echo ""
echo "Za pár minut bude v Actions ke stažení hotová aplikace (Skener.zip)."
gh repo view "${OWNER}/${REPO}" --web >/dev/null 2>&1 || true
