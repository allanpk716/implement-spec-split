#!/usr/bin/env bash
# Isolated integration tests for install.sh (规格 #58): the skill-symlink segment
# (票 #63) and the local-config segment (票 #64). Every run gets a scratch HOME,
# ISS_SKILLS_DIR and ISS_CLAUDE_SETTINGS, so the real ~/.claude is never read or
# written; most cases run a copy of install.sh from a scratch git checkout, so
# they control which skills exist and where. Only outside behaviour is checked:
# stdout, the exit code, the links and where they point, settings.json and the
# backups beside it.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
INSTALL=$ROOT/install.sh
MAINTAINING=$ROOT/MAINTAINING.md
WORK=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
CASE_INDEX=0
PASSED=0
FAILED=0
RUN_EXIT=

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    rm -r "$WORK"
  else
    printf 'Artifacts: %s\n' "$WORK" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

record() {
  local status=$1 name=$2 detail=${3:-}
  if [ "$status" = PASS ]; then
    printf 'PASS %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL %s%s\n' "$name" "${detail:+: $detail}"
    FAILED=$((FAILED + 1))
  fi
}

new_case() {
  CASE_INDEX=$((CASE_INDEX + 1))
  CASE_DIR=$WORK/case-$CASE_INDEX
  CASE_HOME=$CASE_DIR/home
  CASE_SKILLS=$CASE_DIR/skills
  CASE_BIN=$CASE_DIR/bin
  CASE_CLAUDE=$CASE_DIR/claude            # settings.json lives here, backups go beside it
  CASE_SETTINGS=$CASE_CLAUDE/settings.json
  EXTRA_ENV=
  mkdir -p "$CASE_HOME" "$CASE_BIN"
}

write_skill() { # dir name
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: test fixture\n---\n\n# %s\n' "$2" "$2" > "$1/SKILL.md"
}

# A scratch checkout: install.sh copied next to a root skill and one directory
# per named sub-skill, all tracked by git. Sets REPO to its physical path.
make_repo() { # dir [sub-skill...]
  local dir=$1 skill
  shift
  mkdir -p "$dir"
  cp "$INSTALL" "$dir/install.sh"
  write_skill "$dir" implement-spec-split
  for skill in "$@"; do
    write_skill "$dir/$skill" "$skill"
  done
  git -c init.defaultBranch=main -C "$dir" init -q
  git -C "$dir" add -A
  REPO=$(cd "$dir" && pwd -P)
}

# A fake uname on PATH answering -s with the given string, as Git Bash would.
fake_uname() { # string
  cat > "$CASE_BIN/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then printf '%s\n' "$1"; exit 0; fi
/bin/uname "\$@"
EOF
  chmod +x "$CASE_BIN/uname"
}

# run_install <checkout> [args...]: runs <checkout>/install.sh with the scratch
# HOME, ISS_SKILLS_DIR and ISS_CLAUDE_SETTINGS, CLAUDE_CONFIG_DIR unset so that
# nothing can fall back to a real one; stdout in install.out, stderr in
# install.err, the status in RUN_EXIT. EXTRA_ENV, when a case sets it, adds
# space-separated VAR=value assignments (values without spaces): a fixture
# expectation list or a fault.
run_install() {
  local repo=$1
  shift
  env -u CLAUDE_CONFIG_DIR -u ISS_CONFIG_EXPECTATIONS_FILE -u ISS_INSTALL_FAULT ${EXTRA_ENV:-} \
    HOME="$CASE_HOME" ISS_SKILLS_DIR="$CASE_SKILLS" ISS_CLAUDE_SETTINGS="$CASE_SETTINGS" PATH="$CASE_BIN:$PATH" \
    bash "$repo/install.sh" "$@" > "$CASE_DIR/install.out" 2> "$CASE_DIR/install.err"
  RUN_EXIT=$?
}

# The same without ISS_SKILLS_DIR and ISS_CLAUDE_SETTINGS: both default to the
# HOME the process was given (the settings file to $CLAUDE_CONFIG_DIR instead
# when EXTRA_ENV sets it), as doctor.sh locates it.
run_install_default_location() { # checkout
  env -u ISS_SKILLS_DIR -u ISS_CLAUDE_SETTINGS -u CLAUDE_CONFIG_DIR -u ISS_CONFIG_EXPECTATIONS_FILE -u ISS_INSTALL_FAULT ${EXTRA_ENV:-} \
    HOME="$CASE_HOME" PATH="$CASE_BIN:$PATH" \
    bash "$1/install.sh" > "$CASE_DIR/install.out" 2> "$CASE_DIR/install.err"
  RUN_EXIT=$?
}

# write_settings <matcher> [indent] [file]: a settings.json with the
# delegate-guard PreToolUse hook registered under <matcher>, in the shape
# hooks/README.md shows, between two unrelated settings that must survive a fix.
# Two-space indent and the case's settings.json unless told otherwise.
write_settings() {
  local file=${3:-$CASE_SETTINGS}
  mkdir -p "$(dirname -- "$file")"
  MATCHER=$1 INDENT=${2:-'  '} node - > "$file" <<'NODE'
process.stdout.write(JSON.stringify({
  model: 'fixture-model',
  hooks: {
    PreToolUse: [{
      matcher: process.env.MATCHER,
      hooks: [{type: 'command', command: 'node "/fixture/hooks/delegate-guard.js"', timeout: 5}],
    }],
  },
  permissions: {allow: ['Bash(ls:*)']},
}, null, process.env.INDENT) + '\n');
NODE
}

# write_expectations <file>: a fixture expectation list -- the real list's item
# plus a loosen item (the matcher should no longer name NotebookEdit), which the
# installer must never apply. v1's own list has no loosen item.
write_expectations() {
  cat > "$1" <<'JSON'
[
  {
    "id": "delegate-guard-matcher",
    "direction": "tighten",
    "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "include": ["Edit", "Write", "Bash"]},
    "fix": "append-matcher-tools"
  },
  {
    "id": "delegate-guard-no-notebookedit",
    "direction": "loosen",
    "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "exclude": ["NotebookEdit"]}
  }
]
JSON
}

# One line per entry of the scratch skills directory (type, name, link target),
# empty while the directory does not exist: compare before and after --check.
snapshot() {
  local entry
  [ -d "$CASE_SKILLS" ] || return 0
  for entry in "$CASE_SKILLS"/* "$CASE_SKILLS"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -L "$entry" ]; then
      printf 'L %s -> %s\n' "${entry##*/}" "$(readlink "$entry")"
    elif [ -d "$entry" ]; then
      printf 'D %s\n' "${entry##*/}"
    else
      printf 'F %s\n' "${entry##*/}"
    fi
  done | sort
}

expect_exit() {
  local expected=$1 name=$2
  if [ "$RUN_EXIT" -eq "$expected" ]; then
    record PASS "$name"
  else
    record FAIL "$name" "exit=$RUN_EXIT, expected=$expected; $(tail -n 2 "$CASE_DIR/install.err" 2>/dev/null)"
  fi
}

expect_out_has() { # text name
  if grep -Fq -- "$1" "$CASE_DIR/install.out"; then
    record PASS "$2"
  else
    record FAIL "$2" "stdout lacks: $1"
  fi
}

expect_out_none() { # text name
  if grep -Fq -- "$1" "$CASE_DIR/install.out"; then
    record FAIL "$2" "stdout has: $1"
  else
    record PASS "$2"
  fi
}

expect_out_count() { # n text name
  local n
  n=$(grep -Fc -- "$2" "$CASE_DIR/install.out" || true)
  if [ "$n" -eq "$1" ]; then
    record PASS "$3"
  else
    record FAIL "$3" "expected $1 lines with $2, got $n: $(tr '\n' '|' < "$CASE_DIR/install.out" | head -c 400)"
  fi
}

expect_err_has() { # text name
  if grep -Fq -- "$1" "$CASE_DIR/install.err"; then
    record PASS "$2"
  else
    record FAIL "$2" "stderr lacks: $1"
  fi
}

json_brief() {
  OUT_FILE=$CASE_DIR/install.out node -e '
    const raw = require("fs").readFileSync(process.env.OUT_FILE, "utf8");
    try {
      const out = JSON.parse(raw);
      console.log("checks=" + out.checks.map(c => c.level + ":" + c.status + ":" + c.name).join(",")
        + " summary=" + JSON.stringify(out.summary));
    } catch { console.log("unparseable stdout: " + raw.slice(0, 300)); }'
}

