#!/bin/zsh
set -euo pipefail

# Compiles vphone-mcp's sources, except main.swift, with MCPTests.swift, and runs
# the unit tests. Then runs the built binary (build/mcp, from the build
# command in AGENTS.md) over its command line and checks the build and docs facts.
# Exits non-zero on the first failed check.
mcp="${0:a:h:h}"
root="${mcp:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

fail() {
    print -u2 -- "FAIL: $1"
    exit 1
}

sources=()
for source in "$mcp"/VPhoneMCPCLI/*.swift; do
    [[ "${source:t}" == "main.swift" ]] || sources+=("$source")
done

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "${sources[@]}" \
    "$mcp/Tests/MCPTests.swift" \
    -o "$temporary/mcp-tests"
"$temporary/mcp-tests" "$@"

binary="$root/build/mcp/Build/Products/Debug/vphone-mcp"
[[ -x "$binary" ]] || fail "$binary is missing; run the build command in AGENTS.md first"
usage="usage: vphone-mcp [--profile full|standard|readonly] [--tools a,b,c]"
: > "$temporary/in"
export VPHONE_LIBRARY_ROOT="$temporary/empty"
print -r -- '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' > "$temporary/list"
print -r -- '{"jsonrpc":"2.0","id":1,"method":"ping"}' > "$temporary/ping"

# Usage errors: exit 2, empty stdout, and exactly the two usage lines on stderr.
expect_usage() {
    local label="$1" problem="$2"
    shift 2
    local code=0
    "$binary" "$@" <"$temporary/in" >"$temporary/out" 2>"$temporary/err" || code=$?
    [[ $code == 2 ]] || fail "$label: exit $code, want 2"
    [[ ! -s "$temporary/out" ]] || fail "$label: stdout is not empty"
    printf 'vphone-mcp: %s\n%s\n' "$problem" "$usage" > "$temporary/want"
    cmp -s "$temporary/want" "$temporary/err" || fail "$label: stderr is $(<"$temporary/err")"
}

expect_usage "unknown flag" "unknown option --vmm" --vmm x
expect_usage "--vm is not an option" "unknown option --vm" --vm a
expect_usage "--socket is not an option" "unknown option --socket" --socket /tmp/a.sock
expect_usage "--help" "unknown option --help" --help
expect_usage "-h" "unknown option -h" -h
expect_usage "--tools twice" "--tools given twice" --tools methods --tools methods
expect_usage "--tools without value" "--tools needs a value" --tools
expect_usage "empty --tools" "--tools entry is empty" --tools ""
expect_usage "--tools with an empty entry" "--tools entry is empty" --tools a,,b
expect_usage "--tools repeated entry" "--tools entry methods is repeated" --tools methods,methods
expect_usage "--tools unknown entry" "--tools entry bogus is not one of the tool names" --tools bogus
expect_usage "--profile twice" "--profile given twice" --profile full --profile readonly
expect_usage "--profile without value" "--profile needs a value" --profile
expect_usage "--profile unknown" "--profile admin is not one of full, standard, readonly" --profile admin
expect_usage "--profile takes the next element" "--profile --tools is not one of full, standard, readonly" --profile --tools methods
expect_usage "--tools takes the next element" "--tools entry --profile is not one of the tool names" --tools --profile readonly

# A valid tools/list succeeds with the six host tools and the 13 area tools of the embedded catalog, with no VM.
code=0
"$binary" <"$temporary/list" >"$temporary/out" 2>"$temporary/err" || code=$?
[[ $code == 0 ]] || fail "tools/list: exit $code, want 0"
jq -e '.result.tools | length == 19' "$temporary/out" > /dev/null || fail "tools/list does not list the 19 tools"

# --tools limits tools/list to the named tools, in toolNames order.
code=0
"$binary" --tools methods,screenshot <"$temporary/list" >"$temporary/out" 2>"$temporary/err" || code=$?
[[ $code == 0 ]] || fail "--tools methods,screenshot: exit $code, want 0"
jq -e '[.result.tools[].name] == ["screenshot", "methods"]' "$temporary/out" > /dev/null \
    || fail "--tools methods,screenshot does not list screenshot,methods"

# No flag at all is valid, and --profile narrows the host tools.
code=0
"$binary" <"$temporary/list" >"$temporary/out" 2>"$temporary/err" || code=$?
[[ $code == 0 ]] || fail "no flags: exit $code, want 0"
code=0
"$binary" --profile readonly <"$temporary/list" >"$temporary/out" 2>"$temporary/err" || code=$?
[[ $code == 0 ]] || fail "--profile readonly: exit $code, want 0"
jq -e '[.result.tools[].name] | .[0:2] == ["screenshot", "methods"] and (index("shell") == null) and (index("ui") != null)' "$temporary/out" > /dev/null \
    || fail "--profile readonly does not list the read tools only"

# Exit 1: a failed stdout write. Redirections are ordered so that
# the input and error files open before fd 1 is closed.
code=0
"$binary" <"$temporary/ping" 2>"$temporary/err" >&- || code=$?
[[ $code == 1 ]] || fail "closed stdout: exit $code, want 1"
printf 'vphone-mcp: stdout write failed: Bad file descriptor\n' > "$temporary/want"
cmp -s "$temporary/want" "$temporary/err" || fail "closed stdout: stderr is $(<"$temporary/err")"

# Exit 1: a failed stdin read, with empty stdout. The output file
# opens before fd 0 is closed.
code=0
"$binary" >"$temporary/out" 2>"$temporary/err" <&- || code=$?
[[ $code == 1 ]] || fail "closed stdin: exit $code, want 1"
[[ ! -s "$temporary/out" ]] || fail "closed stdin: stdout is not empty"
printf 'vphone-mcp: stdin read failed: Bad file descriptor\n' > "$temporary/want"
cmp -s "$temporary/want" "$temporary/err" || fail "closed stdin: stderr is $(<"$temporary/err")"

# The binary links only system libraries.
libraries=("${(@f)$(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')}")
(( ${#libraries} > 0 )) || fail "otool lists no libraries"
for library in "${libraries[@]}"; do
    [[ "$library" == /usr/lib/* || "$library" == /System/* ]] || fail "$library is not a system library"
done

# The workspace lists the project, and the target builds with the
# deployment target and product name.
grep -q 'VPhoneMCP/VPhoneMCP.xcodeproj' "$root/VPhone.xcworkspace/contents.xcworkspacedata" \
    || fail "the workspace does not list VPhoneMCP"
settings="$(/usr/bin/xcodebuild -workspace "$root/VPhone.xcworkspace" -scheme VPhoneMCP -configuration Debug -showBuildSettings 2>/dev/null)"
[[ "$settings" == *"MACOSX_DEPLOYMENT_TARGET = 15.0"* ]] || fail "MACOSX_DEPLOYMENT_TARGET is not 15.0"
[[ "$settings" == *"PRODUCT_NAME = vphone-mcp"* ]] || fail "PRODUCT_NAME is not vphone-mcp"

# Each doc gives the build command and two mcp.json examples, one
# with --tools. Every example must be valid JSON.
for doc in AGENTS.md Skills/vphone-guest-control/SKILL.md Documents/en/machines/automation-api.md; do
    file="$root/$doc"
    [[ $(grep -c 'vphone-mcp' "$file") -ge 1 ]] || fail "$doc does not mention vphone-mcp"
    [[ $(grep -c 'xcodebuild -workspace VPhone.xcworkspace -scheme VPhoneMCP' "$file") -ge 1 ]] \
        || fail "$doc lacks the build command"
    configs=("${(@f)$(grep '^{"mcpServers"' "$file")}")
    (( ${#configs} == 3 )) || fail "$doc has ${#configs} mcp.json examples, want 3"
    tools=0
    profiles=0
    for config in "${configs[@]}"; do
        print -r -- "$config" | jq -e . > /dev/null || fail "$doc has an invalid mcp.json example"
        [[ "$config" == *'"--tools"'* ]] && tools=$((tools + 1))
        [[ "$config" == *'"--profile"'* ]] && profiles=$((profiles + 1))
    done
    (( tools == 1 )) || fail "$doc: $tools mcp.json examples have --tools, want 1"
    (( profiles == 1 )) || fail "$doc: $profiles mcp.json examples have --profile, want 1"

    # The example with neither flag sits beside the warning.
    unrestricted="$(grep -A4 '^{"mcpServers".*"args":\[\]' "$file" || true)"
    grep -Eq '^Warning: .*push.*pull.*rpc.*shell.*--tools.*--profile.*denies' <<< "$unrestricted" \
        || fail "$doc: no warning beside the unrestricted mcp.json example"
done

# The live script needs a VM, so only its syntax is checked here.
zsh -n "$root/VPhoneMCP/Tests/run-mcp-live.zsh" || fail "run-mcp-live.zsh has a syntax error"

print "CLI, build and docs checks passed"
