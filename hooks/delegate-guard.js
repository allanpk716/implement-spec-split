#!/usr/bin/env node

// Claude Code PreToolUse hook for Edit, Write, NotebookEdit, and Bash. In
// ordinary sessions it denies source-code changes larger than the configured
// limit (default: 10), while allowing invalid/failing input, configured file
// types, small edits, disabled projects, and a temporary override stored at
// <home>/.claude/state/allow-direct-edit. Flash sessions (FLASH_ORCHESTRATOR=1)
// instead deny every source-code write, including common Bash writes. The
// ordinary limit comes from the nearest .claude/delegate-guard.json above
// payload.cwd, DELEGATE_GUARD_LIMIT, or the default. Invalid input fails open;
// internal failures fail open and append an error to
// <home>/.claude/state/delegate-guard.log when that log is writable.

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const LIMIT = 10;
const TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'Bash']);
const FLASH_REASON =
  'flash 会话不写源码：派 glm-5.3 子代理（或 codex worker）。';
const TEXT_EXTENSIONS = new Set([
  '.md',
  '.txt',
  '.json',
  '.jsonc',
  '.yaml',
  '.yml',
  '.toml',
  '.ini',
  '.cfg',
  '.csv',
]);
const TEXT_FILENAMES = new Set(['.gitignore', '.gitattributes']);
const SOURCE_EXTENSIONS = new Set([
  '.ada',
  '.adb',
  '.asm',
  '.astro',
  '.bash',
  '.bat',
  '.bb',
  '.bazel',
  '.c',
  '.cc',
  '.clj',
  '.cljs',
  '.cmd',
  '.coffee',
  '.cpp',
  '.cs',
  '.css',
  '.cts',
  '.cu',
  '.cxx',
  '.dart',
  '.dockerfile',
  '.elixir',
  '.erl',
  '.ex',
  '.exs',
  '.fish',
  '.f90',
  '.for',
  '.go',
  '.groovy',
  '.gs',
  '.gsql',
  '.h',
  '.ha',
  '.hbs',
  '.hpp',
  '.hs',
  '.htm',
  '.html',
  '.hxx',
  '.ipynb',
  '.java',
  '.jl',
  '.js',
  '.jsonl',
  '.jsx',
  '.kt',
  '.kts',
  '.lua',
  '.m',
  '.mm',
  '.mts',
  '.nix',
  '.pas',
  '.php',
  '.pl',
  '.pm',
  '.ps1',
  '.py',
  '.r',
  '.rb',
  '.rs',
  '.sass',
  '.scala',
  '.scm',
  '.scss',
  '.sh',
  '.sql',
  '.svelte',
  '.swift',
  '.tf',
  '.ts',
  '.tsx',
  '.vue',
  '.wxl',
  '.wxi',
  '.xml',
  '.xsl',
  '.zsh',
]);
const MAX_PROJECT_CONFIG_LEVELS = 20;
const LOG_MAX_BYTES = 1024 * 1024;

function countLines(value) {
  if (typeof value !== 'string' || value === '') return 0;

  const normalized = value.replace(/\r\n/g, '\n');
  const parts = normalized.split('\n');
  if (parts[parts.length - 1] === '') parts.pop();
  return parts.length;
}

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    }) + '\n'
  );
}

function fileNameOf(filePath) {
  const normalized = String(filePath).replace(/\\/g, '/');
  const parts = normalized.split('/');
  return parts[parts.length - 1] || '';
}