# expect_json <name> <js predicate over the parsed stdout `out`>; CASE_DIR,
# CASE_SKILLS, CASE_SETTINGS and REPO are passed in the environment.
expect_json() {
  local name=$1 js=$2
  if OUT_FILE=$CASE_DIR/install.out JS="$js" CASE_DIR="$CASE_DIR" CASE_SKILLS="$CASE_SKILLS" \
    CASE_SETTINGS="$CASE_SETTINGS" REPO="${REPO:-}" node -e '
    const out = JSON.parse(require("fs").readFileSync(process.env.OUT_FILE, "utf8"));
    process.exit(new Function("out", "return (" + process.env.JS + ")")(out) ? 0 : 1);
  ' 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "$(json_brief)"
  fi
}

expect_lines() { # n name
  local n
  n=$(wc -l < "$CASE_DIR/install.out" | tr -d ' ')
  if [ "$n" -eq "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "expected $1 lines, got $n"
  fi
}

# A symlink whose stored target is exactly <target>.
expect_link() { # link target name
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
    record PASS "$3"
  else
    record FAIL "$3" "$(ls -ld "$1" 2>&1 | head -c 200) readlink=$(readlink "$1" 2>&1)"
  fi
}

# Nothing at the path: no link, dangling or not, no directory, no file.
expect_missing() { # path name
  if [ -e "$1" ] || [ -L "$1" ]; then
    record FAIL "$2" "$(ls -ld "$1" 2>&1 | head -c 200)"
  else
    record PASS "$2"
  fi
}

expect_entries() { # n name
  local n
  n=$(ls -A "$CASE_SKILLS" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -eq "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "expected $1 entries, got $n: $(ls -A "$CASE_SKILLS" 2>&1 | tr '\n' ' ')"
  fi
}

# Byte for byte the same: settings.json before and after, or a backup and the
# original.
expect_same_file() { # a b name
  if cmp -s "$1" "$2"; then
    record PASS "$3"
  else
    record FAIL "$3" "$(head -c 200 "$1" | tr '\n' '|') vs $(head -c 200 "$2" | tr '\n' '|')"
  fi
}

# expect_settings_at <file> <name> <js body of a function (orig, now, deepEqual)>:
# the copy the case saved as settings.before (orig) and the settings file (now),
# both parsed, go through the body, which must return; deepEqual compares
# regardless of key order.
expect_settings_at() {
  local file=$1 name=$2 js=$3
  if ORIG="$CASE_DIR/settings.before" NOW="$file" JS="$js" node -e '
    const fs = require("fs");
    const deepEqual = (a, b) => {
      if (a === b) return true;
      if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => deepEqual(x, b[i]));
      if (a && b && typeof a === "object" && typeof b === "object") {
        const keys = Object.keys(a);
        return keys.length === Object.keys(b).length && keys.every(k => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]));
      }
      return false;
    };
    const orig = JSON.parse(fs.readFileSync(process.env.ORIG, "utf8"));
    const now = JSON.parse(fs.readFileSync(process.env.NOW, "utf8"));
    process.exit((0, eval("(function (orig, now, deepEqual) {" + process.env.JS + "})"))(orig, now, deepEqual) ? 0 : 1);
  ' 2>"$CASE_DIR/expect.err"; then
    record PASS "$name"
  else
    record FAIL "$name" "$(head -c 300 "$CASE_DIR/expect.err") $(head -c 300 "$file" | tr '\n' '|')"
  fi
}

expect_settings() { # name <js body of a function (orig, now, deepEqual)>
  expect_settings_at "$CASE_SETTINGS" "$1" "$2"
}

# expect_indent <n|tab> <name>: every line of settings.json starts with a whole
# number of <n> spaces (never a tab), or with tabs only.
expect_indent() {
  if FILE="$CASE_SETTINGS" UNIT="$1" node -e '
    const lines = require("fs").readFileSync(process.env.FILE, "utf8").split("\n").filter(Boolean);
    const n = Number(process.env.UNIT);
    const ok = process.env.UNIT === "tab"
      ? lines.every(l => /^(\t*)\S/.test(l))
      : lines.every(l => { const m = l.match(/^( *)/)[0].length; return m % n === 0 && !/^ *\t/.test(l); });
    process.exit(ok && lines.some(l => /^\s/.test(l)) ? 0 : 1);
  ' 2>/dev/null; then
    record PASS "$2"
  else
    record FAIL "$2" "$(head -c 200 "$CASE_SETTINGS" | cat -t | tr '\n' '|')"
  fi
}

# expect_backups <n> <name>: how many backup directories sit beside settings.json.
expect_backups() {
  local n
  n=$(ls -d "$CASE_CLAUDE"/backups/install-* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -eq "$1" ]; then
    record PASS "$2"
  else
    record FAIL "$2" "expected $1 backup directories, got $n"
  fi
}

expect_no_backups() {
  if [ -e "$CASE_CLAUDE/backups" ]; then
    record FAIL "$1" "$(ls -A "$CASE_CLAUDE/backups" | tr '\n' ' ')"
  else
    record PASS "$1"
  fi
}

# expect_backup_is <original> <name>: the one backup is a file named like
# settings.json, byte for byte the original, in a directory named
# install-<YYYYMMDD-HHMMSS>.
expect_backup_is() {
  local dir file
  dir=$(ls -d "$CASE_CLAUDE"/backups/install-* 2>/dev/null | head -n 1)
  file=$dir/settings.json
  if [ -z "$dir" ] || [ ! -f "$file" ]; then
    record FAIL "$2" "no backup file under $CASE_CLAUDE/backups"
    return
  fi
  case "${dir##*/}" in
    install-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) record FAIL "$2" "odd backup directory name: ${dir##*/}"; return ;;
  esac
  expect_same_file "$file" "$1" "$2"
}

# 1. Fresh install from the real checkout: every directory git tracks with a
# SKILL.md gets a link named after its frontmatter name, pointing into this
# checkout. The expected set is read the same way, so a skill added later is
# covered without editing this file; today's five skills are named.
new_case
run_install "$ROOT"
expect_exit 0 "fresh install from the real checkout exits 0"
EXPECTED=$(git -C "$ROOT" ls-files | grep -E '(^|/)SKILL\.md$' | while IFS= read -r f; do
  if [ "$f" = SKILL.md ]; then d=.; else d=${f%/SKILL.md}; fi
  n=$(tr -d '\r' < "$ROOT/$f" | sed -n 's/^name:[[:space:]]*//p' | head -n 1)
  printf '%s %s\n' "$n" "$d"
done)
while IFS=' ' read -r n d; do
  [ -n "$n" ] || continue
  if [ "$d" = . ]; then t=$ROOT; else t=$ROOT/$d; fi
  expect_link "$CASE_SKILLS/$n" "$t" "real checkout: $n links to $d"
done <<< "$EXPECTED"
for n in implement-spec-split find-next grill-feature grill-map grill-router; do
  if printf '%s\n' "$EXPECTED" | cut -d ' ' -f1 | grep -Fxq -- "$n"; then
    record PASS "real checkout has the skill $n"
  else
    record FAIL "real checkout has the skill $n" "not tracked with a SKILL.md"
  fi
done
COUNT=$(printf '%s\n' "$EXPECTED" | grep -c .)
expect_out_count "$COUNT" '已建链' "fresh install prints one 已建链 line per skill"
expect_out_has "PASS $COUNT / WARN 0 / FAIL 0 / 改动 $COUNT 处" "fresh install prints the summary line"
expect_entries "$COUNT" "fresh install leaves nothing but the links"

