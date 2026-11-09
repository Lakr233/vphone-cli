#!/bin/zsh
set -euo pipefail

# Reads the method enums of vphoned's guest API from the Swift sources, with
# no guest and no build: --list prints the raw values one file declares,
# --specs and --forces print what the enums declare, and a plain run checks
# that no method name is declared twice and that every method the HTTP route
# table names is declared; --self-test mutates a copy of the sources to prove
# each failing check fires. Checks 6, 8, 10 and 11 compare against methods-catalog.tsv
# beside this script (method, force, params, force action text, result, live; tab separated).
# --results <dir> <catalog> runs only check 11 (result schemas and live classes) on those files.

declare -a files
default_dir="${0:a:h:h}/Daemon"
script="${0:a}"

# Shared patterns, read by awk through ENVIRON (no escape processing) and by grep -E.
export enum_re='^enum [A-Za-z]+Method: String, GuestMethod [{]$'
export case_re='^    case [A-Za-z0-9]+ = "[^"]+"$'

# The raw values of the enums in one file, in declaration order.
raw_values() {
    /usr/bin/awk '
        $0 ~ ENVIRON["enum_re"] { inside = 1; next }
        /^\}/ { inside = 0 }
        inside && $0 ~ ENVIRON["case_re"] { split($0, quoted, "\""); print quoted[2] }
    ' "$1"
}

