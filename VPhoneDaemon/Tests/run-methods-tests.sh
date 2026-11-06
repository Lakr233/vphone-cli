#!/bin/zsh
set -euo pipefail

# Reads the method enums of vphoned's guest API from the Swift sources, with
# no guest and no build: --list prints the raw values one file declares,
# --specs and --forces print what the enums declare, and a plain run checks
# that no method name is declared twice and that every method the HTTP route
# table names is declared; --self-test mutates a copy of the sources to prove
# each failing check fires. Checks 6, 8 and 10 compare against methods-catalog.tsv
# beside this script (method, force, params, force action text; tab separated).

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

# "<raw> <force> <params>" for every case of every enum in one file.
file_specs() {
    /usr/bin/awk -v file="${1:t}" '
        function finish(   i, n, labels, label, force, params, rest) {
            if (arm == "") return
            n = split(armLabels, labels, " ")
            force = "never"
            if (armBody ~ /force: \.always/) force = "always"
            if (armBody ~ /force: \.when/) force = "when"
            params = ""
            rest = armBody
            while (match(rest, /\.(required|optional)\("[^"]+", \.[a-z]+\)/)) {
                token = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                split(token, part, "\"")
                kind = part[3]
                sub(/^, \./, "", kind)
                sub(/\)$/, "", kind)
                params = params (params == "" ? "" : ",") part[2] ":" kind (token ~ /^\.required/ ? "!" : "")
            }
            if (params == "") params = "-"
            for (i = 1; i <= n; i++) { seen[labels[i]] = 1; out[labels[i]] = force " " params }
            arm = ""
        }
        $0 ~ ENVIRON["enum_re"] { inside = 1; insideSpec = 0; next }
        inside && /^\}/ { finish(); inside = 0; insideSpec = 0
            for (name in raw) {
                if (!(name in seen)) { print "FAIL spec: " file " " name " has no arm" > "/dev/stderr"; bad = 1 }
                else print raw[name] " " out[name]
            }
            delete raw; delete seen; delete out; next }
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
        '{ sub(/\.optional\("filter", \.string\)/, ".required(\"filter\", .string)") } 1' "$source" || bad=1
    mutation_case undeclared-key "FAIL undeclared-key: GuestAPI+Log.swift process" GuestAPI+Log.swift \
        '{ sub(/\.optional\("process", \.string\)/, ".optional(\"unrelated\", .string)") } 1' "$source" || bad=1
    mutation_case message-text "FAIL message: system.shutdown" GuestAPI+AppDetail.swift \
        '{ sub(/"shut down the guest"/, "\"shut the guest down\"") } 1' "$source" || bad=1
    mutation_case message-validation "FAIL message: services.stop" GuestAPI+Service.swift \
        '/case \.servicesStop:/ { inStop = 1 } inStop && /force: \.always/ { sub(/\{ p in try "stop [^}]*\}/, "{ _ in \"stop it\" }"); inStop = 0 } 1' "$source" || bad=1
    return $bad
}

case "${1:-}" in
    --self-test)
        self_test "${2:-}"
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
# A missing, unreadable or malformed catalog is a failure of its own; checks 6, 8 and 10 then cannot run.
catalog="${0:a:h}/methods-catalog.tsv"
catalog_ok=1
if [[ ! -r "$catalog" ]] || ! /usr/bin/awk -F'\t' 'NF != 4 { exit 1 } END { exit NR == 0 }' "$catalog"; then
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
