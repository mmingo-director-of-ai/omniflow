#!/usr/bin/env python3
"""Build the pinned, vendored MIT Atlas SDK consumer without a private checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path)
parser.add_argument("--test", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = root / "OmniFlow/Helpers/Atlas"
lock = json.loads((source / "atlas-sdk.lock.json").read_text())
sdk_source = root / "Vendor/AtlasSDK"
manifest = json.loads((root / "Vendor/atlas-sdk-manifest.json").read_text())
revision = lock["revision"]
go = shutil.which("go") or "/opt/homebrew/bin/go"
env = dict(os.environ, GOCACHE=os.environ.get("GOCACHE", str(root / ".build/go-cache")), GOTOOLCHAIN="local", GOPROXY="off", GOSUMDB="off", GOWORK="off", CGO_ENABLED="0")

def run(command, **kwargs):
    return subprocess.run(command, check=True, env=env, **kwargs)

if manifest["revision"] != lock["revision"] or manifest["sdkTree"] != lock["sdkTree"]:
    raise SystemExit("Vendored Atlas manifest does not match the SDK lock")
actual_files = {str(path.relative_to(sdk_source)) for path in sdk_source.rglob("*") if path.is_file()}
if actual_files != set(manifest["files"]):
    raise SystemExit("Vendored Atlas SDK file set differs from its manifest")
for relative, expected in manifest["files"].items():
    if hashlib.sha256((sdk_source / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit("Vendored Atlas SDK integrity mismatch: " + relative)
if lock["moduleVersion"] not in (source / "go.mod").read_text():
    raise SystemExit("Atlas module version does not match the lock")

output = args.output or Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"] / "Helpers/NotchLeeAtlas"
output.parent.mkdir(parents=True, exist_ok=True)
(root / ".build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="atlas-", dir=root / ".build") as temporary:
    build = Path(temporary)
    sdk = build / "sdk"
    shutil.copytree(sdk_source, sdk)
    modfile = build / "bridge.mod"
    shutil.copyfile(source / "go.mod", modfile)
    module = "gitlab.quandrylabs.ai/quandry-labs/atomic-atlas/sdk/go"
    run([go, "mod", "edit", "-modfile=" + str(modfile), "-replace=" + module + "=" + str(sdk)], cwd=source)
    flags = "-s -w -X main.sdkVersion=" + lock["version"] + " -X main.sdkRevision=" + revision
    if args.test:
        run([go, "vet", "-mod=readonly", "-modfile=" + str(modfile), "./..."], cwd=source)
        run([go, "test", "-mod=readonly", "-modfile=" + str(modfile), "-count=1", "./..."], cwd=source)
    arches = os.environ.get("ARCHS", platform.machine()).split()
    products = []
    for arch in arches:
        env["GOARCH"] = {"arm64": "arm64", "x86_64": "amd64"}[arch]
        env["GOOS"] = "darwin"
        product = build / ("NotchLeeAtlas-" + arch)
        run([go, "build", "-mod=readonly", "-modfile=" + str(modfile), "-trimpath", "-buildvcs=false", "-ldflags=" + flags, "-o", str(product), "."], cwd=source)
        products.append(product)
    if len(products) == 1:
        shutil.copyfile(products[0], output)
    else:
        run(["lipo", "-create", *map(str, products), "-output", str(output)])
    output.chmod(0o755)

identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
if os.environ.get("CODE_SIGNING_ALLOWED") == "YES" and identity:
    command = ["codesign", "--force", "--options", "runtime", "--sign", identity]
    if os.environ.get("TARGET_NAME") == "OmniFlowAppStore":
        command += ["--entitlements", str(source / "AtlasAppStore.entitlements")]
    run(command + [str(output)])
print("Built NotchLeeAtlas with Atlas " + lock["version"] + " (" + revision[:12] + ")")