# 2. The --json shape follows doctor.sh: one object with a checks array (one
# row per skill) and a summary; every row is PASS/created and the links are on
# disk. With ISS_SKILLS_DIR set, nothing lands under the scratch HOME's .claude.
# No settings.json, so no config row; the settings file looked at and the (empty)
# list of unexecuted loosenings are in the object all the same.
new_case
make_repo "$CASE_DIR/repo" find-next grill-router
run_install "$REPO" --json
expect_exit 0 "fixture install with --json exits 0"
expect_lines 1 "--json prints exactly one line"
expect_json "the object has the top-level keys in a fixed order" 'Object.keys(out).join(",") === "mode,windows,mainCheckout,skillsDir,claudeSettings,checks,unexecutedLoosenings,summary"'
expect_json "the settings file looked at is reported, and no loosening is listed" 'out.claudeSettings === process.env.CASE_SETTINGS && Array.isArray(out.unexecutedLoosenings) && out.unexecutedLoosenings.length === 0'
expect_json "every check has the row keys in a fixed order" 'out.checks.every(c => Object.keys(c).join(",") === "group,level,status,changed,name,dir,link,target,message,hint")'
expect_json "the summary has its keys in a fixed order" 'Object.keys(out.summary).join(",") === "pass,warn,fail,info,changed,drift"'
expect_json "every row is PASS and created" 'out.checks.length === 3 && out.checks.every(c => c.group === "skills" && c.level === "PASS" && c.status === "created" && c.changed === true)'
expect_json "rows are named after the frontmatter name, root first" 'out.checks.map(c => c.name).join(",") === "implement-spec-split,find-next,grill-router"'
expect_json "each row carries its directory, link and target" 'out.checks.every(c => c.dir === (c.name === "implement-spec-split" ? "." : c.name) && c.link === process.env.CASE_SKILLS + "/" + c.name && c.target === (c.dir === "." ? process.env.REPO : process.env.REPO + "/" + c.dir))'
expect_json "summary counts pass, change and drift" 'JSON.stringify(out.summary) === JSON.stringify({pass:3,warn:0,fail:0,info:0,changed:3,drift:0})'
expect_json "mode, platform and both locations are reported" 'out.mode === "install" && out.windows === false && out.mainCheckout === process.env.REPO && out.skillsDir === process.env.CASE_SKILLS'
expect_link "$CASE_SKILLS/implement-spec-split" "$REPO" "fixture: the root skill links to the checkout"
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "fixture: find-next links into the checkout"
expect_link "$CASE_SKILLS/grill-router" "$REPO/grill-router" "fixture: grill-router links into the checkout"
if [ -e "$CASE_HOME/.claude" ]; then
  record FAIL "ISS_SKILLS_DIR keeps the scratch HOME's .claude untouched" "$CASE_HOME/.claude was created"
else
  record PASS "ISS_SKILLS_DIR keeps the scratch HOME's .claude untouched"
fi

# 3. Idempotent: a second --json run changes nothing (every row ok), and a
# third human-mode run prints no modification line and leaves the links exactly
# as the first run made them.
LINKS_AFTER_FIRST=$(snapshot)
run_install "$REPO" --json
expect_exit 0 "second install exits 0"
expect_json "the second run changes nothing" 'out.checks.every(c => c.status === "ok" && c.changed === false) && out.summary.changed === 0 && out.summary.pass === 3'
run_install "$REPO"
expect_exit 0 "third install (human mode) exits 0"
expect_out_count 0 '已建链' "third install prints no 已建链 line"
expect_out_count 0 '已改指' "third install prints no 已改指 line"
expect_out_count 0 '已删除悬空链' "third install prints no 已删除悬空链 line"
expect_out_has "改动 0 处" "third install reports 改动 0 处"
if [ "$(snapshot)" = "$LINKS_AFTER_FIRST" ]; then
  record PASS "links are identical after repeated runs"
else
  record FAIL "links are identical after repeated runs" "$(snapshot)"
fi

# 4. A link made the way README.md documents it, through the skills directory's
# own entry for the root skill, resolves to the same directory and counts as in
# place: judged by where the link resolves, not by its text.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_SKILLS"
ln -s "$REPO" "$CASE_SKILLS/implement-spec-split"
ln -s "$CASE_SKILLS/implement-spec-split/find-next" "$CASE_SKILLS/find-next"
run_install "$REPO" --json
expect_exit 0 "a link made through the root skill's entry exits 0"
expect_json "a link made through the root skill's entry is already in place" 'out.checks.length === 2 && out.checks.every(c => c.status === "ok") && out.summary.changed === 0 && out.summary.drift === 0'
expect_link "$CASE_SKILLS/find-next" "$CASE_SKILLS/implement-spec-split/find-next" "an in-place link through another path is left as it is"

# 5. A link pointing into another checkout (wrong): --check reports it as FAIL
# and leaves it; the install re-points it and leaves the other checkout alone.
new_case
make_repo "$CASE_DIR/repo" find-next grill-router
mkdir -p "$CASE_DIR/other-clone/find-next" "$CASE_DIR/other-clone/grill-router"
printf 'x\n' > "$CASE_DIR/other-clone/find-next/SKILL.md"
mkdir -p "$CASE_SKILLS"
ln -s "$CASE_DIR/other-clone/find-next" "$CASE_SKILLS/find-next"
ln -s "$CASE_DIR/other-clone/grill-router" "$CASE_SKILLS/grill-router"
BEFORE=$(snapshot)
run_install "$REPO" --check
expect_exit 1 "--check on a wrong link exits 1"
expect_out_has '[FAIL] find-next 指向别处' "--check names the wrong link"
expect_out_count 0 '已改指' "--check prints no modification line"
if [ "$(snapshot)" = "$BEFORE" ]; then
  record PASS "--check leaves the wrong link alone"
else
  record FAIL "--check leaves the wrong link alone" "$(snapshot)"
fi
run_install "$REPO" --check --json
expect_json "--check reports the wrong links and the missing root link" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["missing:implement-spec-split","wrong:find-next","wrong:grill-router"]) && out.summary.drift === 3 && out.summary.changed === 0 && out.mode === "check"'
expect_json "a wrong link's row says where it points and where it should" 'out.checks[1].message.includes(process.env.CASE_DIR + "/other-clone/find-next") && out.checks[1].message.includes(process.env.REPO + "/find-next")'
run_install "$REPO"
expect_exit 0 "install re-points a wrong link and exits 0"
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "wrong link is re-pointed into the checkout"
expect_link "$CASE_SKILLS/grill-router" "$REPO/grill-router" "second wrong link is re-pointed into the checkout"
if [ -f "$CASE_DIR/other-clone/find-next/SKILL.md" ]; then
  record PASS "the other checkout is left alone"
else
  record FAIL "the other checkout is left alone" "its file is gone"
fi
expect_out_count 2 '已改指' "install prints one 已改指 line per re-pointed link"
run_install "$REPO" --json
expect_json "after the install the state is clean" 'out.checks.every(c => c.status === "ok") && out.summary.drift === 0'

# 6. A dangling link at a current skill's name (the checkout moved):
# --check reports it as FAIL and leaves it; the install re-points it.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_SKILLS"
ln -s "$CASE_DIR/old-place/find-next" "$CASE_SKILLS/find-next"
run_install "$REPO" --check --json
expect_exit 1 "--check on a dangling link exits 1"
expect_json "--check reports the dangling link as FAIL" 'out.checks.some(c => c.status === "dangling" && c.level === "FAIL" && c.name === "find-next") && out.checks.some(c => c.status === "missing" && c.name === "implement-spec-split")'
expect_link "$CASE_SKILLS/find-next" "$CASE_DIR/old-place/find-next" "--check leaves the dangling link alone"
run_install "$REPO"
expect_exit 0 "install re-points a dangling link"
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "dangling link is re-pointed into the checkout"
expect_out_count 1 '已改指' "install prints one 已改指 line for the dangling link"
expect_out_count 1 '已建链' "install prints one 已建链 line for the missing root link"

# 7. Dangling links left behind by skills the checkout no longer has (the two
# old switches, linked the two ways README showed): --check reports them, the
# install deletes them, and nothing replaces them.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install "$REPO" --json
expect_exit 0 "fixture install exits 0 before the stale links are added"
ln -s "$REPO/judgment-model" "$CASE_SKILLS/judgment-model"
ln -s "$CASE_SKILLS/implement-spec-split/worker-model" "$CASE_SKILLS/worker-model"
run_install "$REPO" --check --json
expect_exit 1 "--check on stale dangling links exits 1"
expect_json "--check reports both stale links as dangling, the skills as ok" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["ok:implement-spec-split","ok:find-next","dangling:judgment-model","dangling:worker-model"]) && out.summary.drift === 2'
expect_link "$CASE_SKILLS/judgment-model" "$REPO/judgment-model" "--check leaves the stale link alone"
run_install "$REPO" --json
expect_exit 0 "install removing stale links exits 0"
expect_json "install reports both stale links as removed" 'out.checks.filter(c => c.status === "removed" && c.changed === true && c.level === "PASS").map(c => c.name).join(",") === "judgment-model,worker-model" && out.summary.changed === 2 && out.summary.drift === 0'
expect_missing "$CASE_SKILLS/judgment-model" "install deletes the stale judgment-model link"
expect_missing "$CASE_SKILLS/worker-model" "install deletes the stale worker-model link"
expect_entries 2 "after removing the stale links only the two skill links remain"

