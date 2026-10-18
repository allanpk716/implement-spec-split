#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
if (process.env.FAKE_CODEX_ARGS_LOG) {
  fs.appendFileSync(process.env.FAKE_CODEX_ARGS_LOG, JSON.stringify(args) + "\n");
}
if (process.env.FAKE_CODEX_PID_LOG) {
  fs.appendFileSync(process.env.FAKE_CODEX_PID_LOG, process.pid + "\n");
}

let output = "";
for (let i = 0; i < args.length; i++) if (args[i] === "-o" && args[i + 1]) output = args[++i];
let stdin = "";
try { stdin = fs.readFileSync(0, "utf8"); } catch {}

const runDir = output ? path.dirname(output) : ".";
const counterFile = path.join(runDir, "fake-codex-counter");
let count = 0;
try { count = +fs.readFileSync(counterFile, "utf8") || 0; } catch {}
count++;
fs.writeFileSync(counterFile, String(count));

const id = `01a14a0a-4a09-7901-9ebf-af248bdb9${String(1000 + count).slice(-4)}`;
const thread = {type: "thread.started", thread_id: id};
const warning = {type: "item.completed", item: {type: "error", message: "Codex is ignoring 1 unrecognized configuration setting"}};
const emit = events => { for (const e of events) console.log(JSON.stringify(e)); };
const wrappedCommand = String.raw`"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command 'npm test'`;
const command = n => [
  {type: "item.started", item: {id: `item_${n}`, type: "command_execution", command: wrappedCommand, aggregated_output: "", exit_code: null, status: "in_progress"}},
  {type: "item.completed", item: {id: `item_${n}`, type: "command_execution", command: wrappedCommand, aggregated_output: "ok", exit_code: 0, status: "completed"}},
];
const finish = (text = "done") => [
  {type: "item.completed", item: {id: "item_15", type: "file_change", changes: [{path: "C:\\x\\add.js", kind: "update"}], status: "completed"}},
  {type: "item.completed", item: {id: "item_3", type: "agent_message", text}},
  {type: "turn.completed", usage: {input_tokens: 100, cached_input_tokens: 0, output_tokens: 10, reasoning_output_tokens: 0}},
];
const cwdArg = (() => { for (let i = 0; i < args.length; i++) if (args[i] === "-C" && args[i + 1]) return args[++i]; return ""; })();
const mutationTarget = process.env.FAKE_CODEX_TARGET || "tracked.txt";
const mutateWorkspace = kind => {
  if (!cwdArg) throw new Error("fake codex mutation scenario requires -C");
  const target = path.join(cwdArg, mutationTarget);
  if (kind === "untracked") fs.writeFileSync(target, "untracked\n");
  else {
    fs.appendFileSync(target, "changed by fake codex\n");
    if (kind === "commit") {
      const git = (commandArgs, check = true) => {
        const result = require("child_process").spawnSync("git", commandArgs, {cwd: cwdArg, encoding: "utf8"});
        if (check && result.status !== 0) throw new Error(result.stderr);
        return result;
      };
      git(["add", "--", mutationTarget]);
      git(["commit", "-m", "fake codex commit"]);
    }
  }
};
const failed = message => ({type: "turn.failed", error: {message}});
const rollout = () => {
  const home = process.env.CODEX_HOME || path.join(process.env.HOME || ".", ".codex");
  const dir = path.join(home, "sessions", "2026", "01", "01");
  fs.mkdirSync(dir, {recursive: true});
  fs.writeFileSync(path.join(dir, `rollout-${id}.jsonl`), JSON.stringify(thread) + "\n");
};
const fail = message => { rollout(); emit([thread, warning, failed(message)]); };

const scenario = process.env.FAKE_CODEX_SCENARIO || "ok";
if (scenario === "ok") {
  rollout(); emit([thread, warning, ...command(4), ...finish()]); fs.writeFileSync(output, "done\n");
} else if (scenario === "401") {
  fail("unexpected status 401 Unauthorized: 身份验证失败");
} else if (scenario === "429-then-ok") {
  if (count <= 2) fail("exceeded retry limit, last status: 429 Too Many Requests");
  else { rollout(); emit([thread, warning, ...finish("done after retry")]); fs.writeFileSync(output, "done after retry\n"); }
} else if (scenario === "429-forever") {
  fail("exceeded retry limit, last status: 429 Too Many Requests");
} else if (scenario === "network-wait") {
  rollout(); emit([thread, warning]);
  setInterval(() => emit([{type: "error", message: "Reconnecting... waiting for network (Connection failed: error sending request)"}]), 500);
} else if (scenario === "reconnect-only") {
  rollout(); emit([thread, warning]);
  setInterval(() => emit([{type: "error", message: "Reconnecting... 1/5 (unexpected status 500)"}]), 500);
} else if (scenario === "silent") {
  rollout(); setInterval(() => {}, 1000);
} else if (scenario === "busy-forever") {
  rollout(); emit([thread, warning]);
  let n = 10;
  setInterval(() => emit([{type: `turn.progress.${n++}`}]), 1000);
} else if (scenario === "answered-not-completed") {
  rollout(); emit([thread, warning, ...command(4), {type: "item.completed", item: {id: "item_3", type: "agent_message", text: "final answer"}}]);
  setInterval(() => {}, 1000);
} else if (scenario === "commentary-then-hang") {
  rollout();
  emit([
    thread, warning,
    {type: "item.completed", item: {id: "item_3", type: "agent_message", text: "I'm checking X before making changes."}},
    {type: "item.started", item: {id: "item_20", type: "command_execution", command: "npm test", aggregated_output: "", exit_code: null, status: "in_progress"}},
  ]);
  setInterval(() => {}, 1000);
} else if (scenario === "grandchild") {
  rollout(); emit([thread, warning]);
  const marker = process.env.FAKE_CODEX_GRANDCHILD_MARKER || "";
  const child = require("child_process").spawn(process.execPath, ["-e", "setTimeout(()=>{},300000)"], {detached: false, stdio: "ignore"});
  if (marker) fs.writeFileSync(marker, String(child.pid));
  setInterval(() => {}, 1000);
} else if (scenario === "stdin-echo") {
  rollout(); emit([thread, warning, {type: "item.completed", item: {id: "item_3", type: "agent_message", text: stdin}}, ...finish(stdin)]);
  fs.writeFileSync(output, stdin);
} else if (scenario === "read-only-clean") {
  rollout(); emit([thread, warning, ...command(4), ...finish()]);
  fs.writeFileSync(output, "done\n");
} else if (scenario === "read-only-tracked" || scenario === "read-only-dirty-more") {
  mutateWorkspace("tracked"); rollout(); emit([thread, warning, ...finish()]);
  fs.writeFileSync(output, "done\n");
} else if (scenario === "read-only-untracked") {
  mutateWorkspace("untracked"); rollout(); emit([thread, warning, ...finish()]);
  fs.writeFileSync(output, "done\n");
} else if (scenario === "read-only-commit") {
  mutateWorkspace("commit"); rollout(); emit([thread, warning, ...finish()]);
  fs.writeFileSync(output, "done\n");
} else {
  console.error(`unknown FAKE_CODEX_SCENARIO: ${scenario}`); process.exit(2);
}