# "<raw> <force> <params>" for every case of every enum in one file. With a second argument "desc" it prints
# instead "<raw><tab><field><tab><param><tab><text>" for the summary (field summary, param -), every param (field
# param) and the force text of a forced method (field force, param -); newlines in a text become \001. Descriptions
# never contain a double quote, so the scans match "[^"]*"; the result:/force: scans run on a same-length copy of
# the body with every string blanked, so text inside a string never counts.
file_specs() {
    /usr/bin/awk -v file="${1:t}" -v mode="${2:-}" '
        function blank(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
        function row(field, param, text) {
            gsub(/\n/, "\001", text)
            return field "\t" param "\t" text "\n"
        }
        function finish(   i, n, labels, label, force, params, rest, scrub, tmp, text, descs) {
            if (arm == "") return
            n = split(armLabels, labels, " ")
            scrub = ""
            tmp = armBody
            while (match(tmp, /"[^"]*"/)) {
                scrub = scrub substr(tmp, 1, RSTART) blank(RLENGTH - 2) "\""
                tmp = substr(tmp, RSTART + RLENGTH)
            }
            scrub = scrub tmp
            force = "never"
            if (scrub ~ /force: \.always/) force = "always"
            if (scrub ~ /force: \.when/) force = "when"
            params = ""
            descs = ""
            rest = armBody
            if (match(scrub, /(^|[(, ])result:/)) rest = substr(rest, 1, RSTART)
            if (match(rest, /summary: "[^"]*"/)) {
                text = substr(rest, RSTART + 10, RLENGTH - 11)
                descs = descs row("summary", "-", text)
            } else descs = descs row("summary", "-", "")
            while (match(rest, /\.(required|optional)\("[^"]+", \.[a-z]+(, "[^"]*")?/)) {
                token = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                split(token, part, "\"")
                kind = part[3]
                sub(/^, \./, "", kind)
                sub(/,.*$/, "", kind)
                params = params (params == "" ? "" : ",") part[2] ":" kind (token ~ /^\.required/ ? "!" : "")
                descs = descs row("param", part[2], part[4])
            }
            if (force != "never") {
                text = ""
                if (match(armBody, /force: \.always\("[^"]*"/)) {
                    split(substr(armBody, RSTART, RLENGTH), part, "\""); text = part[2]
                } else if (match(armBody, /force: \.when\("[^"]*", "[^"]*"/)) {
                    split(substr(armBody, RSTART, RLENGTH), part, "\""); text = part[4]
                }
                descs = descs row("force", "-", text)
            }
            if (params == "") params = "-"
            for (i = 1; i <= n; i++) { seen[labels[i]] = 1; out[labels[i]] = force " " params; dout[labels[i]] = descs }
            arm = ""
        }
        $0 ~ ENVIRON["enum_re"] { inside = 1; insideSpec = 0; next }
        inside && /^\}/ { finish(); inside = 0; insideSpec = 0
            for (name in raw) {
                if (!(name in seen)) { print "FAIL spec: " file " " name " has no arm" > "/dev/stderr"; bad = 1 }
                else if (mode == "desc") {
                    m = split(dout[name], rows, "\n")
                    for (r = 1; r < m; r++) print raw[name] "\t" rows[r]
                } else print raw[name] " " out[name]
            }
            delete raw; delete seen; delete out; delete dout; next }
        !inside { next }
        $0 ~ ENVIRON["case_re"] { split($0, quoted, "\""); name = $2; raw[name] = quoted[2]; next }
        /^    var spec: MethodSpec \{$/ { insideSpec = 1; next }
        insideSpec && /^        \}$/ { finish(); insideSpec = 0; next }
        insideSpec && /^        case \./ {
            finish()
            line = $0
            sub(/^        case /, "", line)
            colon = index(line, ":")
            labels = substr(line, 1, colon - 1)
            gsub(/[.,]/, " ", labels)
            armLabels = labels
            armBody = substr(line, colon + 1)
            arm = "open"
            next
        }
        insideSpec && arm != "" { armBody = armBody "\n" $0 }
        END { exit bad }
    ' "$1"
}

# "<raw><tab><arm body>" for every spec arm of every case of one file; newlines in a body become spaces.
file_arms() {
    /usr/bin/awk '
        function finish(   i, n, labels) {
            if (arm == "") return
            n = split(armLabels, labels, " ")
            for (i = 1; i <= n; i++) out[labels[i]] = armBody
            arm = ""
        }
        $0 ~ ENVIRON["enum_re"] { inside = 1; insideSpec = 0; next }
        inside && /^\}/ { finish(); inside = 0; insideSpec = 0
            for (name in raw) if (name in out) print raw[name] "\t" out[name]
            delete raw; delete out; next }
        !inside { next }
        $0 ~ ENVIRON["case_re"] { split($0, quoted, "\""); raw[$2] = quoted[2]; next }
        /^    var spec: MethodSpec \{$/ { insideSpec = 1; next }
        insideSpec && /^        \}$/ { finish(); insideSpec = 0; next }
        insideSpec && /^        case \./ {
            finish()
            line = $0
            sub(/^        case /, "", line)
            colon = index(line, ":")
            labels = substr(line, 1, colon - 1)
            gsub(/[.,]/, " ", labels)
            armLabels = labels
            armBody = substr(line, colon + 1)
            arm = "open"
            next
        }
        insideSpec && arm != "" { armBody = armBody " " $0 }
    ' "$1"
}

spec_files() {
    local dir="${1:-$default_dir}"
    files=("$dir"/GuestAPI*.swift(N))
}

# "<raw> <force> <params>" for every method of every enum file, sorted.
all_specs() {
    for file in $files; do file_specs "$file"; done | /usr/bin/sort
}

# "<raw> <force>" for the methods that need force, sorted.
forced_methods() {
    all_specs | /usr/bin/awk '$2 != "never" { print $1, $2 }'
}

# "<raw><tab>missing", "<raw><tab>nonliteral" or "<raw><tab>ok<tab><cell>" for every spec arm on stdin (file_arms
# output). The cell lists the keys of a literal `result: [ ... ]` in declaration order as name:type plus the flags
# ? (optional) ~ (hidden) * (open), "-" for an empty list.
result_cells() {
    /usr/bin/awk -F'\t' '
        {
            raw = $1; body = $2
            if (!match(body, /(^|[(, ])result:/)) { print raw "\tmissing"; next }
            rest = substr(body, RSTART + RLENGTH)
            sub(/^ +/, "", rest)
            closeAt = index(rest, "]")
            if (substr(rest, 1, 1) != "[" || closeAt == 0 || substr(rest, closeAt + 1) !~ /^ *[)]/) { print raw "\tnonliteral"; next }
            inner = substr(rest, 2, closeAt - 2)
            cell = ""; bad = 0
            while (1) {
                sub(/^[ ,]+/, "", inner)
                if (inner == "") break
                if (!match(inner, /^\.(required|optional|hidden)\("[^"]+", \.[a-z]+\)(\.open\(\))?/)) { bad = 1; break }
                token = substr(inner, 1, RLENGTH)
                inner = substr(inner, RLENGTH + 1)
                split(token, part, "\"")
                kind = token; sub(/^\./, "", kind); sub(/\(.*/, "", kind)
                type = part[3]; sub(/^, \./, "", type); sub(/\).*/, "", type)
                flags = (kind == "optional" ? "?" : kind == "hidden" ? "~" : "") (token ~ /[.]open\(\)$/ ? "*" : "")
                cell = cell (cell == "" ? "" : ",") part[2] ":" type flags
            }
            if (bad) print raw "\tnonliteral"
            else print raw "\tok\t" (cell == "" ? "-" : cell)
        }
    '
}

# Check 12: prints one FAIL line per doc ($@) that has a heading or table header row naming results, which would
# restate methods.list, the authority for result shapes.
check_docs() {
    local doc
    for doc in "$@"; do
        if /usr/bin/grep -qiE '^#+ .*result|^[|].*[|] *results? *([|]|$)' "$doc"; then
            print "FAIL docs: $doc restates result shapes (methods.list is the authority)"
        fi
    done
}

# Check 11: prints one FAIL line per finding comparing the result and live columns of catalog $2 with the specs in dir $1.
check_results() {
    spec_files "$1"
    local swift_cells="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/vphone-methods-results.XXXXXX")"
    for file in $files; do file_arms "$file"; done | result_cells > "$swift_cells"
    LC_ALL=C /usr/bin/awk -F'\t' -v swift="$swift_cells" '
        function keyname(token,   name) { name = token; sub(/:.*/, "", name); return name }
        function sortkeys(list, n,   i, j, tmp) {
            for (i = 2; i <= n; i++) {
                tmp = list[i]
                for (j = i - 1; j >= 1 && keyname(list[j]) > keyname(tmp); j--) list[j + 1] = list[j]
                list[j + 1] = tmp
            }
        }
        BEGIN {
            while ((getline line < swift) > 0) { split(line, field, "\t"); status[field[1]] = field[2]; cell[field[1]] = field[3] }
        }
        {
            m = $1; force = $2; params = $3; res = $5; live = $6
            if (live !~ /^(read|mutating|excluded:.+)$/) print "FAIL live: " m " has invalid live value \"" live "\""
            else if (live == "read") {
                if (force != "never") print "FAIL live: " m " is read but has force " force
                if (params ~ /!/) print "FAIL live: " m " is read but has a required param"
            }
            if (!(m in status)) next
            if (status[m] == "missing") { print "FAIL result: " m " result: missing"; next }
            if (status[m] == "nonliteral") { print "FAIL result: " m " result: is not a literal list of ResultKey"; next }
            bad = 0
            n = (cell[m] == "-") ? 0 : split(cell[m], mine, ",")
            delete seen
            for (i = 1; i <= n; i++) {
                k = keyname(mine[i])
                if (k in seen) { print "FAIL result: " m " repeats key " k " in its declaration"; bad = 1 }
                seen[k] = 1
            }
            sortkeys(mine, n)
            canon = ""
            for (i = 1; i <= n; i++) canon = canon (i > 1 ? "," : "") mine[i]
            if (canon == "") canon = "-"
            if (res == "") { print "FAIL result: " m " catalog result cell is empty"; next }
            if (res != "-") {
                t = split(res, theirs, ",")
                delete seen
                for (i = 1; i <= t; i++) {
                    if (theirs[i] !~ /^[A-Za-z_][A-Za-z0-9_]*:(string|integer|number|boolean|array|object|any)[?]?~?[*]?$/) {
                        print "FAIL result: " m " catalog has malformed key \"" theirs[i] "\""; bad = 1; continue
                    }
                    k = keyname(theirs[i])
                    if (k in seen) { print "FAIL result: " m " catalog repeats key " k; bad = 1 }
                    seen[k] = 1
                    if (i > 1 && keyname(theirs[i - 1]) > k) { print "FAIL result: " m " catalog keys are not sorted by name at " k; bad = 1 }
                }
            }
            if (!bad && canon != res) print "FAIL result: " m " differs from the catalog: swift " canon " catalog " res
        }
    ' "$2"
    /bin/rm -f "$swift_cells"
}

# Runs this script on a mutated copy of the daemon sources and asserts it exits
# non-zero and names the offender: $1 label, $2 expected text, $3 file in the copy,
# the rest an awk program that rewrites that file.
mutation_case() {
    local label="$1" expect="$2" target="$3" program="$4" source="$5"
    local copy="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-methods-selftest.XXXXXX")"
    /bin/cp "$source"/*.swift "$copy"
    /usr/bin/awk "$program" "$copy/$target" > "$copy/mutated"
    /bin/mv "$copy/mutated" "$copy/$target"
    local output code=0
    output="$(/bin/zsh "$script" "$copy" 2>&1)" || code=$?
    /bin/rm -rf "$copy"
    if (( code != 0 )) && [[ "$output" == *"$expect"* ]]; then
        print "PASS self-test: $label"
        return 0
    fi
    print "FAIL self-test: $label (exit $code, wanted output containing: $expect)"
    return 1
}

# Check 11 mutations run on a three-method fixture (spec file plus catalog) so they hold whatever the real specs
# declare: $1 label, $2 expected text ("" = must pass), $3 swift|catalog, $4 sed -E program applied to that file.
result_case() {
    local label="$1" expect="$2" target="$3" program="$4"
    local copy="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-results-selftest.XXXXXX")"
    print -r -- 'enum FixtureMethod: String, GuestMethod {
    case alpha = "fix.alpha"
    case beta = "fix.beta"
    case gamma = "fix.gamma"

    var spec: MethodSpec {
        switch self {
        case .alpha: MethodSpec(result: [.required("b", .string), .optional("a", .integer), .hidden("c", .any).open()])
        case .beta: MethodSpec(force: .always, result: [])
        case .gamma: MethodSpec(.required("y", .string), result: [.required("k", .object).open()])
        }
    }
}' > "$copy/GuestAPI+Fixture.swift"
    print -r -- "fix.alpha	never	-	-	a:integer?,b:string,c:any~*	read
fix.beta	always	-	-	-	mutating
fix.gamma	never	y:string!	-	k:object*	excluded:needs params" > "$copy/catalog.tsv"
    local file="$copy/catalog.tsv"
    [[ "$target" == swift ]] && file="$copy/GuestAPI+Fixture.swift"
    /usr/bin/sed -E "$program" "$file" > "$copy/mutated"
    /bin/mv "$copy/mutated" "$file"
    local output code=0
    output="$(/bin/zsh "$script" --results "$copy" "$copy/catalog.tsv" 2>&1)" || code=$?
    /bin/rm -rf "$copy"
    if [[ -z "$expect" ]]; then
        if (( code == 0 )) && [[ -z "$output" ]]; then print "PASS self-test: $label"; return 0; fi
    elif (( code != 0 )) && [[ "$output" == *"$expect"* ]]; then
        print "PASS self-test: $label"; return 0
    fi
    print "FAIL self-test: $label (exit $code, wanted ${expect:-no output}, got: $output)"
    return 1
}

self_test_results() {
    local bad=0
    result_case results-baseline "" catalog 's/x^//' || bad=1
    result_case result-type-change "FAIL result: fix.alpha" swift 's/\.optional\("a", \.integer\)/.optional("a", .string)/' || bad=1
    result_case live-read-forced "FAIL live: fix.beta is read but has force always" catalog '/^fix.beta/s/mutating$/read/' || bad=1
    result_case live-read-required-param "FAIL live: fix.gamma is read but has a required param" catalog 's/excluded:needs params$/read/' || bad=1
    result_case repeated-key-swift "FAIL result: fix.alpha repeats key b" swift 's/\.optional\("a", \.integer\)/.optional("b", .integer)/' || bad=1
    result_case repeated-key-catalog "FAIL result: fix.alpha catalog repeats key b" catalog 's/a:integer\?,b:string/b:integer?,b:string/' || bad=1
    result_case malformed-suffix "FAIL result: fix.alpha catalog has malformed key \"c:any*~\"" catalog 's/c:any~\*/c:any*~/' || bad=1
    result_case malformed-suffix-double "FAIL result: fix.alpha catalog has malformed key \"a:integer??\"" catalog 's/a:integer\?/a:integer??/' || bad=1
    result_case unsorted-catalog "FAIL result: fix.alpha catalog keys are not sorted" catalog 's/a:integer\?,b:string/b:string,a:integer?/' || bad=1
    result_case reordered-swift-keys "" swift 's/result: \[\.required\("b", \.string\), \.optional\("a", \.integer\)/result: [.optional("a", .integer), .required("b", .string)/' || bad=1
    result_case live-capitalised "FAIL live: fix.beta has invalid live value \"Read\"" catalog '/^fix.beta/s/mutating$/Read/' || bad=1
    result_case live-empty-reason "FAIL live: fix.gamma has invalid live value \"excluded:\"" catalog 's/excluded:needs params$/excluded:/' || bad=1
    result_case non-literal-result "FAIL result: fix.gamma result: is not a literal list of ResultKey" swift 's/result: \[\.required\("k", \.object\)\.open\(\)\]/result: Self.shape/' || bad=1
    result_case omitted-result "FAIL result: fix.beta result: missing" swift 's/force: \.always, result: \[\]/force: .always/' || bad=1
    return $bad
}

self_test_docs() {
    local bad=0 tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-docs-selftest.XXXXXX")"
    print -r -- 'Result shapes: see methods.list.' > "$tmp/clean.md"
    print -r -- '## Result shapes' > "$tmp/heading.md"
    print -r -- '| Method | Result |' > "$tmp/table.md"
    local name out
    for name in clean heading table; do
        out="$(check_docs "$tmp/$name.md")"
        if [[ $name == clean && -z "$out" ]] || [[ $name != clean && "$out" == "FAIL docs: $tmp/$name.md"* ]]; then
            print "PASS self-test: docs-$name"
        else print "FAIL self-test: docs-$name (got: $out)"; bad=1; fi
    done
    /bin/rm -rf "$tmp"
    return $bad
}

self_test() {
    local source="${1:-$default_dir}" bad=0
    mutation_case duplicate "FAIL duplicate: time.timezone" GuestAPI+Clock.swift \
        '{ sub(/= "time.clock"/, "= \"time.timezone\"") } 1' "$source" || bad=1
    mutation_case route "FAIL route: time.clock" GuestAPI+Clock.swift \
        '{ sub(/= "time.clock"/, "= \"time.clock2\"") } 1' "$source" || bad=1
    mutation_case legacy "FAIL legacy: GuestMethodSpec.swift:" GuestMethodSpec.swift \
        '{ print } END { print "func legacy() { try requireForce(params, \"x\") }" }' "$source" || bad=1
    mutation_case unregistered "FAIL unregistered: GuestAPI+Extended.swift:" GuestAPI+Extended.swift \
        '!done && /^ *\.make\(/ { sub(/\.make\(/, "GuestMethodArea(entries: { [] }, execute: x) // "); done = 1 } 1' "$source" || bad=1
    mutation_case capability 'FAIL capability: found 0 "methods"' GuestAPI.swift \
        'index($0, "\"methods\",") { next } 1' "$source" || bad=1
    mutation_case force "FAIL force: processes.kill" GuestAPI+Process.swift \
        '/case \.processesKill/ { inKill = 1 } inKill && /force: \.always/ { sub(/force: \.always/, "force: .never"); inKill = 0 } 1' "$source" || bad=1
    mutation_case params "FAIL params: processes.list" GuestAPI+Process.swift \
        '{ sub(/\.optional\("filter", \.string/, ".required(\"filter\", .string") } 1' "$source" || bad=1
    mutation_case undeclared-key "FAIL undeclared-key: GuestAPI+Log.swift process" GuestAPI+Log.swift \
        '{ sub(/\.optional\("process", \.string/, ".optional(\"unrelated\", .string") } 1' "$source" || bad=1
    mutation_case message-text "FAIL message: system.shutdown" GuestAPI+AppDetail.swift \
        '{ sub(/"shut down the guest"/, "\"shut the guest down\"") } 1' "$source" || bad=1
    mutation_case message-validation "FAIL message: services.stop" GuestAPI+Service.swift \
        '/case \.servicesStop:/ { inStop = 1 } inStop && /force: \.always/ { sub(/\{ p in try "stop [^}]*\}/, "{ _ in \"stop it\" }"); inStop = 0 } 1' "$source" || bad=1
    mutation_case empty-summary "FAIL description: time.clock summary is empty" GuestAPI+Clock.swift \
        '/case \.timeClock/ { on = 1 } on && sub(/summary: "[^"]*"/, "summary: \"\"") { on = 0 } 1' "$source" || bad=1
    mutation_case empty-param-description "FAIL description: time.clock.time param is empty" GuestAPI+Clock.swift \
        '{ sub(/\.optional\("time", \.number, "[^"]*"/, ".optional(\"time\", .number, \"\"") } 1' "$source" || bad=1
    mutation_case empty-force-text "FAIL description: processes.kill force is empty" GuestAPI+Process.swift \
        '/case \.processesKill/ { on = 1 } on && sub(/force: \.always\("[^"]*"/, "force: .always(\"\"") { on = 0 } 1' "$source" || bad=1
    mutation_case long-description "FAIL description: time.clock summary is over 120 characters (121)" GuestAPI+Clock.swift \
        'BEGIN { long = sprintf("%121s", ""); gsub(/ /, "x", long) }
         /case \.timeClock/ { on = 1 } on && sub(/summary: "[^"]*"/, "summary: \"" long "\"") { on = 0 } 1' "$source" || bad=1
    mutation_case long-param-description "FAIL description: time.clock.time param is over 120 characters (121)" GuestAPI+Clock.swift \
        'BEGIN { long = sprintf("%121s", ""); gsub(/ /, "x", long) }
         { sub(/\.optional\("time", \.number, "[^"]*"/, ".optional(\"time\", .number, \"" long "\"") } 1' "$source" || bad=1
    mutation_case empty-when-force-text "FAIL description: services.kickstart force is empty" GuestAPI+Service.swift \
        '/case \.servicesKickstart/ { on = 1 } on && sub(/force: \.when\("kill", "[^"]*"/, "force: .when(\"kill\", \"\"") { on = 0 } 1' "$source" || bad=1
    mutation_case newline-description "FAIL description: time.clock summary contains a newline" GuestAPI+Clock.swift \
        '/case \.timeClock/ { on = 1 } on && sub(/summary: "[^"]*"/, "summary: \"a\nb\"") { on = 0 } 1' "$source" || bad=1
    mutation_case newline-param-description "FAIL description: time.clock.time param contains a newline" GuestAPI+Clock.swift \
        '{ sub(/\.optional\("time", \.number, "[^"]*"/, ".optional(\"time\", .number, \"a\\nb\"") } 1' "$source" || bad=1
    mutation_case long-force-text "FAIL description: processes.kill force is over 120 characters (121)" GuestAPI+Process.swift \
        'BEGIN { long = sprintf("%121s", ""); gsub(/ /, "x", long) }
         /case \.processesKill/ { on = 1 } on && sub(/force: \.always\("[^"]*"/, "force: .always(\"" long "\"") { on = 0 } 1' "$source" || bad=1
    mutation_case newline-force-text "FAIL description: processes.kill force contains a newline" GuestAPI+Process.swift \
        '/case \.processesKill/ { on = 1 } on && sub(/force: \.always\("[^"]*"/, "force: .always(\"a\\nb\"") { on = 0 } 1' "$source" || bad=1
    self_test_results || bad=1
    self_test_docs || bad=1
    return $bad
}

case "${1:-}" in
    --self-test)
        self_test "${2:-}"
        exit $?
        ;;
    --results)
        findings="$(check_results "$2" "$3")"
        [[ -z "$findings" ]] || print -r -- "$findings"
        [[ -z "$findings" ]]
        exit $?
        ;;
    --list)
        values="$(raw_values "$2")"
        if [[ -z "$values" ]]; then
            print "FAIL enum: none found in $2"
            exit 1
        fi
        print -r -- "$values"
        exit 0
        ;;
    --specs)
        spec_files "${2:-}"
        all_specs
        exit 0
        ;;
    --forces)
        spec_files "${2:-}"
        forced_methods
        exit 0
        ;;