function tokenizeShell(command) {
  const tokens = [];
  let current = '';
  let quoted = false;
  let currentStartsAt = 0;

  const flushWord = () => {
    if (current !== '') {
      tokens.push({
        text: current,
        quoted,
        startsAt: currentStartsAt,
        endsAt: currentStartsAt + current.length - 1,
      });
    }
    current = '';
    quoted = false;
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];
    if (character === '\'' || character === '"') {
      quoted = true;
      const closingQuote = command.indexOf(character, index + 1);
      if (closingQuote === -1) {
        current += command.slice(index + 1);
        break;
      }
      current += command.slice(index + 1, closingQuote);
      index = closingQuote;
      continue;
    }

    if (character === '\n' || character === '\r') {
      flushWord();
      tokens.push({ text: '\n', quoted: false });
      if (character === '\r' && command[index + 1] === '\n') {
        index += 1;
      }
      currentStartsAt = index + 1;
      continue;
    }

    if (/\s/.test(character)) {
      flushWord();
      currentStartsAt = index + 1;
      continue;
    }

    if ('<>|;&()'.includes(character)) {
      flushWord();
      currentStartsAt = index + 1;
      const next = command[index + 1];
      if (
        (character === '>' && next === '>') ||
        (character === '<' && next === '<') ||
        (character === '&' && next === '&') ||
        (character === '|' && next === '|')
      ) {
        tokens.push({
          text: character + next,
          quoted: false,
          startsAt: index,
          endsAt: index + 1,
        });
        index += 1;
      } else {
        tokens.push({
          text: character,
          quoted: false,
          startsAt: index,
          endsAt: index,
        });
      }
      continue;
    }

    current += character;
  }
  flushWord();
  return tokens;
}

function withoutHeredocBody(tokens) {
  const heredocIndex = tokens.findIndex(token => token.text === '<<');
  if (heredocIndex === -1) return tokens;

  const marker = tokens[heredocIndex + 1];
  if (!marker) return tokens;

  const bodyStart = tokens.findIndex(
    (token, index) =>
      index > heredocIndex + 1 &&
      token.text === '\n'
  );
  if (bodyStart === -1) return tokens;

  const bodyEnd = tokens.findIndex(
    (token, index) =>
      index > bodyStart &&
      token.text === marker.text &&
      tokens[index - 1].text === '\n'
  );
  return [
    ...tokens.slice(0, bodyStart + 1),
    ...(bodyEnd === -1 ? [] : tokens.slice(bodyEnd)),
  ];
}

function isSourceBashWrite(command) {
  const tokens = withoutHeredocBody(tokenizeShell(command));
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    const previous = index > 0 ? tokens[index - 1] : undefined;
    const isFdOrCombinedRedirect =
      previous !== undefined &&
      !previous.quoted &&
      previous.endsAt === token.startsAt - 1 &&
      (previous.text === '&' || /^\d+$/.test(previous.text));
    if (
      (token.text === '>' || token.text === '>>') &&
      !token.quoted &&
      !isFdOrCombinedRedirect &&
      index + 1 < tokens.length &&
      !tokens[index + 1].text.startsWith('&') &&
      isSourceFileName(tokens[index + 1].text)
    ) {
      return true;
    }

    if (token.text === 'tee') {
      for (let next = index + 1; next < tokens.length; next += 1) {
        const argument = tokens[next];
        if ('|;&()\n'.includes(argument.text[0])) break;
        if (
          !argument.text.startsWith('-') &&
          isSourceFileName(argument.text)
        ) {
          return true;
        }
      }
    }

    if (token.text === 'perl') {
      let hasInPlaceOption = false;
      let sawScriptOperand = false;
      let optionTakesValue = false;
      for (let next = index + 1; next < tokens.length; next += 1) {
        const argument = tokens[next];
        if ('|;&()<>\n'.includes(argument.text[0])) break;
        if (optionTakesValue) {
          optionTakesValue = false;
          sawScriptOperand = true;
          continue;
        }
        if (argument.text === '--') break;
        if (argument.text.startsWith('--')) {
          const [name] = argument.text.split('=', 2);
          if (name === '--in-place') hasInPlaceOption = true;
          continue;
        }
        if (argument.text.startsWith('-') && argument.text !== '-') {
          const optionCharacters = argument.text.slice(1).split(/[=:]/)[0];
          if (optionCharacters.includes('i')) hasInPlaceOption = true;
          if (/[en]/.test(optionCharacters)) optionTakesValue = true;
          continue;
        }
        if (!sawScriptOperand) {
          sawScriptOperand = true;
          continue;
        }
        if (hasInPlaceOption && isSourceFileName(argument.text)) return true;
      }
      continue;
    }

    if (token.text !== 'sed') continue;

    let hasInPlaceOption = false;
    let sawScriptOperand = false;
    let sawFileOperand = false;
    let optionTakesValue = false;
    for (let next = index + 1; next < tokens.length; next += 1) {
      const argument = tokens[next];
      if ('|;&()<>\n'.includes(argument.text[0])) break;
      if (optionTakesValue) {
        optionTakesValue = false;
        continue;
      }
      if (argument.text === '--') break;
      if (argument.text.startsWith('--')) {
        const [name] = argument.text.split('=', 2);
        if (name === '--in-place') hasInPlaceOption = true;
        if (
          (name === '--expression' || name === '--file') &&
          !argument.text.includes('=')
        ) {
          optionTakesValue = true;
        }
        continue;
      }
      if (
        argument.text.startsWith('-') &&
        argument.text !== '-'
      ) {
        const optionCharacters = argument.text.slice(1);
        if (optionCharacters.includes('i')) hasInPlaceOption = true;
        if (/[ef]$/.test(optionCharacters)) optionTakesValue = true;
        continue;
      }
      if (!sawScriptOperand) {
        sawScriptOperand = true;
        continue;
      }
      sawFileOperand = true;
      if (hasInPlaceOption && isSourceFileName(argument.text)) {
        return true;
      }
    }
    if (hasInPlaceOption && !sawFileOperand) return true;
  }
  return false;
}

