#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="${RUNNER_TEMP:-${repo_root}/.build}/node24-openclaw"
donor_root="${work_root}/mobile-donor"
source_root="${work_root}/node24-target"
dist_root="${repo_root}/dist/node24-openclaw-ios-bundle"
base_tag="v24.5.0"
target_tag="v24.15.0"
mobile_repository="Acurast/nodejs-mobile"
mobile_commit="b856357fb95b2af800e8613e242a70cdcb935743"
diff_paths=(
  .
  ':(exclude).github/**'
  ':(exclude)benchmark/**'
  ':(exclude)doc/**'
  ':(exclude)doc_mobile/**'
  ':(exclude)test/**'
  ':(exclude)tools/mobile-test/**'
  ':(exclude)tools/node_modules/**'
  ':(exclude)tools/android_build.sh'
  ':(exclude)android_configure.py'
  ':(exclude)deps/cares/config/android/**'
  ':(exclude)deps/cjs-module-lexer/**'
  ':(exclude)deps/npm/**'
  ':(exclude)deps/undici/src/package-lock.json'
  ':(exclude)deps/uv/src/unix/linux-core.c'
  ':(exclude)deps/nghttp2/lib/Makefile.msvc'
  ':(exclude)deps/nghttp2/lib/version.rc.in'
  ':(exclude)deps/zlib/contrib/minizip/ChangeLogUnzip'
  ':(exclude)deps/zlib/zlib.map'
  ':(exclude)tools/test.py'
  ':(exclude,glob)**/xcuserdata/**'
  ':(exclude,glob)**/*.bat'
  ':(exclude,glob)**/*.cmd'
  ':(exclude,glob)**/*.eml'
  ':(exclude)README.md'
  ':(exclude)CHANGELOG*.md'
  ':(exclude)LICENSE'
)
expected_rejects=(
  "deps/ngtcp2/ngtcp2.gyp.rej"
  "deps/uvwasi/src/uvwasi.c.rej"
  "node.gyp.rej"
  "node.gypi.rej"
  "tools/gyp/pylib/gyp/generator/make.py.rej"
  "tools/gyp/pylib/gyp/generator/ninja.py.rej"
  "tools/gyp/pylib/gyp/xcode_emulation.py.rej"
)

rm -rf "${work_root}" "${repo_root}/dist"
mkdir -p "${work_root}" "${dist_root}/Frameworks"

echo "Preparing the pinned Node 24.5 iOS donor patch..."
git clone --filter=blob:none --no-checkout \
  "https://github.com/${mobile_repository}.git" "${donor_root}"
git -C "${donor_root}" checkout --detach "${mobile_commit}"
git -C "${donor_root}" remote add upstream https://github.com/nodejs/node.git
git -C "${donor_root}" fetch --depth 1 upstream \
  "refs/tags/${base_tag}:refs/tags/upstream-${base_tag}"

echo "Cloning OpenClaw's minimum supported Node 24 release..."
git clone --filter=blob:none --depth 1 --branch "${target_tag}" \
  https://github.com/nodejs/node.git "${source_root}"
target_commit="$(git -C "${source_root}" rev-parse HEAD)"

patch_file="${work_root}/node24-ios.patch"
git -C "${donor_root}" diff --binary \
  "refs/tags/upstream-${base_tag}^{tree}" "${mobile_commit}^{tree}" \
  -- "${diff_paths[@]}" > "${patch_file}"

set +e
git -C "${source_root}" apply --reject --whitespace=nowarn "${patch_file}"
apply_exit=$?
set -e
if [[ "${apply_exit}" -eq 0 ]]; then
  echo "Expected the audited seven-file conflict set, but the patch applied cleanly." >&2
  exit 1
fi

actual_rejects=()
while IFS= read -r reject_path; do
  actual_rejects+=("${reject_path}")
done < <(
  find "${source_root}" -name '*.rej' -print |
    sed "s#^${source_root}/##" |
    sort
)
if [[ "${actual_rejects[*]}" != "${expected_rejects[*]}" ]]; then
  printf 'Unexpected reject set:\n%s\n' "${actual_rejects[@]}" >&2
  exit 1
fi

echo "Reconciling the four arm64 iOS-relevant conflicts..."
"${PYTHON:-python3}" - "${source_root}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace_once(relative, old, new):
    path = root / relative
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"{relative}: expected exactly one audited match")
    path.write_text(text.replace(old, new, 1))


def replace_exact_count(relative, old, new, expected):
    path = root / relative
    text = path.read_text()
    if text.count(old) != expected:
        raise SystemExit(
            f"{relative}: expected {expected} audited matches for {old!r}"
        )
    path.write_text(text.replace(old, new))


replace_once(
    "node.gyp",
    """        [ 'node_shared=="true"', {
          'sources': [
            'src/node_snapshot_stub.cc',
          ]
        }],
        [ 'node_shared_gtest=="false"', {""",
    """        [ 'node_shared=="true"', {
          'sources': [
            'src/node_snapshot_stub.cc',
          ]
        }],
        [ 'node_target_type=="static_library" and OS=="ios"', {
          'sources': [
            'src/node_snapshot_stub.cc',
          ]
        }],
        [ 'node_shared_gtest=="false"', {""",
)

