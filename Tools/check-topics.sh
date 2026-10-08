#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
check_dir="${GYRUS_CHECK_OUTPUT:-/tmp/GyrusTopicChecks}"
mkdir -p "$check_dir"
source_files=("${(@f)$(rg --files Sources -g '*.swift' -g '!GyrusApp.swift')}")
xcrun swiftc -O -parse-as-library "${source_files[@]}" Tests/TopicChecks.swift -o "$check_dir/topic-checks"
"$check_dir/topic-checks"
