#!/usr/bin/env bash
# Isolated integration tests for install.sh, the skill-symlink segment (规格 #58
# 票 #63). Every run gets a scratch HOME and ISS_SKILLS_DIR, so the real
# ~/.claude is never read or written; most cases run a copy of install.sh from a
# scratch git checkout, so they control which skills exist and where. Only
# outside behaviour is checked: stdout, the exit code, the links and where they
# point.

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
# HOME and ISS_SKILLS_DIR; stdout in install.out, stderr in install.err, the
# status in RUN_EXIT.
run_install() {
  local repo=$1
  shift
  env HOME="$CASE_HOME" ISS_SKILLS_DIR="$CASE_SKILLS" PATH="$CASE_BIN:$PATH" \
    bash "$repo/install.sh" "$@" > "$CASE_DIR/install.out" 2> "$CASE_DIR/install.err"
  RUN_EXIT=$?
}

# The same without ISS_SKILLS_DIR: the default location is $HOME/.claude/skills.
run_install_default_location() { # checkout
  env -u ISS_SKILLS_DIR HOME="$CASE_HOME" PATH="$CASE_BIN:$PATH" \
    bash "$1/install.sh" > "$CASE_DIR/install.out" 2> "$CASE_DIR/install.err"
  RUN_EXIT=$?
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

# expect_json <name> <js predicate over the parsed stdout `out`>; CASE_SKILLS
# and REPO are passed in the environment.
expect_json() {
  local name=$1 js=$2
  if OUT_FILE=$CASE_DIR/install.out JS="$js" CASE_SKILLS="$CASE_SKILLS" REPO="${REPO:-}" node -e '
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
new_case
make_repo "$CASE_DIR/repo" find-next grill-router
run_install "$REPO" --json
expect_exit 0 "fixture install with --json exits 0"
expect_lines 1 "--json prints exactly one line"
expect_json "the object has the top-level keys in a fixed order" 'Object.keys(out).join(",") === "mode,windows,mainCheckout,skillsDir,checks,summary"'
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
INSTALLED=$(cat "$CASE_DIR/install.out")
run_install "$REPO" --json
if [ "$(cat "$CASE_DIR/install.out")" = "$INSTALLED" ]; then
  record PASS "two install --json runs on an installed state print the same object"
else
  record FAIL "two install --json runs on an installed state print the same object" "first=$INSTALLED second=$(cat "$CASE_DIR/install.out")"
fi
expect_json "the keys are the same as in the other modes" 'Object.keys(out).join(",") === "mode,windows,mainCheckout,skillsDir,checks,summary" && Object.keys(out.summary).join(",") === "pass,warn,fail,info,changed,drift" && out.checks.every(c => Object.keys(c).join(",") === "group,level,status,changed,name,dir,link,target,message,hint")'
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
# directory is found, and the link is named after the frontmatter name rather
# than the directory; a file that is merely named like a skill file is not one.
new_case
make_repo "$CASE_DIR/repo" find-next
write_skill "$REPO/wrappers/feature" grill-feature
write_skill "$REPO/brand-new" brand-new
mkdir -p "$REPO/upstream"
printf -- '---\nname: not-a-skill\n---\n' > "$REPO/upstream/implement-spec.SKILL.md"
git -C "$REPO" add -A
run_install "$REPO" --json
expect_exit 0 "a checkout with a nested and a new skill exits 0"
expect_json "a nested skill and a new one are linked by their frontmatter names" 'JSON.stringify(out.checks.map(c => c.name + "=" + c.dir)) === JSON.stringify(["implement-spec-split=.","brand-new=brand-new","find-next=find-next","grill-feature=wrappers/feature"])'
expect_link "$CASE_SKILLS/grill-feature" "$REPO/wrappers/feature" "nested skill links to its directory"
expect_link "$CASE_SKILLS/brand-new" "$REPO/brand-new" "new skill is linked without a script change"
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