replace_once(
    "node.gyp",
    """      'sources': [ '<@(node_cctest_sources)' ],

      'conditions': [
        [ 'node_shared_gtest=="false"', {""",
    """      'sources': [ '<@(node_cctest_sources)' ],

      'conditions': [
        [ 'not (node_target_type=="static_library" and OS=="ios")', {
          'sources': [
            'src/node_snapshot_stub.cc',
          ]
        }],
        [ 'node_shared_gtest=="false"', {""",
)

replace_once(
    "node.gypi",
    """    [ 'node_use_sqlite=="true"', {
      'defines': [ 'HAVE_SQLITE=1' ],
    }, {
      'defines': [ 'HAVE_SQLITE=0' ]
    }],
  ],
}""",
    """    [ 'node_use_sqlite=="true"', {
      'defines': [ 'HAVE_SQLITE=1' ],
    }, {
      'defines': [ 'HAVE_SQLITE=0' ]
    }],
    [ 'OS=="android" or OS=="ios"', {
      'defines': [
        'NODE_MOBILE',
      ],
    }],
  ],
}""",
)

replace_once(
    "tools/gyp/pylib/gyp/generator/make.py",
    'self.flavor not in ("mac", "openbsd", "netbsd", "win")',
    'self.flavor not in ("mac", "ios", "openbsd", "netbsd", "win")',
)

replace_once(
    "tools/gyp/pylib/gyp/generator/ninja.py",
    """    def WriteLink(self, spec, config_name, config, link_deps, compile_deps):
        \"\"\"Write out a link step. Fills out target.binary.\"\"\"
        if self.flavor != "mac" or len(self.archs) == 1:""",
    """    def WriteLink(self, spec, config_name, config, link_deps, compile_deps):
        \"\"\"Write out a link step. Fills out target.binary.\"\"\"
        if self.flavor not in ("mac", "ios") or len(self.archs) == 1:""",
)

# NodeMobile disables Intl, but current OpenClaw requires Unicode property
# regular expressions. Full ICU avoids fragile JavaScript rewrites and keeps
# security-sensitive normalization behavior intact.
replace_exact_count(
    "tools/ios_framework_prepare.sh",
    "--with-intl=none",
    "--with-intl=full-icu",
    3,
)
replace_once(
    "tools/ios_framework_prepare.sh",
    """    --without-node-code-cache \\
    --without-node-snapshot
  make -j$(getconf _NPROCESSORS_ONLN)

  # Move compilation outputs""",
    """    --without-node-code-cache \\
    --without-node-snapshot
  make -j$(getconf _NPROCESSORS_ONLN)
  echo "Built target ICU archives:"
  ls -lh $LIBRARY_PATH/libicu*.a

  # Move compilation outputs""",
)

# Node 24.15 split the CommonJS lexer implementation into libmerve.a. The
# NodeMobile wrapper also predates the ICU archives because it disabled Intl.
# Copy all providers into the framework and keep them after their consumers in
# the static link order.
replace_once(
    "tools/ios_framework_prepare.sh",
    '  "libnode.a"\n  "libopenssl.a"',
    '  "libnode.a"\n'
    '  "libmerve.a"\n'
    '  "libicui18n.a"\n'
    '  "libicuucx.a"\n'
    '  "libicudata.a"\n'
    '  "libopenssl.a"',
)