# 8. A dangling link that does not point into this checkout is somebody else's:
# neither reported nor touched.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_SKILLS"
ln -s "$CASE_DIR/elsewhere/some-skill" "$CASE_SKILLS/some-skill"
run_install "$REPO" --json
expect_exit 0 "a foreign dangling link is not drift"
expect_json "a foreign dangling link is not reported" 'out.checks.length === 2 && out.checks.every(c => c.name !== "some-skill") && out.summary.drift === 0'
expect_link "$CASE_SKILLS/some-skill" "$CASE_DIR/elsewhere/some-skill" "a foreign dangling link is left alone"

# 9. A real directory of the root skill's name (another clone): never touched,
# one WARN line, exit code 1 because drift remains; the sub-skills are still
# linked. --check reports the same WARN and changes nothing.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_SKILLS/implement-spec-split/hooks"
printf 'keep\n' > "$CASE_SKILLS/implement-spec-split/hooks/keep"
run_install "$REPO"
expect_exit 1 "a real directory of another clone leaves the exit code at 1"
expect_out_count 1 '真实目录' "the real directory gets exactly one warning line"
expect_out_has '[WARN] implement-spec-split 是真实目录不是软链，未动' "the warning names the root skill"
expect_out_count 1 '[WARN]' "a real directory prints one WARN line and no more"
if [ -f "$CASE_SKILLS/implement-spec-split/hooks/keep" ] && [ ! -L "$CASE_SKILLS/implement-spec-split" ]; then
  record PASS "the real directory is left alone"
else
  record FAIL "the real directory is left alone" "$(ls -la "$CASE_SKILLS/implement-spec-split" 2>&1 | head -c 200)"
fi
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "sub-skills are linked despite the real directory"
BEFORE=$(snapshot)
run_install "$REPO" --check
expect_exit 1 "--check on a real directory of another clone exits 1"
expect_out_has '[WARN] implement-spec-split 是真实目录不是软链，未动' "--check warns about the real directory"
if [ "$(snapshot)" = "$BEFORE" ]; then
  record PASS "--check leaves the real directory alone"
else
  record FAIL "--check leaves the real directory alone" "$(snapshot)"
fi
run_install "$REPO" --check --json
expect_json "--check --json reports the real directory as WARN and the rest as ok" 'JSON.stringify(out.checks.map(c => c.level + ":" + c.status + ":" + c.name)) === JSON.stringify(["WARN:real-dir:implement-spec-split","PASS:ok:find-next"]) && out.summary.drift === 1 && out.summary.warn === 1 && out.summary.fail === 0'

# 9b. The same at a sub-skill's name.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_SKILLS/find-next"
printf 'keep\n' > "$CASE_SKILLS/find-next/keep"
run_install "$REPO" --json
expect_exit 1 "a real directory at a sub-skill's name leaves the exit code at 1"
expect_json "a real directory at a sub-skill's name is WARN, the root skill is linked" 'JSON.stringify(out.checks.map(c => c.level + ":" + c.status + ":" + c.name)) === JSON.stringify(["PASS:created:implement-spec-split","WARN:real-dir:find-next"])'
if [ -f "$CASE_SKILLS/find-next/keep" ] && [ ! -L "$CASE_SKILLS/find-next" ]; then
  record PASS "the real directory at a sub-skill's name is left alone"
else
  record FAIL "the real directory at a sub-skill's name is left alone"
fi

# 10. README's clone-direct form: ~/.claude/skills/implement-spec-split is a
# real directory and is the checkout install.sh runs from. That satisfies the
# root skill without a warning; the sub-skill links go into the checkout.
new_case
make_repo "$CASE_SKILLS/implement-spec-split" find-next grill-router
run_install "$REPO" --json
expect_exit 0 "clone-direct form exits 0"
expect_json "the root skill's real directory is in place, the sub-skills get links" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["ok:implement-spec-split","created:find-next","created:grill-router"]) && out.checks[0].changed === false && out.checks[0].level === "PASS" && out.summary.drift === 0'
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "clone-direct form: find-next links into the checkout"
expect_link "$CASE_SKILLS/grill-router" "$REPO/grill-router" "clone-direct form: grill-router links into the checkout"
if [ -d "$CASE_SKILLS/implement-spec-split" ] && [ ! -L "$CASE_SKILLS/implement-spec-split" ]; then
  record PASS "clone-direct form leaves the checkout directory as it is"
else
  record FAIL "clone-direct form leaves the checkout directory as it is"
fi
run_install "$REPO"
expect_exit 0 "clone-direct form exits 0 in human mode"
expect_out_none '[WARN]' "clone-direct form prints no warning"

# 11. --check on a machine where nothing is installed: every skill is FAIL
# missing, the exit code is 1, and not even the skills directory is created.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install "$REPO" --check
expect_exit 1 "--check with nothing installed exits 1"
expect_out_count 2 '[FAIL]' "--check prints one FAIL line per missing skill"
expect_out_has '[FAIL] find-next 缺链' "--check names the missing link"
expect_out_has '只检查' "--check says it is only checking"
expect_out_has "PASS 0 / WARN 0 / FAIL 2 / 改动 0 处" "--check reports the summary"
if [ -e "$CASE_SKILLS" ]; then
  record FAIL "--check does not create the skills directory"
else
  record PASS "--check does not create the skills directory"
fi
run_install "$REPO" --check --json
expect_json "--check --json reports every skill missing" 'out.checks.length === 2 && out.checks.every(c => c.status === "missing" && c.level === "FAIL" && c.changed === false) && out.summary.drift === 2 && out.summary.changed === 0 && out.mode === "check"'
expect_json "--check --json still names the skills directory it looked in" 'out.skillsDir === process.env.CASE_SKILLS'
if [ -e "$CASE_SKILLS" ]; then
  record FAIL "--check --json does not create the skills directory"
else
  record PASS "--check --json does not create the skills directory"
fi

# 12. --check over a mixed state (real directory, dangling, wrong, stale)
# reports every kind and changes nothing, in both output modes.
new_case
make_repo "$CASE_DIR/repo" find-next grill-router
mkdir -p "$CASE_SKILLS/implement-spec-split" "$CASE_DIR/other/grill-router"
printf 'keep\n' > "$CASE_SKILLS/implement-spec-split/keep"
printf 'keep\n' > "$CASE_DIR/other/grill-router/SKILL.md"
ln -s "$CASE_DIR/other/grill-router" "$CASE_SKILLS/grill-router"
ln -s "$CASE_DIR/old/find-next" "$CASE_SKILLS/find-next"
ln -s "$REPO/judgment-model" "$CASE_SKILLS/judgment-model"
BEFORE=$(snapshot)
run_install "$REPO" --check
expect_exit 1 "--check on a mixed state exits 1"
if [ "$(snapshot)" = "$BEFORE" ]; then
  record PASS "--check (human mode) changes nothing in a mixed state"
else
  record FAIL "--check (human mode) changes nothing in a mixed state" "$(snapshot)"
fi
expect_out_count 3 '[FAIL]' "--check prints one FAIL line per missing, wrong or dangling link"
expect_out_count 1 '[WARN]' "--check prints one WARN line for the real directory"
run_install "$REPO" --check --json
if [ "$(snapshot)" = "$BEFORE" ]; then
  record PASS "--check (--json) changes nothing in a mixed state"
else
  record FAIL "--check (--json) changes nothing in a mixed state" "$(snapshot)"
fi
expect_json "every kind of drift is reported in its own status" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["real-dir:implement-spec-split","dangling:find-next","wrong:grill-router","dangling:judgment-model"])'
expect_json "the drift count matches the rows" 'out.summary.drift === 4 && out.summary.warn === 1 && out.summary.fail === 3 && out.summary.changed === 0'
run_install "$REPO" --json
expect_exit 1 "the install still exits 1 while the real directory remains"
expect_json "the install reports what it did with each" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name + ":" + c.changed)) === JSON.stringify(["real-dir:implement-spec-split:false","relinked:find-next:true","relinked:grill-router:true","removed:judgment-model:true"])'
expect_json "the install's summary counts three changes and the remaining drift" 'out.summary.changed === 3 && out.summary.drift === 1 && out.summary.warn === 1 && out.summary.fail === 0'

