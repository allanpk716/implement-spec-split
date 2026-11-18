#!/usr/bin/env bash
# Generate an isolated Codex home for External workers from an interactive home.
#
# Usage: setup-worker-home.sh [--from <source-home>] [--to <worker-home>]
#
# Only worker-relevant model, provider, MCP, and agents configuration is copied. Values are
# never printed; the script reports dropped key/table names and paths only.

set -u

die() { echo "setup-worker-home: $*" >&2; exit 64; }

winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

FROM="${HOME:-}/.codex"
TO="${CODEX_WORKER_HOME:-${HOME:-}/.codex-worker}"
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ "${2+x}" = x ] || die "--from needs a directory"
      FROM="$2"; shift 2 ;;
    --to)
      [ "${2+x}" = x ] || die "--to needs a directory"
      TO="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v node >/dev/null || die "node not found on PATH"
[ -n "$FROM" ] || die "--from must not be empty"
[ -n "$TO" ] || die "--to must not be empty"
[ -f "$FROM/config.toml" ] || die "source config.toml not found under: $FROM"

FROM=$(cd "$FROM" && pwd -P) || die "cannot enter source home: $FROM"
mkdir -p "$TO" || die "cannot create worker home: $TO"
TO=$(cd "$TO" && pwd -P) || die "cannot enter worker home: $TO"
[ "$FROM" != "$TO" ] || die "--to must differ from --from"