project = "tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj"
replace_once(
    project,
    "\t\tA36728F42E53580A004DF2FB /* libnode.a in Frameworks */ = {isa = PBXBuildFile; fileRef = 3376C91D1EC3922F0007AD59 /* libnode.a */; };\n",
    "\t\tA36728F42E53580A004DF2FB /* libnode.a in Frameworks */ = {isa = PBXBuildFile; fileRef = 3376C91D1EC3922F0007AD59 /* libnode.a */; };\n"
    "\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000002 /* libmerve.a */; };\n",
)
replace_once(
    project,
    "\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000002 /* libmerve.a */; };\n",
    "\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000002 /* libmerve.a */; };\n"
    "\t\tC0DEC0DE0000000000000003 /* libicui18n.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000004 /* libicui18n.a */; };\n"
    "\t\tC0DEC0DE0000000000000005 /* libicuucx.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000006 /* libicuucx.a */; };\n"
    "\t\tC0DEC0DE0000000000000007 /* libicudata.a in Frameworks */ = {isa = PBXBuildFile; fileRef = C0DEC0DE0000000000000008 /* libicudata.a */; };\n",
)
replace_once(
    project,
    "\t\t3376C91D1EC3922F0007AD59 /* libnode.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libnode.a; path = bin/libnode.a; sourceTree = \"<group>\"; };\n",
    "\t\t3376C91D1EC3922F0007AD59 /* libnode.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libnode.a; path = bin/libnode.a; sourceTree = \"<group>\"; };\n"
    "\t\tC0DEC0DE0000000000000002 /* libmerve.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libmerve.a; path = bin/libmerve.a; sourceTree = \"<group>\"; };\n",
)
replace_once(
    project,
    "\t\tC0DEC0DE0000000000000002 /* libmerve.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libmerve.a; path = bin/libmerve.a; sourceTree = \"<group>\"; };\n",
    "\t\tC0DEC0DE0000000000000002 /* libmerve.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libmerve.a; path = bin/libmerve.a; sourceTree = \"<group>\"; };\n"
    "\t\tC0DEC0DE0000000000000004 /* libicui18n.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libicui18n.a; path = bin/libicui18n.a; sourceTree = \"<group>\"; };\n"
    "\t\tC0DEC0DE0000000000000006 /* libicuucx.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libicuucx.a; path = bin/libicuucx.a; sourceTree = \"<group>\"; };\n"
    "\t\tC0DEC0DE0000000000000008 /* libicudata.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; name = libicudata.a; path = bin/libicudata.a; sourceTree = \"<group>\"; };\n",
)
replace_once(
    project,
    "\t\t\t\tA36728F42E53580A004DF2FB /* libnode.a in Frameworks */,\n",
    "\t\t\t\tA36728F42E53580A004DF2FB /* libnode.a in Frameworks */,\n"
    "\t\t\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */,\n",
)
replace_once(
    project,
    "\t\t\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */,\n",
    "\t\t\t\tC0DEC0DE0000000000000001 /* libmerve.a in Frameworks */,\n"
    "\t\t\t\tC0DEC0DE0000000000000003 /* libicui18n.a in Frameworks */,\n"
    "\t\t\t\tC0DEC0DE0000000000000005 /* libicuucx.a in Frameworks */,\n"
    "\t\t\t\tC0DEC0DE0000000000000007 /* libicudata.a in Frameworks */,\n",
)
replace_once(
    project,
    "\t\t\t\t3376C91D1EC3922F0007AD59 /* libnode.a */,\n",
    "\t\t\t\t3376C91D1EC3922F0007AD59 /* libnode.a */,\n"
    "\t\t\t\tC0DEC0DE0000000000000002 /* libmerve.a */,\n",
)
replace_once(
    project,
    "\t\t\t\tC0DEC0DE0000000000000002 /* libmerve.a */,\n",
    "\t\t\t\tC0DEC0DE0000000000000002 /* libmerve.a */,\n"
    "\t\t\t\tC0DEC0DE0000000000000004 /* libicui18n.a */,\n"
    "\t\t\t\tC0DEC0DE0000000000000006 /* libicuucx.a */,\n"
    "\t\t\t\tC0DEC0DE0000000000000008 /* libicudata.a */,\n",
)
PY

find "${source_root}" -name '*.rej' -delete

# Prefer Python 3.12, whose environment has the setuptools compatibility shim.
"${PYTHON:-python3}" - "${source_root}/configure" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
python_313 = 'command -v python3.13 >/dev/null && exec python3.13 "$0" "$@"'
python_312 = 'command -v python3.12 >/dev/null && exec python3.12 "$0" "$@"'
expected = f"{python_313}\n{python_312}"
if expected not in text:
    raise SystemExit("configure Python probe order no longer matches the audited source")
path.write_text(text.replace(expected, f"{python_312}\n{python_313}", 1))
PY

echo "Selected toolchain:"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
clang --version | head -n 1
"${PYTHON:-python3}" --version

echo "Building Node 24.15 arm64 for an iOS device..."
(
  cd "${source_root}"
  ./tools/ios_framework_prepare.sh arm64
)

framework_parent="${source_root}/out_ios_arm64/iphoneos-arm64/Release-iphoneos"
framework="${framework_parent}/NodeMobile.framework"
test -f "${framework}/NodeMobile"
test -f "${framework}/Headers/NodeMobile.h"
cp -R "${framework}" "${dist_root}/Frameworks/"

xcrun --sdk iphoneos clang++ \
  -std=c++20 \
  -arch arm64 \
  -miphoneos-version-min=15.0 \
  -F "${framework_parent}" \
  -Wl,-rpath,@executable_path/Frameworks \
  "${repo_root}/cli/node_main.cc" \
  -framework NodeMobile \
  -o "${dist_root}/node-ios"

codesign --force --sign - --timestamp=none \
  "${dist_root}/Frameworks/NodeMobile.framework"
codesign --force --sign - --timestamp=none "${dist_root}/node-ios"
"${repo_root}/scripts/inspect-artifact.sh" "${dist_root}"

{
  echo
  echo "Node.js target tag: ${target_tag}"
  echo "Node.js target commit: ${target_commit}"
  echo "iOS donor commit: ${mobile_commit}"
  echo "Intl mode: full-icu"
  echo "OpenClaw engine compatibility: >=24.15.0 <25"
} >> "${dist_root}/BUILD-REPORT.txt"

cp "${repo_root}/README.md" "${dist_root}/EXPERIMENT.md"
tar -C "${repo_root}/dist" -czf \
  "${repo_root}/dist/node24-openclaw-ios-arm64.tar.gz" \
  node24-openclaw-ios-bundle

echo "OpenClaw-compatible Node bundle created."