# 13. --json parses with node -e and is stable between two runs on the same
# state: byte-identical output, keys that do not move.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install "$REPO" --check --json
FIRST=$(cat "$CASE_DIR/install.out")
if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CASE_DIR/install.out" 2>"$CASE_DIR/parse.err"; then
  record PASS "--check --json parses with node -e"
else
  record FAIL "--check --json parses with node -e" "$(cat "$CASE_DIR/parse.err")"
fi
run_install "$REPO" --check --json
if [ "$(cat "$CASE_DIR/install.out")" = "$FIRST" ]; then
  record PASS "two --check --json runs print the same object"
else
  record FAIL "two --check --json runs print the same object"
fi
run_install "$REPO" --json
run_install "$REPO" --json
INSTALLED=$(cat "$CASE_DIR/install.out")
run_install "$REPO" --json
if [ "$(cat "$CASE_DIR/install.out")" = "$INSTALLED" ]; then
  record PASS "two install --json runs on an installed state print the same object"
else
  record FAIL "two install --json runs on an installed state print the same object" "first=$INSTALLED second=$(cat "$CASE_DIR/install.out")"
fi
expect_json "the keys are the same as in the other modes" 'Object.keys(out).join(",") === "mode,windows,mainCheckout,skillsDir,claudeSettings,checks,unexecutedLoosenings,summary" && Object.keys(out.summary).join(",") === "pass,warn,fail,info,changed,drift" && out.checks.every(c => Object.keys(c).join(",") === "group,level,status,changed,name,dir,link,target,message,hint")'
run_install "$REPO" --check --json
expect_exit 0 "--check --json on an installed state exits 0"
expect_json "no drift means exit 0 and an all-PASS summary" 'out.summary.drift === 0 && out.summary.fail === 0 && out.summary.warn === 0 && out.checks.every(c => c.level === "PASS")'

# 14. Windows (Git Bash: uname -s starting with MINGW or MSYS): no link is made
# or removed; each skill not verifiably in place gets one WARN line with the
# manual step (README: mklink /J, or copy), --check reports a missing link as
# WARN rather than FAIL, and the exit code still says drift. A directory
# already at the name (a junction or a copy) counts as present.
for FAKE in MINGW64_NT-10.0-19045 MSYS_NT-10.0-19045; do
  new_case
  fake_uname "$FAKE"
  make_repo "$CASE_DIR/repo" find-next
  run_install "$REPO" --json
  expect_exit 1 "$FAKE: install with nothing in place exits 1"
  if [ -e "$CASE_SKILLS" ]; then
    record FAIL "$FAKE: install creates nothing" "$(ls -A "$CASE_SKILLS" | tr '\n' ' ')"
  else
    record PASS "$FAKE: install creates nothing"
  fi
  expect_json "$FAKE: every skill is a WARN manual step, none FAIL" 'out.windows === true && out.checks.length === 2 && out.checks.every(c => c.level === "WARN" && c.status === "manual" && c.changed === false) && out.summary.fail === 0 && out.summary.changed === 0 && out.summary.drift === 2'
  expect_json "$FAKE: each hint carries mklink /J and both paths" 'out.checks.every(c => c.hint.includes("mklink /J") && c.hint.includes(c.link) && c.hint.includes(c.target))'
  run_install "$REPO"
  expect_exit 1 "$FAKE: human mode with nothing in place exits 1"
  expect_out_count 2 'mklink /J' "$FAKE: human mode prints one manual step per skill"
  expect_out_count 0 '[FAIL]' "$FAKE: human mode prints no FAIL"
  run_install "$REPO" --check --json
  expect_exit 1 "$FAKE: --check with nothing in place exits 1"
  expect_json "$FAKE: --check reports a missing link as WARN, not FAIL" 'out.mode === "check" && out.checks.every(c => c.level === "WARN" && c.status === "manual") && out.summary.fail === 0'
  mkdir -p "$CASE_SKILLS/find-next"
  printf 'x\n' > "$CASE_SKILLS/find-next/SKILL.md"
  run_install "$REPO" --json
  expect_json "$FAKE: a junction or copy at the name counts as present" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["manual:implement-spec-split","present:find-next"]) && out.checks[1].level === "PASS" && out.checks[1].changed === false'
  if [ -L "$CASE_SKILLS/find-next" ]; then
    record FAIL "$FAKE: a directory at the name stays a directory"
  else
    record PASS "$FAKE: a directory at the name stays a directory"
  fi
  # The config segment is node only: it runs on Windows too.
  write_settings 'Edit|Write|NotebookEdit'
  cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
  run_install "$REPO" --json
  expect_json "$FAKE: the config segment tightens the matcher all the same" 'out.checks.some(c => c.group === "config" && c.status === "tightened" && c.changed === true) && out.windows === true'
  expect_settings "$FAKE: the matcher is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|NotebookEdit|Bash"'
  expect_backups 1 "$FAKE: the backup is beside settings.json"
done

# 15. Without ISS_SKILLS_DIR the links go to ~/.claude/skills of the HOME the
# process was given (the scratch HOME), and nowhere else.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install_default_location "$REPO"
expect_exit 0 "default location exits 0"
expect_link "$CASE_HOME/.claude/skills/implement-spec-split" "$REPO" "default location is \$HOME/.claude/skills: root skill"
expect_link "$CASE_HOME/.claude/skills/find-next" "$REPO/find-next" "default location is \$HOME/.claude/skills: find-next"
if [ -e "$CASE_SKILLS" ]; then
  record FAIL "default location does not look at the scratch ISS_SKILLS_DIR path"
else
  record PASS "default location does not look at the scratch ISS_SKILLS_DIR path"
fi

# 16. install.sh reached through a symlink, as on a machine where
# ~/.claude/skills/implement-spec-split links to the checkout: the checkout is
# where the script really lives and the links carry that physical path.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_DIR/linked"
ln -s "$REPO" "$CASE_DIR/linked/implement-spec-split"
run_install "$CASE_DIR/linked/implement-spec-split" --json
expect_exit 0 "install through a symlinked skill path exits 0"
expect_json "the checkout is the script's physical location" 'out.mainCheckout === process.env.REPO'
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "links carry the physical path, not the symlinked one"
expect_link "$CASE_SKILLS/implement-spec-split" "$REPO" "the root link carries the physical path"

# 17. A skill added later is linked without touching install.sh, a nested
# directory is found, the link is named after the frontmatter name rather than
# the directory, and a directory with a non-ASCII name is found too (git
# quotes such paths unless asked not to); a file that is merely named like a
# skill file is not one.
new_case
make_repo "$CASE_DIR/repo" find-next
write_skill "$REPO/wrappers/feature" grill-feature
write_skill "$REPO/brand-new" brand-new
write_skill "$REPO/子技能" sub-skill
mkdir -p "$REPO/upstream"
printf -- '---\nname: not-a-skill\n---\n' > "$REPO/upstream/implement-spec.SKILL.md"
git -C "$REPO" add -A
run_install "$REPO" --json
expect_exit 0 "a checkout with a nested and a new skill exits 0"
expect_json "a nested, a new and a non-ASCII skill are linked by their frontmatter names" 'JSON.stringify(out.checks.map(c => c.name + "=" + c.dir)) === JSON.stringify(["implement-spec-split=.","brand-new=brand-new","find-next=find-next","grill-feature=wrappers/feature","sub-skill=子技能"])'
expect_link "$CASE_SKILLS/grill-feature" "$REPO/wrappers/feature" "nested skill links to its directory"
expect_link "$CASE_SKILLS/brand-new" "$REPO/brand-new" "new skill is linked without a script change"
expect_link "$CASE_SKILLS/sub-skill" "$REPO/子技能" "a non-ASCII directory is found and linked"
expect_missing "$CASE_SKILLS/not-a-skill" "a file not named SKILL.md is not a skill"

# 18. Usage: unknown argument 64; -h and --help print the usage and exit 0;
# neither creates anything.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install "$REPO" --unknown
expect_exit 64 "unknown argument exits 64"
expect_err_has 'usage' "unknown argument prints a usage line on stderr"
run_install "$REPO" -h
expect_exit 0 "-h exits 0"
expect_out_has 'Usage:' "-h prints the usage"
run_install "$REPO" --help
expect_exit 0 "--help exits 0"
if [ -e "$CASE_SKILLS" ]; then
  record FAIL "usage and help create nothing"
else
  record PASS "usage and help create nothing"
fi

