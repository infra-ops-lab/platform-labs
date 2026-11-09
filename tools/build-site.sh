#!/bin/bash
# Build the website from the lab READMEs: ./tools/build-site.sh  (add "serve" for a live preview)
# Needs: pip install -r tools/requirements-docs.txt
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf _site-src && mkdir _site-src
# every lab file (Markdown, YAML, scripts, Go) goes in, so links to files work on the site too
rsync -a --exclude '.git' --exclude '.github' --exclude '_site-src' --exclude 'site' \
      --exclude 'tools' --exclude 'mkdocs.yml' --exclude '.gitignore' ./ _site-src/
if [ "${1:-}" = serve ]; then mkdocs serve; else mkdocs build; fi
