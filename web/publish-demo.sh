#!/usr/bin/env bash
# Build the demo and push it to the gh-pages branch (GitHub Pages).
set -euo pipefail
cd "$(dirname "$0")"

npx vite build demo --base=/mictext/ --outDir ../dist-demo --emptyOutDir

cd ..
WT=$(mktemp -d)
trap 'git worktree remove --force "$WT" 2>/dev/null || true' EXIT
git worktree add "$WT" gh-pages 2>/dev/null || git worktree add -b gh-pages "$WT"
# another machine may have deployed since this clone's gh-pages last moved
git -C "$WT" pull --rebase origin gh-pages 2>/dev/null || true
find "$WT" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
cp -r web/dist-demo/. "$WT"/
touch "$WT/.nojekyll"
git -C "$WT" add -A
git -C "$WT" commit -m "Deploy demo" --allow-empty
git -C "$WT" push origin gh-pages
echo "Deployed. Page: https://dieterstemmet.github.io/mictext/"