umask 077
TMP_CONFIG="$TO/.config.toml.$$"
SOURCE_CONFIG="$FROM/config.toml"
TARGET_CONFIG="$TO/config.toml"
DROPPED=""
if ! DROPPED=$(FROM_HOME="$(winpath "$FROM")" TO_HOME="$(winpath "$TO")" USER_HOME="$(winpath "${HOME:-}")" node -e '
  const fs = require("fs");
  const path = require("path");
  const source = process.argv[1], output = process.argv[2];
  const rootKeys = new Set(["model_provider", "model", "model_reasoning_effort", "model_catalog_json"]);
  const keptNamespaces = new Set(["model_providers", "mcp_servers", "agents"]);
  const dropped = [];
  const droppedOnce = name => {
    if (!dropped.includes(name)) dropped.push(name);
  };
  const firstHeaderKey = text => {
    text = text.trim();
    if (!text) return "";
    const quote = text[0];
    if (quote === String.fromCharCode(39) || quote === "\"") {
      for (let i = 1; i < text.length; i++) {
        if (quote === "\"" && text[i] === "\\") { i++; continue; }
        if (text[i] === quote) {
          const raw = text.slice(0, i + 1);
          if (quote === "\"") {
            try { return JSON.parse(raw); } catch { return text.slice(1, i); }
          }
          return text.slice(1, i);
        }
      }
      return text;
    }
    const match = text.match(/^[A-Za-z0-9_-]+/);
    return match ? match[0] : "";
  };
  const headerText = line => {
    const value = line.trim();
    if (value.startsWith("[[")) {
      return value.endsWith("]]") ? value.slice(2, -2) : "";
    }
    return value.startsWith("[") && value.endsWith("]") ? value.slice(1, -1) : "";
  };
  const assignmentKey = line => firstHeaderKey(line.slice(0, line.indexOf("=")).trim());
  const assignmentName = line => line.slice(0, line.indexOf("=")).trim();
  const stringValue = text => {
    const match = text.trim().match(/^("((?:\\.|[^"\\])*)"|\x27([^\x27]*)\x27)(?:\s*(?:#.*)?)?$/);
    if (!match) return null;
    if (match[1].startsWith("\"")) {
      try { return JSON.parse(match[1]); } catch { return match[2]; }
    }
    return match[3];
  };
  const catalogLine = line => {
    const at = line.indexOf("=");
    const value = stringValue(line.slice(at + 1));
    if (value === null) return line;
    const from = path.resolve(process.env.FROM_HOME);
    let absolute;
    if (value === "~") {
      absolute = path.resolve(from);
    } else if (value.startsWith("~/")) {
      const suffix = value.slice(2);
      const home = process.env.USER_HOME || "";
      const viaHome = home ? path.resolve(home, suffix) : path.resolve(value);
      const viaSource = path.resolve(from, suffix.replace(/^\.codex(?:\/|$)/, ""));
      const inside = candidate => {
        const relative = path.relative(from, candidate);
        return !!relative && !relative.startsWith("..") && !path.isAbsolute(relative);
      };
      absolute = [viaHome, viaSource].find(inside) || viaHome;
    } else {
      absolute = path.resolve(value);
    }
    const relative = path.relative(from, absolute);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return line;
    let catalog = path.join(path.resolve(process.env.TO_HOME), relative);
    if (process.platform === "win32") catalog = catalog.replace(/\\/g, "/");
    return `model_catalog_json = ${JSON.stringify(catalog)}`;
  };

  let text;
  try { text = fs.readFileSync(source, "utf8"); }
  catch (err) { console.error("cannot read source config.toml: " + err.message); process.exit(1); }
  if (text && !text.endsWith("\n")) text += "\n";
  const out = [];
  let inRoot = true;
  let keeping = true;
  for (const line of text.split(/(?<=\n)/)) {
    const body = line.replace(/\r?\n$/, "");
    if (/^\s*\[\[?/.test(body)) {
      const name = headerText(body);
      const namespace = firstHeaderKey(name);
      inRoot = false;
      keeping = keptNamespaces.has(namespace);
      if (!keeping) droppedOnce(name.trim());
      if (keeping) out.push(line);
      continue;
    }
    if (inRoot) {
      if (!body.trim() || /^\s*(?:#|$)/.test(body)) { out.push(line); continue; }
      const key = assignmentKey(body);
      if (!rootKeys.has(key)) { droppedOnce(assignmentName(body)); continue; }
      out.push(key === "model_catalog_json" ? catalogLine(body) + "\n" : line);
      continue;
    }
    if (keeping) out.push(line);
  }
  try { fs.writeFileSync(output, out.join("")); }
  catch (err) { console.error("cannot write generated config.toml: " + err.message); process.exit(1); }
  if (dropped.length) console.log(dropped.join("\n"));
' "$(winpath "$SOURCE_CONFIG")" "$(winpath "$TMP_CONFIG")"); then
  rm -f "$TMP_CONFIG"
  die "could not generate worker config.toml"
fi

if [ ! -f "$TARGET_CONFIG" ]; then
  chmod 600 "$TMP_CONFIG"
  mv "$TMP_CONFIG" "$TARGET_CONFIG" || die "could not install config.toml"
elif cmp -s "$TARGET_CONFIG" "$TMP_CONFIG"; then
  rm -f "$TMP_CONFIG"
  chmod 600 "$TARGET_CONFIG"
else
  BACKUP="$TO/config.toml.bak-$(date +%Y%m%dT%H%M%S%z)-$$"
  cp "$TARGET_CONFIG" "$BACKUP" || { rm -f "$TMP_CONFIG"; die "could not back up config.toml"; }
  chmod 600 "$TMP_CONFIG"
  mv "$TMP_CONFIG" "$TARGET_CONFIG" || die "could not replace config.toml"
fi

if [ -n "$DROPPED" ]; then printf '%s\n' "$DROPPED"; fi
[ -f "$FROM/models.json" ] && cp "$FROM/models.json" "$TO/models.json"
[ -f "$FROM/AGENTS.md" ] && cp "$FROM/AGENTS.md" "$TO/AGENTS.md"
if [ -d "$FROM/skills/ssh-manager" ]; then
  mkdir -p "$TO/skills" || die "could not create skills directory"
  cp -R "$FROM/skills/ssh-manager" "$TO/skills/" || die "could not copy ssh-manager skill"
fi
mkdir -p "$TO/sessions" || die "could not create sessions directory"