# 19. A SKILL.md without a frontmatter name is reported and skipped (the root
# skill in particular must not fall back to the directory name); a second
# directory claiming a name already linked is reported and skipped too.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$REPO/nameless"
printf -- '---\ndescription: no name here\n---\n' > "$REPO/nameless/SKILL.md"
write_skill "$REPO/twin" find-next
git -C "$REPO" add -A
run_install "$REPO" --json
expect_exit 1 "a nameless SKILL.md and a twin leave the exit code at 1"
expect_json "the nameless and the twin are FAIL rows and skipped, the rest linked" 'JSON.stringify(out.checks.map(c => c.status + ":" + c.name)) === JSON.stringify(["created:implement-spec-split","created:find-next","error:","error:find-next"]) && out.summary.fail === 2'
expect_link "$CASE_SKILLS/find-next" "$REPO/find-next" "the first directory claiming a name gets the link"
expect_missing "$CASE_SKILLS/nameless" "a nameless SKILL.md gets no link"
expect_missing "$CASE_SKILLS/twin" "a twin gets no link"

# 20. The config segment with the real expectation list (v1: the delegate-guard
# PreToolUse matcher must cover Edit, Write and Bash), against this machine's
# shape before #64: matcher Edit|Write|NotebookEdit. --check reports the missing
# Bash as FAIL and writes nothing; the install backs settings.json up beside it,
# appends Bash, keeps the indentation, changes nothing else in the file (compared
# after parsing), prints one modification line, and a second run changes nothing
# and makes no new backup.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write|NotebookEdit'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO" --check
expect_exit 1 "--check with the matcher lacking Bash exits 1"
expect_out_has '[FAIL] delegate-guard hook 的 PreToolUse matcher "Edit|Write|NotebookEdit" 缺 Bash' "--check names the missing tool"
expect_out_count 0 '已补为' "--check prints no modification line"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "--check leaves settings.json alone"
expect_no_backups "--check makes no backup"
run_install "$REPO"
expect_exit 0 "install with the matcher lacking Bash exits 0"
expect_out_count 1 '已补为' "install prints one modification line for the matcher"
expect_out_has '[PASS] delegate-guard hook 的 PreToolUse matcher "Edit|Write|NotebookEdit" 缺 Bash，已补为 "Edit|Write|NotebookEdit|Bash"' "the modification line names the old and the new matcher"
expect_out_has 'PASS 3 / WARN 0 / FAIL 0 / 改动 3 处' "the summary counts the fix as a change"
expect_settings "only the matcher differs from the original" 'orig.hooks.PreToolUse[0].matcher = "Edit|Write|NotebookEdit|Bash"; return deepEqual(orig, now)'
expect_indent 2 "the indentation is kept"
expect_backups 1 "one backup directory beside settings.json"
expect_backup_is "$CASE_DIR/settings.before" "the backup is the original file"
expect_out_has "原文件备份：$CASE_CLAUDE/backups/install-" "the modification line points at the backup"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.after"
run_install "$REPO"
expect_exit 0 "a second install exits 0"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.after" "a second install leaves settings.json as it is"
expect_backups 1 "a second install makes no new backup"
expect_out_count 0 '已补为' "a second install prints no modification line"
run_install "$REPO" --check --json
expect_exit 0 "--check after the fix exits 0"
expect_json "after the fix the config row is PASS ok" 'JSON.stringify(out.checks.map(c => c.group + ":" + c.status)) === JSON.stringify(["skills:ok","skills:ok","config:ok"]) && out.claudeSettings === process.env.CASE_SETTINGS && out.unexecutedLoosenings.length === 0'

# 21. Already satisfied: with Bash in the matcher (any position), a blank
# matcher (every tool, as doctor.sh reads it) or no matcher key at all,
# settings.json stays byte for byte, no backup appears, no modification line is
# printed and the config row is PASS ok.
new_case
make_repo "$CASE_DIR/repo" find-next
for MATCHER in 'Edit|Write|NotebookEdit|Bash' 'Bash|Edit|Write' ''; do
  write_settings "$MATCHER"
  cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
  run_install "$REPO" --json
  expect_exit 0 "matcher '$MATCHER' already covers Bash: exit 0"
  expect_json "matcher '$MATCHER': the config row is PASS ok and nothing changed" 'out.checks.filter(c => c.group === "config").length === 1 && out.checks.some(c => c.group === "config" && c.status === "ok" && c.level === "PASS" && c.changed === false && c.name === "delegate-guard-matcher") && out.checks.filter(c => c.group === "config").every(c => !c.changed) && out.summary.drift === 0'
  expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "matcher '$MATCHER': settings.json is byte for byte the same"
  expect_no_backups "matcher '$MATCHER': no backup"
done
write_settings 'Edit|Write|NotebookEdit|Bash'
node -e 'const fs = require("fs"); const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); delete o.hooks.PreToolUse[0].matcher; fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2) + "\n");' "$CASE_SETTINGS"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO"
expect_exit 0 "a registration without a matcher key: exit 0"
expect_out_count 0 '已补为' "a registration without a matcher key prints no modification line"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "a registration without a matcher key: settings.json is byte for byte the same"
expect_no_backups "a registration without a matcher key: no backup"