esac

dir="${1:-$default_dir}"
spec_files "$dir"
failures=0

declare -a names
for file in $files; do
    names+=("${(@f)$(raw_values "$file")}")
done
names=("${(@)names:#}")

if (( ${#names} == 0 )); then
    print "FAIL enum: none found"
    failures=$((failures + 1))
fi

# 1. duplicate
for name in ${(f)"$(print -rl -- $names | /usr/bin/sort | /usr/bin/uniq -d)"}; do
    [[ -n "$name" ]] || continue
    print "FAIL duplicate: $name"
    failures=$((failures + 1))
done

# 2. route
routed="$(/usr/bin/awk '
    /private static func route\(/ { inside = 1; found = 1; next }
    inside && /^ *default:/ { inside = 0 }
    inside {
        rest = $0
        while (match(rest, /"[a-z_0-9]+(\.[a-z_0-9]+)+"/)) {
            name = substr(rest, RSTART + 1, RLENGTH - 2)
            rest = substr(rest, RSTART + RLENGTH)
            print name
        }
    }
' "$dir/GuestHyperTextHandler.swift" 2>/dev/null | /usr/bin/awk '!seen[$0]++' || true)"
if [[ -z "$routed" ]]; then
    print "FAIL route: no route table found"
    failures=$((failures + 1))
else
    for name in ${(f)routed}; do
        if (( ! ${names[(Ie)$name]} )); then
            print "FAIL route: $name"
            failures=$((failures + 1))
        fi
    done
fi

# 3. undeclared-key: a key read from params that the file's specs do not declare
for file in $files; do
    [[ -n "$(raw_values "$file")" ]] || continue
    declared_keys="$(file_specs "$file" | /usr/bin/awk '$3 != "-" { n = split($3, p, ","); for (i = 1; i <= n; i++) { split(p[i], q, ":"); print q[1] } }' || true)"
    for key in ${(f)"$(/usr/bin/env declared_keys="$declared_keys" /usr/bin/awk '
        BEGIN { n = split(ENVIRON["declared_keys"], d, "\n"); for (i = 1; i <= n; i++) have[d[i]] = 1 }
        /params(, "[^"]+"|\["[^"]+"\])/ {
            rest = $0
            while (match(rest, /params(, "[^"]+"|\["[^"]+"\])/)) {
                token = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                split(token, part, "\"")
                read[part[2]] = 1
            }
        }
        END { for (key in read) if (!(key in have)) print key }
    ' "$file" | /usr/bin/sort)"}; do
        print "FAIL undeclared-key: ${file:t} $key"
        failures=$((failures + 1))
    done
done

# 4. legacy: the string-dispatch idioms the enums replaced
for file in "$dir"/*.swift(N); do
    while IFS= read -r finding; do
        [[ -n "$finding" ]] || continue
        print "FAIL legacy: $finding"
        failures=$((failures + 1))
    done < <(/usr/bin/awk -v file="${file:t}" '
        /requireForce\(/ { print file ":" FNR " requireForce(" }
        file !~ /^GuestAPI/ { next }
        pending && /^ *return nil$/ { print file ":" pending " default: return nil" }
        { pending = 0 }
        /func .*[(, ]method: String/ { inside = 1; next }
        inside && $0 == "    }" { inside = 0; next }
        !inside { next }
        /switch method/ { print file ":" FNR " switch method" }
        /method ==/ { print file ":" FNR " method ==" }
        /method !=/ { print file ":" FNR " method !=" }
        /contains\(method\)/ { print file ":" FNR " contains(method)" }
        /^ *default: *return nil *$/ { print file ":" FNR " default: return nil" }
        /^ *default: *$/ { pending = FNR }
    ' "$file")
done

# 5. unregistered: every enum has a .make entry in the area table
makes=0
enums=0
if [[ -f "$dir/GuestAPI+Extended.swift" ]]; then
    makes=$(/usr/bin/grep -c '^ *\.make(' "$dir/GuestAPI+Extended.swift" || true)
    while IFS= read -r finding; do
        [[ -n "$finding" ]] || continue
        print "FAIL unregistered: GuestAPI+Extended.swift:$finding"
        failures=$((failures + 1))
    done < <(/usr/bin/awk '/GuestMethodArea\(entries:/ { print FNR " GuestMethodArea(entries:" }' "$dir/GuestAPI+Extended.swift")
fi
for file in $files; do
    enums=$((enums + $(/usr/bin/grep -Ec "$enum_re" "$file" || true)))
done
if (( makes != enums )); then
    print "FAIL unregistered: $makes .make entries vs $enums enums"
    failures=$((failures + 1))
fi

# 6. force: the methods that need force: true, from the force column of the catalog.
# A missing, unreadable or malformed catalog is a failure of its own; checks 6, 8, 10 and 11 then cannot run.
catalog="${0:a:h}/methods-catalog.tsv"
catalog_ok=1
if [[ ! -r "$catalog" ]] || ! /usr/bin/awk -F'\t' 'NF != 6 { exit 1 } END { exit NR == 0 }' "$catalog"; then
    print "FAIL catalog: $catalog is missing, unreadable or malformed"
    failures=$((failures + 1))
    catalog_ok=0
fi
if (( catalog_ok )); then
    declare -A expected_force found_force
    for line in ${(f)"$(/usr/bin/awk -F'\t' '$2 != "never" { k = $2; sub(/:.*/, "", k); print $1, k }' "$catalog")"}; do
        expected_force[${line% *}]=${line#* }
    done
    for line in ${(f)"$(forced_methods)"}; do found_force[${line% *}]=${line#* }; done
    for raw in ${(ko)found_force}; do
        if [[ "${expected_force[$raw]:-never}" != "${found_force[$raw]}" ]]; then
            print "FAIL force: $raw expected ${expected_force[$raw]:-never} found ${found_force[$raw]}"
            failures=$((failures + 1))
        fi
    done
    for raw in ${(ko)expected_force}; do
        if (( ! ${+found_force[$raw]} )); then
            print "FAIL force: $raw expected ${expected_force[$raw]} found never"
            failures=$((failures + 1))
        fi
    done
fi

# 7. capability: health() lists "methods" exactly once
listed_methods=$(/usr/bin/awk '
    /func health\(/ { inside = 1 }
    inside && index($0, "\"methods\",") { count++ }
    inside && $0 == "    }" { inside = 0 }
    END { print count + 0 }
' "$dir/GuestAPI.swift" 2>/dev/null || print 0)
if [[ "$listed_methods" != 1 ]]; then
    print "FAIL capability: found $listed_methods \"methods\", in health(), expected 1"
    failures=$((failures + 1))
fi

# 8. params: every method's declared params and force kind equal its catalog row.
if (( catalog_ok )); then
    catalog_specs="$(/usr/bin/awk -F'\t' '{ k = $2; sub(/:.*/, "", k); print $1, k, $3 }' "$catalog" | /usr/bin/sort)"
    for offender in ${(f)"$(/usr/bin/diff <(print -r -- "$catalog_specs") <(all_specs) | /usr/bin/awk '/^[<>]/ { print $2 }' | /usr/bin/sort -u)"}; do
        print "FAIL params: $offender differs from the catalog"
        failures=$((failures + 1))
    done
fi

# 10. message: the force action text of every catalog row that has one (column 4, "-" for none) appears in the
# method's spec arm. Text naming `<label>`, `<path>` or `<directory>` must read that param with
# `try GuestAPI.string(p, "k")`, which is what validates a required param before the force error.
if (( catalog_ok )); then
    declare -A arm_body
    for file in $files; do
        for line in ${(f)"$(file_arms "$file")"}; do arm_body[${line%%$'\t'*}]=${line#*$'\t'}; done
    done
    for line in ${(f)"$(/usr/bin/awk -F'\t' '$4 != "-" { print $1 "\t" $4 }' "$catalog")"}; do
        raw=${line%%$'\t'*}
        text=${line#*$'\t'}
        plain=1
        for key in label path directory; do
            if [[ "$text" == *"\`<$key>\`"* ]]; then
                text="try \"${text//\`<$key>\`/\\(GuestAPI.string(p, \"$key\"))}\""
                plain=0
            fi
        done
        (( plain )) && text="\"$text\""
        if [[ "${arm_body[$raw]:-}" != *"$text"* ]]; then
            print "FAIL message: $raw action text is not $text"
            failures=$((failures + 1))
        fi
    done
fi

# 11. results and live: each method's `result:` declaration equals the catalog's result column (keys sorted, name:type
# plus ? ~ * flags, "-" for none) and every row has a valid live class (read only without force or required params).
if (( catalog_ok )); then
    for finding in ${(f)"$(check_results "$dir" "$catalog")"}; do
        print -r -- "$finding"
        failures=$((failures + 1))
    done
fi

# 12. docs: the guest-control references do not restate result shapes
docs_root="${0:a:h:h:h}"
for finding in ${(f)"$(check_docs "$docs_root/Skills/vphone-guest-control/references/rpc-methods.md" "$docs_root/Research/vphoned_http_api.md")"}; do
    print -r -- "$finding"
    failures=$((failures + 1))
done

# 13. description: every method summary, param description and (force != never) force text is non-empty, at most
# 120 characters and one line. Compile time covers a missing description; this covers the rest.
for file in $files; do
    while IFS=$'\t' read -r raw field param text; do
        [[ -n "$raw" ]] || continue
        subject="$raw"
        [[ "$field" == param ]] && subject="$raw.$param"
        reason=""
        if [[ -z "$text" ]]; then reason="is empty"
        elif [[ "$text" == *$'\001'* || "$text" == *'\n'* ]]; then reason="contains a newline"
        elif (( ${#text} > 120 )); then reason="is over 120 characters (${#text})"
        fi
        if [[ -n "$reason" ]]; then
            print "FAIL description: $subject $field $reason (fill it in ${file:t})"
            failures=$((failures + 1))
        fi
    done < <(file_specs "$file" desc)
done

# 9. size: the catalog stays far below the 1 MiB request/response body limit (estimated from the specs)
estimate=$(all_specs | /usr/bin/awk '{
    total += 50 + length($1)
    if ($3 == "-") next
    count = split($3, params, ",")
    for (i = 1; i <= count; i++) { split(params[i], parts, ":"); total += 55 + length(parts[1]) + length(parts[2]) }
} END { print total + 0 }')
if (( estimate > 262144 )); then
    print "FAIL size: catalog estimated at $estimate bytes, limit 262144"
    failures=$((failures + 1))
fi

print "methods: ${#names} names, $failures failures"
(( failures == 0 )) || exit 1
