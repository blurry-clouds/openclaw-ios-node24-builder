#!/usr/bin/env bash
set -euo pipefail

bundle="${1:?usage: inspect-artifact.sh BUNDLE_DIRECTORY}"
launcher="${bundle}/node-ios"
framework="${bundle}/Frameworks/NodeMobile.framework/NodeMobile"
report="${bundle}/BUILD-REPORT.txt"

test -f "${launcher}"
test -f "${framework}"

launcher_file="$(file "${launcher}")"
framework_file="$(file "${framework}")"
launcher_build="$(xcrun vtool -show-build "${launcher}")"
framework_build="$(xcrun vtool -show-build "${framework}")"
launcher_dependencies="$(otool -L "${launcher}")"
framework_dependencies="$(otool -L "${framework}")"
launcher_load_commands="$(otool -l "${launcher}")"
entry_point="$(nm -gU "${framework}" | grep -E '(_node_start|node_start)$')"

grep -Eq 'Mach-O 64-bit.*arm64' <<<"${launcher_file}"
grep -Eq 'Mach-O 64-bit.*arm64' <<<"${framework_file}"
grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<<"${launcher_build}"
grep -Eq 'platform[[:space:]]+IOS([[:space:]]|$)' <<<"${framework_build}"
grep -Fq '@rpath/NodeMobile.framework/NodeMobile' <<<"${launcher_dependencies}"
grep -A2 'cmd LC_RPATH' <<<"${launcher_load_commands}" |
  grep -Fq '@executable_path/Frameworks'
codesign --verify --strict "${launcher}"
codesign --verify --strict "${bundle}/Frameworks/NodeMobile.framework"

assert_supported_minos() {
  local label="$1"
  local build_output="$2"
  local minos
  minos="$(awk '$1 == "minos" { print $2; exit }' <<<"${build_output}")"
  if [[ -z "${minos}" ]]; then
    echo "${label}: missing iOS minimum version" >&2
    return 1
  fi
  awk -v value="${minos}" 'BEGIN {
    split(value, actual, ".");
    split("15.8.8", limit, ".");
    for (i = 1; i <= 3; i++) {
      a = actual[i] + 0;
      b = limit[i] + 0;
      if (a < b) exit 0;
      if (a > b) exit 1;
    }
    exit 0;
  }' || {
    echo "${label}: minimum iOS ${minos} exceeds device iOS 15.8.8" >&2
    return 1
  }
}

assert_supported_minos "launcher" "${launcher_build}"
assert_supported_minos "framework" "${framework_build}"

{
  echo "OpenClaw iOS Runtime Lab - baseline artifact report"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
  echo
  echo "== Launcher file =="
  echo "${launcher_file}"
  echo
  echo "== Framework file =="
  echo "${framework_file}"
  echo
  echo "== Launcher build version =="
  echo "${launcher_build}"
  echo
  echo "== Framework build version =="
  echo "${framework_build}"
  echo
  echo "== Launcher dependencies =="
  echo "${launcher_dependencies}"
  echo
  echo "== Framework dependencies =="
  echo "${framework_dependencies}"
  echo
  echo "== Launcher runtime paths =="
  grep -A2 'cmd LC_RPATH' <<<"${launcher_load_commands}"
  echo
  echo "== Required entry point =="
  echo "${entry_point}"
  echo
  echo "== Code signatures =="
  codesign -dvv "${launcher}" 2>&1
  codesign -dvv "${bundle}/Frameworks/NodeMobile.framework" 2>&1
  echo
  echo "== SHA-256 =="
  shasum -a 256 "${launcher}" "${framework}"
} | tee "${report}"
