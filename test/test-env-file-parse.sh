#!/bin/bash
# test/test-env-file-parse.sh
# env_file_records / env_file_value (tmux-session.sh): the env file is untrusted
# text. Each record is NAME=VALUE; a line that does not start a record continues
# the previous one (joined by one newline). Values are never sourced or evaluated.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

WORK="$(mktemp -d /tmp/envparse.XXXXXX)" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# check label file expected-record...   (records compared byte for byte)
check() {
    local label="$1" file="$2" rec i=0 ok=1
    shift 2
    local -a got=()
    while IFS= read -r -d '' rec; do got+=("$rec"); done < <(env_file_records "$file" 2>/dev/null)
    if [[ "${#got[@]}" -ne "$#" ]]; then ok=0; fi
    for rec in "$@"; do
        [[ "${got[$i]-}" == "$rec" ]] || ok=0
        i=$((i + 1))
    done
    if [[ "$ok" -eq 1 ]]; then pass "$label"; else fail "$label: got ${#got[@]} record(s): $(printf '[%s]' "${got[@]-}")"; fi
}

F="$WORK/f"
printf 'A=1\n' >"$F";                                   check "plain record" "$F" 'A=1'
printf 'B=hello world\n' >"$F";                         check "value with spaces" "$F" 'B=hello world'
printf 'C=\n' >"$F";                                    check "empty value" "$F" 'C='
printf 'D=a=b=c\n' >"$F";                               check "= inside a value" "$F" 'D=a=b=c'
printf 'E=  x  \n' >"$F";                               check "leading and trailing spaces kept" "$F" 'E=  x  '
printf 'F=l1\nl2\nl3\nG=2\n' >"$F";                     check "3-line value" "$F" $'F=l1\nl2\nl3' 'G=2'
printf 'junk line\nH=1\n' >"$F";                        check "line before the first record dropped" "$F" 'H=1'
printf 'I=1\nJ=2\nI=3\n' >"$F";                         check "repeated name replaced" "$F" 'I=3' 'J=2'
printf 'K=1' >"$F";                                     check "missing final newline" "$F" 'K=1'
printf 'L=$(touch %s/m1)\nN=`touch %s/m2`\nO=$HOME\n' "$WORK" "$WORK" >"$F"
check "command-looking values stay literal" "$F" "L=\$(touch $WORK/m1)" "N=\`touch $WORK/m2\`" 'O=$HOME'
[[ ! -e "$WORK/m1" && ! -e "$WORK/m2" ]] && pass "no marker file was created" || fail "a value was executed"
printf 'PATH=/usr/bin:/bin\nX=1\n' >"$F";               check "PATH record" "$F" 'PATH=/usr/bin:/bin' 'X=1'

got="$(env_file_value "$F" PATH)"
[[ "$got" == "/usr/bin:/bin" ]] && pass "env_file_value returns the PATH value" || fail "env_file_value PATH: '$got'"
env_file_value "$F" NOPE >/dev/null 2>&1 && fail "env_file_value of a missing name must fail" || pass "env_file_value of a missing name fails"
printf 'P=a\nb\n' >"$F"
got="$(env_file_value "$F" P)"
[[ "$got" == $'a\nb' ]] && pass "env_file_value keeps a continuation line" || fail "env_file_value P: '$got'"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