# 22. What gets appended: the missing tools in the list's order, at the end of
# the matcher; everything already there stays, NotebookEdit included.
new_case
make_repo "$CASE_DIR/repo" find-next
for PAIR in 'Edit|Write => Edit|Write|Bash' 'Bash|Edit => Bash|Edit|Write' 'Edit => Edit|Write|Bash' 'Edit|Write|NotebookEdit => Edit|Write|NotebookEdit|Bash'; do
  BEFORE=${PAIR%% => *}
  AFTER=${PAIR##* => }
  write_settings "$BEFORE"
  cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
  run_install "$REPO"
  expect_exit 0 "'$BEFORE': exit 0"
  expect_settings "'$BEFORE' becomes '$AFTER' and nothing else differs" "orig.hooks.PreToolUse[0].matcher = \"$AFTER\"; return deepEqual(orig, now)"
  expect_out_has "已补为 \"$AFTER\"" "'$BEFORE': the modification line names the new matcher"
done

# 23. The file's shape is followed: four spaces stay four spaces, tabs stay
# tabs, and a file without a trailing newline stays without one.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write' '    '
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO"
expect_exit 0 "a file indented with four spaces exits 0"
expect_indent 4 "four-space indentation is kept"
expect_settings "four-space file: the matcher is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|Bash"'
write_settings 'Edit|Write' "$(printf '\t')"
run_install "$REPO"
expect_exit 0 "a file indented with tabs exits 0"
expect_indent tab "tab indentation is kept"
expect_settings "tab file: the matcher is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|Bash"'
write_settings 'Edit|Write' '    '
printf '%s' "$(cat "$CASE_SETTINGS")" > "$CASE_SETTINGS"
run_install "$REPO"
expect_exit 0 "a file without a trailing newline exits 0"
if [ -n "$(tail -c 1 "$CASE_SETTINGS")" ]; then
  record PASS "no trailing newline is added"
else
  record FAIL "no trailing newline is added" "the file ends with a newline"
fi
expect_settings "no-newline file: the matcher is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|Bash"'

# 24. No delegate-guard registration: not drift, not handled, not reported --
# a settings.json with other hooks only, or a PreToolUse that is not an array.
# Both are left as they are and no backup is made.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_CLAUDE"
printf '{\n  "hooks": {\n    "PreToolUse": [\n      {"matcher": "Agent|Task", "hooks": [{"type": "command", "command": "node \\"/fixture/hooks/subagent-guard.js\\""}]}\n    ],\n    "Stop": []\n  }\n}\n' > "$CASE_SETTINGS"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO" --json
expect_exit 0 "other hooks only: exit 0"
expect_json "other hooks only: no config row" 'out.checks.every(c => c.group === "skills") && out.summary.drift === 0'
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "other hooks only: settings.json is untouched"
expect_no_backups "other hooks only: no backup"
run_install "$REPO" --check
expect_exit 0 "other hooks only: --check exits 0"
expect_out_none 'delegate-guard' "other hooks only: --check prints nothing about delegate-guard"
printf '{"hooks": {"PreToolUse": {"matcher": "Bash"}}}\n' > "$CASE_SETTINGS"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO" --json
expect_json "PreToolUse not an array: no config row" 'out.checks.every(c => c.group === "skills")'
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "PreToolUse not an array: settings.json is untouched"

# 24b. No settings.json at all: nothing is created (not the directory, not a
# backup), no config row, and the human output still names the file looked at.
new_case
make_repo "$CASE_DIR/repo" find-next
run_install "$REPO" --json
expect_exit 0 "no settings.json: exit 0"
expect_json "no settings.json: no config row, the path is still reported" 'out.checks.every(c => c.group === "skills") && out.claudeSettings === process.env.CASE_SETTINGS'
if [ -e "$CASE_CLAUDE" ]; then
  record FAIL "no settings.json: nothing is created" "$(ls -la "$CASE_CLAUDE" 2>&1 | head -c 200)"
else
  record PASS "no settings.json: nothing is created"
fi
run_install "$REPO" --check
expect_out_has "配置文件：$CASE_SETTINGS" "the human output names the settings file it looked in"

# 25. A loosen item (from a fixture: v1's list has none) is never applied. The
# machine still names NotebookEdit and the repo would rather it did not: the
# install changes nothing, makes no backup, lists the item under 未执行的放宽项
# in human mode and in --json (its own array, plus a WARN row that counts as
# drift), and exits 1. The tighten item in the same list is judged as usual; a
# loosen item the machine already satisfies is PASS and not listed.
new_case
make_repo "$CASE_DIR/repo" find-next
write_expectations "$CASE_DIR/expectations.json"
write_settings 'Edit|Write|NotebookEdit|Bash'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
EXTRA_ENV="ISS_CONFIG_EXPECTATIONS_FILE=$CASE_DIR/expectations.json"
run_install "$REPO"
expect_exit 1 "an unexecuted loosen item leaves the exit code at 1"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "a loosen item never modifies settings.json"
expect_no_backups "a loosen item makes no backup"
expect_out_has '未执行的放宽项' "human mode prints the 未执行的放宽项 section"
expect_out_has '- 放宽项未执行：delegate-guard hook 的 PreToolUse matcher 含 NotebookEdit（仓库期望不含）' "the section names the loosen item"
expect_out_has '[WARN] 放宽项未执行：delegate-guard hook 的 PreToolUse matcher' "the loosen item is one WARN line"
expect_out_count 1 '[WARN]' "nothing else is a WARN"
expect_out_has '[PASS] delegate-guard hook 的 PreToolUse matcher 已覆盖 Edit|Write|Bash' "the tighten item in the same list is judged as usual"
expect_out_has 'PASS 3 / WARN 1 / FAIL 0 / 改动 2 处' "the summary counts the loosen item as drift and no change"
run_install "$REPO" --json
expect_json "the loosen item is a WARN row in checks, after the skill rows" 'JSON.stringify(out.checks.map(c => c.group + ":" + c.level + ":" + c.status + ":" + c.name)) === JSON.stringify(["skills:PASS:ok:implement-spec-split","skills:PASS:ok:find-next","config:PASS:ok:delegate-guard-matcher","config:WARN:loosen:delegate-guard-no-notebookedit"])'
expect_json "the loosen item is in its own array, the same row" 'out.unexecutedLoosenings.length === 1 && out.unexecutedLoosenings[0].name === "delegate-guard-no-notebookedit" && out.unexecutedLoosenings[0].status === "loosen" && out.unexecutedLoosenings[0].level === "WARN" && out.unexecutedLoosenings[0].message.includes("NotebookEdit")'
expect_json "the loosen row counts as drift, nothing changed" 'out.summary.warn === 1 && out.summary.drift === 1 && out.summary.changed === 0 && out.summary.pass === 3'
expect_json "config rows have the same keys as skill rows and name the settings file" 'out.checks.filter(c => c.group === "config").every(c => Object.keys(c).join(",") === "group,level,status,changed,name,dir,link,target,message,hint" && c.link === process.env.CASE_SETTINGS && c.dir === "" && c.target === "" && c.changed === false)'
expect_lines 1 "--json prints the loosenings inside the object, not as a section"
write_settings 'Edit|Write|Bash'
run_install "$REPO" --json
expect_json "a satisfied loosen item is PASS ok and not listed" '!out.checks.some(c => c.status === "loosen") && out.checks.filter(c => c.group === "config").every(c => c.status === "ok" && c.level === "PASS") && out.unexecutedLoosenings.length === 0 && out.summary.drift === 0'
run_install "$REPO"
expect_exit 0 "a satisfied loosen item exits 0"
expect_out_none '未执行的放宽项' "no section when no loosening is unexecuted"

# 26. --check with a tighten item unmet and a loosen item unexecuted (fixture):
# both are reported -- FAIL unmet and WARN loosen -- in human mode with the
# section, and in --json; nothing is written and no backup is made. The install
# that follows fixes the tighten item only.
new_case
make_repo "$CASE_DIR/repo" find-next
write_expectations "$CASE_DIR/expectations.json"
write_settings 'Edit|Write|NotebookEdit'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
EXTRA_ENV="ISS_CONFIG_EXPECTATIONS_FILE=$CASE_DIR/expectations.json"
run_install "$REPO" --check
expect_exit 1 "--check with an unmet tighten item exits 1"
expect_out_has '[FAIL] delegate-guard hook 的 PreToolUse matcher "Edit|Write|NotebookEdit" 缺 Bash（期望覆盖 Edit|Write|Bash）' "--check reports the unmet tighten item"
expect_out_has '[WARN] 放宽项未执行：delegate-guard hook 的 PreToolUse matcher 含 NotebookEdit（仓库期望不含） -> 安装脚本不改放宽项' "--check reports the unexecuted loosen item"
expect_out_has '未执行的放宽项' "--check prints the 未执行的放宽项 section"
expect_out_has 'PASS 0 / WARN 1 / FAIL 3 / 改动 0 处' "--check's summary counts the two missing links and the unmet tighten item"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "--check leaves settings.json alone"
expect_no_backups "--check makes no backup"
run_install "$REPO" --check --json
expect_json "--check --json reports both items" 'JSON.stringify(out.checks.filter(c => c.group === "config").map(c => c.level + ":" + c.status + ":" + c.name)) === JSON.stringify(["FAIL:unmet:delegate-guard-matcher","WARN:loosen:delegate-guard-no-notebookedit"]) && out.unexecutedLoosenings.length === 1 && out.summary.changed === 0 && out.mode === "check"'
expect_json "the unmet tighten row's hint is to run the install" 'out.checks.find(c => c.status === "unmet").hint.includes(process.env.REPO + "/install.sh")'
run_install "$REPO"
expect_exit 1 "the install fixes the tighten item and still exits 1 for the loosen item"
expect_settings "the tighten item is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|NotebookEdit|Bash"'
expect_out_count 1 '已补为' "the install prints one modification line for the tighten item"
expect_out_has '未执行的放宽项' "the install still lists the loosen item"
expect_backups 1 "one backup for the tighten item"

# 27. The written file does not parse (a fault the test switches on after the
# write): the backup is put back, the row is FAIL, the exit code 1, no
# modification line, and the backup itself stays for the record.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write|NotebookEdit'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
EXTRA_ENV='ISS_INSTALL_FAULT=corrupt-settings'
run_install "$REPO"
expect_exit 1 "a settings.json that does not parse after the write exits 1"
expect_out_has '[FAIL] delegate-guard hook 的 PreToolUse matcher "Edit|Write|NotebookEdit" 缺 Bash，改后的 settings.json 不是合法 JSON，已用备份还原' "the row says the backup was restored"
expect_out_count 0 '已补为' "no modification line is printed"
expect_out_count 0 '[PASS] delegate-guard' "the failed fix is not a PASS line"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "the original is back byte for byte"
expect_backups 1 "the backup stays"
expect_backup_is "$CASE_DIR/settings.before" "the backup is the original file"
run_install "$REPO" --check
expect_exit 1 "--check after the restored file reports the matcher still lacking Bash"
expect_out_count 1 '缺 Bash' "--check after the restore reports the unmet item once"

# 28. A settings.json that is not JSON to begin with: not modified (no backup
# either), one FAIL row in both modes, exit code 1 -- the items are not judged.
new_case
make_repo "$CASE_DIR/repo" find-next
mkdir -p "$CASE_CLAUDE"
printf '{"hooks": {\n' > "$CASE_SETTINGS"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO"
expect_exit 1 "a settings.json that is not JSON exits 1"
expect_out_has '[FAIL] settings.json 不是合法 JSON，未改' "the row says settings.json was left alone"
expect_out_count 1 '[FAIL]' "one FAIL row for the file, none for an item"
expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "an unparseable settings.json is not modified"
expect_no_backups "an unparseable settings.json gets no backup"
run_install "$REPO" --check --json
expect_exit 1 "--check on an unparseable settings.json exits 1"
expect_json "the unparseable file is one FAIL error row and nothing else from the config segment" 'JSON.stringify(out.checks.filter(c => c.group === "config").map(c => c.level + ":" + c.status)) === JSON.stringify(["FAIL:error"]) && out.summary.fail === 1 && out.summary.changed === 0'
expect_json "the row names the file and how to go on" 'out.checks.filter(c => c.group === "config")[0].link === process.env.CASE_SETTINGS && out.checks.filter(c => c.group === "config")[0].hint.includes("install.sh")'

# 29. Two delegate-guard registrations: judged by the first one, the one
# doctor.sh judges; the fix goes to that one and the second is left as it is.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write'
node -e 'const fs = require("fs"); const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); o.hooks.PreToolUse.push({matcher: "Bash", hooks: [{type: "command", command: "node \"/fixture/hooks/delegate-guard.js\"", timeout: 5}]}); fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2) + "\n");' "$CASE_SETTINGS"
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
run_install "$REPO"
expect_exit 0 "two registrations: exit 0"
expect_settings "the first registration is fixed, the second kept" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|Bash" && now.hooks.PreToolUse[1].matcher === "Bash" && deepEqual({h: [orig.hooks.PreToolUse[1]]}, {h: [now.hooks.PreToolUse[1]]})'

# 30. Without ISS_CLAUDE_SETTINGS the settings file is
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json of the HOME the process was
# given (the file doctor.sh reads), and the backup goes beside it; nowhere else.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write|NotebookEdit' '  ' "$CASE_HOME/.claude/settings.json"
cp "$CASE_HOME/.claude/settings.json" "$CASE_DIR/settings.before"
run_install_default_location "$REPO"
expect_exit 0 "default settings location exits 0"
expect_out_has "配置文件：$CASE_HOME/.claude/settings.json" "the default settings location is \$HOME/.claude/settings.json"
expect_settings_at "$CASE_HOME/.claude/settings.json" "the default location is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|NotebookEdit|Bash"'
DEFAULT_BACKUP=$(ls -d "$CASE_HOME/.claude/backups"/install-* 2>/dev/null | head -n 1)
if [ -n "$DEFAULT_BACKUP" ] && cmp -s "$DEFAULT_BACKUP/settings.json" "$CASE_DIR/settings.before"; then
  record PASS "the backup goes beside the default settings file"
else
  record FAIL "the backup goes beside the default settings file" "$(ls -la "$CASE_HOME/.claude/backups" 2>&1 | head -c 200)"
fi
if [ -e "$CASE_CLAUDE" ]; then
  record FAIL "the default location does not look at the scratch ISS_CLAUDE_SETTINGS path" "$CASE_CLAUDE exists"
else
  record PASS "the default location does not look at the scratch ISS_CLAUDE_SETTINGS path"
fi
write_settings 'Edit|Write|NotebookEdit' '  ' "$CASE_DIR/cfg/settings.json"
cp "$CASE_DIR/cfg/settings.json" "$CASE_DIR/settings.before"
EXTRA_ENV="CLAUDE_CONFIG_DIR=$CASE_DIR/cfg"
run_install_default_location "$REPO"
expect_exit 0 "CLAUDE_CONFIG_DIR as the settings location exits 0"
expect_out_has "配置文件：$CASE_DIR/cfg/settings.json" "CLAUDE_CONFIG_DIR is honoured, as doctor.sh honours it"
expect_settings_at "$CASE_DIR/cfg/settings.json" "the settings file under CLAUDE_CONFIG_DIR is fixed" 'return now.hooks.PreToolUse[0].matcher === "Edit|Write|NotebookEdit|Bash"'

# 31. No backup, no change: when the backup directory cannot be made (the
# directory is read-only), settings.json is left alone and the row is FAIL.
# Root writes anywhere, so the case is skipped there.
new_case
make_repo "$CASE_DIR/repo" find-next
write_settings 'Edit|Write|NotebookEdit'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
if [ "$(id -u)" -eq 0 ]; then
  record PASS "a settings directory that cannot hold a backup exits 1" "(skipped: root writes anywhere)"
else
  chmod a-w "$CASE_CLAUDE"
  run_install "$REPO"
  expect_exit 1 "a settings directory that cannot hold a backup exits 1"
  expect_out_has '[FAIL] delegate-guard hook 的 PreToolUse matcher "Edit|Write|NotebookEdit" 缺 Bash，备份失败，未改' "the row says no backup could be made"
  expect_same_file "$CASE_SETTINGS" "$CASE_DIR/settings.before" "settings.json is left alone without a backup"
  chmod u+w "$CASE_CLAUDE"
  expect_no_backups "nothing was made beside it"
fi

# 32. Items the script cannot act on (fixture) each get a FAIL row saying why
# and do not stop the others: a wrong direction and an unknown check are
# errors, a tighten item without a known fix is unmet and left alone, and the
# well-formed item after them is still applied.
new_case
make_repo "$CASE_DIR/repo" find-next
cat > "$CASE_DIR/expectations.json" <<'JSON'
[
  {"id": "bad-direction", "direction": "both", "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "include": ["Bash"]}},
  {"id": "bad-check", "direction": "tighten", "check": {"type": "unknownCheck"}},
  {"id": "no-fix", "direction": "tighten", "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "include": ["Bash"]}, "fix": "remove-something"},
  {"id": "good", "direction": "tighten", "check": {"type": "preToolUseMatcher", "hook": "delegate-guard.js", "include": ["Bash"]}, "fix": "append-matcher-tools"}
]
JSON
write_settings 'Edit|Write'
cp "$CASE_SETTINGS" "$CASE_DIR/settings.before"
EXTRA_ENV="ISS_CONFIG_EXPECTATIONS_FILE=$CASE_DIR/expectations.json"
run_install "$REPO" --json
expect_exit 1 "unrecognised items leave the exit code at 1"
expect_json "each unrecognised item is its own FAIL row; the good one is applied" 'JSON.stringify(out.checks.filter(c => c.group === "config").map(c => c.level + ":" + c.status + ":" + c.name)) === JSON.stringify(["FAIL:error:bad-direction","FAIL:error:bad-check","FAIL:unmet:no-fix","PASS:tightened:good"])'
expect_json "the rows say why" 'out.checks[2].message.includes("无法识别：direction") && out.checks[3].message.includes("无法识别：未知的检查方式") && out.checks[4].message.includes("没有自动修正方法（未知的修正方式）") && out.checks[4].changed === false'
expect_settings "only the good item changed the file" 'orig.hooks.PreToolUse[0].matcher = "Edit|Write|Bash"; return deepEqual(orig, now)'
expect_backups 1 "one backup, for the one applied item"

# 33. An expectation list that cannot be read, or is not a JSON array, is a
# cannot-run condition: exit 2 before anything is made.
new_case
make_repo "$CASE_DIR/repo" find-next
EXTRA_ENV="ISS_CONFIG_EXPECTATIONS_FILE=$CASE_DIR/missing.json"
run_install "$REPO"
expect_exit 2 "an unreadable expectation list exits 2"
expect_err_has 'cannot read the expectation list' "an unreadable expectation list is named on stderr"
printf '{"id": "x"}\n' > "$CASE_DIR/expectations.json"
EXTRA_ENV="ISS_CONFIG_EXPECTATIONS_FILE=$CASE_DIR/expectations.json"
run_install "$REPO" --check
expect_exit 2 "an expectation list that is not an array exits 2"
expect_err_has 'not a JSON array' "an expectation list that is not an array is named on stderr"
if [ -e "$CASE_SKILLS" ] || [ -e "$CASE_CLAUDE" ]; then
  record FAIL "a bad expectation list makes nothing" "$(ls -la "$CASE_SKILLS" "$CASE_CLAUDE" 2>&1 | head -c 200)"
else
  record PASS "a bad expectation list makes nothing"
fi

# MAINTAINING registers the test in its self-test list.
if grep -Fq 'bash scripts/test-install.sh' "$MAINTAINING"; then
  record PASS 'MAINTAINING registers the test in its self-test list'
else
  record FAIL 'MAINTAINING registers the test in its self-test list'
fi

if [ "$FAILED" -eq 0 ]; then
  printf 'Summary: %d passed, 0 failed\n' "$PASSED"
else
  printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"
fi
exit "$FAILED"
