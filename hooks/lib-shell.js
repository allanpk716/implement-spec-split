'use strict';

// Shared shell-command lexing for Claude Code PreToolUse hooks.
// The tokenizer is intentionally small: it only understands the constructs the
// hooks need (words, quotes, redirections, command separators, heredocs). It is
// not a shell parser. Anything it does not understand fails open in the caller.

const SHELL_COMMAND_SEPARATORS = new Set([
  '|',
  '||',
  ';',
  '&&',
  '&',
  '(',
  ')',
  '\n',
]);

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

function isCommandSeparator(token) {
  return !token.quoted && SHELL_COMMAND_SEPARATORS.has(token.text);
}

function isRedirectionToken(token) {
  return !token.quoted && /^\d*[<>]+$/.test(token.text);
}

function baseNameOf(value) {
  const normalized = String(value).replace(/\\/g, '/');
  const parts = normalized.split('/');
  return parts[parts.length - 1] || '';
}

// Visit every command position in a token list. A command position is the
// start of a command, or the token after a command separator, with env
// assignments, env/nohup/time, timeout <n>, and redirections skipped.
// visit(commandToken, argsStart, argsEnd) receives the command token and the
// half-open argument range; returning false stops the scan.
function forEachCommandPosition(tokens, visit) {
  let index = 0;
  while (index < tokens.length) {
    let cursor = index;
    let commandToken;
    while (cursor < tokens.length) {
      const token = tokens[cursor];
      if (isCommandSeparator(token)) break;
      if (isRedirectionToken(token)) {
        cursor += 1;
        const target = tokens[cursor];
        if (
          target &&
          !isCommandSeparator(target) &&
          !isRedirectionToken(target) &&
          !target.text.startsWith('&')
        ) {
          cursor += 1;
        }
        continue;
      }
      if (
        !token.quoted &&
        (/^[A-Za-z_][A-Za-z0-9_]*=/.test(token.text) ||
          token.text === 'env' ||
          token.text === 'nohup' ||
          token.text === 'time')
      ) {
        cursor += 1;
        continue;
      }
      if (!token.quoted && token.text === 'timeout') {
        cursor += 1;
        if (
          cursor < tokens.length &&
          !isCommandSeparator(tokens[cursor]) &&
          !isRedirectionToken(tokens[cursor])
        ) {
          cursor += 1;
        }
        continue;
      }
      commandToken = token;
      break;
    }

    const argsStart = commandToken === undefined ? cursor : cursor + 1;
    let end = argsStart;
    while (end < tokens.length && !isCommandSeparator(tokens[end])) {
      end += 1;
    }
    if (
      commandToken !== undefined &&
      visit(commandToken, argsStart, end) === false
    ) {
      return;
    }
    index = end + 1;
  }
}

module.exports = {
  tokenizeShell,
  withoutHeredocBody,
  isCommandSeparator,
  isRedirectionToken,
  baseNameOf,
  forEachCommandPosition,
};