function isSourceFileName(filePath) {
  const fileName = fileNameOf(filePath);
  if (TEXT_FILENAMES.has(fileName)) return false;
  const dot = fileName.lastIndexOf('.');
  if (dot <= 0) return false;
  return SOURCE_EXTENSIONS.has(fileName.slice(dot).toLowerCase());
}

function isAllowedFileName(filePath) {
  const fileName = fileNameOf(filePath);
  if (TEXT_FILENAMES.has(fileName)) return true;

  const dot = fileName.lastIndexOf('.');
  if (dot <= 0) return false;
  return TEXT_EXTENSIONS.has(fileName.slice(dot).toLowerCase());
}

function hasValidOverride(homeDir) {
  try {
    const overridePath = path.join(
      homeDir,
      '.claude',
      'state',
      'allow-direct-edit'
    );
    if (!fs.existsSync(overridePath)) return false;

    const raw = fs.readFileSync(overridePath, 'utf8').trim();
    const expiresAtMs = /^\d+$/.test(raw)
      ? Number(raw) * 1000
      : Date.parse(raw);
    return Number.isFinite(expiresAtMs) && expiresAtMs > Date.now();
  } catch (_error) {
    return false;
  }
}

function isPositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function parseLimitEnv(value) {
  if (!value || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return isPositiveInteger(parsed) ? parsed : null;
}

function readProjectConfig(cwd, log) {
  if (typeof cwd !== 'string' || cwd === '') return {};

  let current = path.resolve(cwd);
  for (let level = 0; level < MAX_PROJECT_CONFIG_LEVELS; level += 1) {
    const configPath = path.join(current, '.claude', 'delegate-guard.json');
    let exists = false;
    try {
      exists = fs.existsSync(configPath) || fs.statSync(configPath).isFile();
    } catch (_error) {
      exists = false;
    }

    if (exists) {
      try {
        const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (!config || typeof config !== 'object' || Array.isArray(config)) {
          throw new Error('invalid project config');
        }
        if (
          ('enabled' in config && typeof config.enabled !== 'boolean') ||
          ('limit' in config && !isPositiveInteger(config.limit))
        ) {
          throw new Error('invalid project config fields');
        }
        return config;
      } catch (error) {
        log(
          'warn',
          `ignore invalid project config ${configPath}: ${
            error instanceof Error ? error.message : String(error)
          }`
        );
      }
    }

    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return {};
}

function makeLogger(homeDir) {
  return (level, message) => {
    try {
      const dir = path.join(homeDir, '.claude', 'state');
      fs.mkdirSync(dir, { recursive: true });
      const logPath = path.join(dir, 'delegate-guard.log');
      try {
        if (fs.statSync(logPath).size >= LOG_MAX_BYTES) {
          fs.writeFileSync(logPath, '');
        }
      } catch (_error) {
        // A missing log is created by the append below.
      }
      fs.appendFileSync(logPath, `${new Date().toISOString()} ${level} ${message}\n`);
    } catch (_error) {
      // Logging must never change the hook's fail-open behavior.
    }
  };
}

function main() {
  let parsedInput = false;
  let input;
  let payload;
  try {
    input = fs.readFileSync(0, 'utf8');
    payload = JSON.parse(input);
    parsedInput = true;
    if (!TOOLS.has(payload.tool_name)) return;

    const toolInput = payload.tool_input;
    if (!toolInput || typeof toolInput !== 'object') return;

    const flashMode = process.env.FLASH_ORCHESTRATOR === '1';
    if (payload.tool_name === 'Bash') {
      if (!flashMode) return;
      const command = toolInput.command;
      if (typeof command !== 'string' || command === '') return;
      if (isSourceBashWrite(command)) deny(FLASH_REASON);
      return;
    }

    const filePath =
      payload.tool_name === 'NotebookEdit'
        ? toolInput.notebook_path
        : toolInput.file_path;
    if (typeof filePath !== 'string' || filePath === '') return;

    if (flashMode) {
      if (isSourceFileName(filePath)) deny(FLASH_REASON);
      return;
    }

    const homeDir = process.env.DELEGATE_GUARD_HOME || os.homedir();
    const log = makeLogger(homeDir);
    if (hasValidOverride(homeDir)) return;
    // Sessions without a delegation budget (e.g. claude-glm) opt out entirely.
    if (process.env.DELEGATE_GUARD_DISABLE === '1') return;

    const projectConfig = readProjectConfig(payload.cwd, log);
    if (projectConfig.enabled === false) return;

    if (isAllowedFileName(filePath)) return;

    let lineCount;
    if (payload.tool_name === 'Edit') {
      lineCount = Math.max(
        countLines(toolInput.old_string),
        countLines(toolInput.new_string)
      );
    } else if (payload.tool_name === 'Write') {
      lineCount = countLines(toolInput.content);
    } else {
      lineCount = countLines(toolInput.new_source);
    }

    const limit =
      typeof projectConfig.limit === 'number'
        ? projectConfig.limit
        : parseLimitEnv(process.env.DELEGATE_GUARD_LIMIT) || LIMIT;
    if (lineCount <= limit) return;

    const reason =
      process.env.DELEGATE_GUARD_LANG === 'en'
        ? `${payload.tool_name} change to source file ${fileNameOf(
            filePath
          )} counts as ${lineCount} lines, exceeding the limit of ${limit} lines; ` +
          `source changes over ${limit} lines should be written as a Brief for a codex worker ` +
          `(see the Opus / codex division in global CLAUDE.md); an exception may only be enabled with explicit user authorization.`
        : `${payload.tool_name} 对源码文件 ${fileNameOf(filePath)} 的修改计算为 ${lineCount} 行，` +
          `超过阈值 ${limit} 行；超过 ${limit} 行的源码修改按规则应写 Brief 交给 codex worker` +
          `（见全局 CLAUDE.md 的 Opus / codex 分工）；只有用户明确授权时才可开例外。`;
    deny(reason);
  } catch (error) {
    // Fail open so the guard cannot block a Claude Code session.
    if (parsedInput) {
      makeLogger(process.env.DELEGATE_GUARD_HOME || os.homedir())(
        'error',
        `delegate-guard failed open: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }
}

main();
