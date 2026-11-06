#!/bin/sh
# Mock HTTP only; JSON construction and OpenSSL signing run normally.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cp tests/mock-curl.sh "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$root/.test-tools:$PATH"
export PATH
TEST_LOG="$tmp/calls"
export TEST_LOG
for TEST_CASE in create update unchanged duplicate denied; do
    export TEST_CASE
    : > "$TEST_LOG"
    status=0
    sh ddns.sh --domain example.com --sub home --id test-id --secret test-secret --ip 1.2.3.4 > "$tmp/out" 2>&1 || status=$?
    case "$TEST_CASE" in
        create) [ "$status" = 0 ]; grep -q CreateRecord "$TEST_LOG";;
        update) [ "$status" = 0 ]; grep -q ModifyRecord "$TEST_LOG";;
        unchanged) [ "$status" = 0 ]; [ "$(wc -l < "$TEST_LOG" | tr -d ' ')" = 1 ];;
        duplicate|denied) [ "$status" != 0 ]; [ "$(wc -l < "$TEST_LOG" | tr -d ' ')" = 1 ];;
    esac
    echo "PASS $TEST_CASE"
done
sh -n ddns.sh
echo 'PASS shell syntax'
