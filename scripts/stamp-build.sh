#!/usr/bin/env bash
# Xcode build phase: writes the commit count (CFBundleVersion) and short SHA
# (OmniFlowGitSHA, "-dirty" when OmniFlow/ has uncommitted changes) into the
# built app's Info.plist, so installs can be told apart. Runs after Info.plist
# processing and before code signing. Outside a git checkout it leaves the
# defaults (build from project.yml, SHA "dev").
set -euo pipefail
plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
cd "${SRCROOT}/.."
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "stamp-build: no Git commit; keeping defaults"; exit 0; }
build="$(git rev-list --count HEAD)"
sha="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- OmniFlow || echo -dirty)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" "$plist"
/usr/libexec/PlistBuddy -c "Set :OmniFlowGitSHA ${sha}" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :OmniFlowGitSHA string ${sha}" "$plist"
echo "stamp-build: build ${build} · ${sha}"
