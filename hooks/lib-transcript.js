'use strict';

// Shared transcript scanning for Claude Code PreToolUse hooks.
// A transcript is JSONL with one JSON object per line. Slash-command calls are
// user entries whose message content contains a <command-name> tag. Scanning is
// chunked so a multi-megabyte transcript stays well under a second, and callers
// fail open when the file is missing, unreadable, or contains a bad line.

const fs = require('fs');
const { StringDecoder } = require('string_decoder');

const COMMAND_NAME = '/implement-spec-split';
const COMMAND_NAME_TAG = `<command-name>${COMMAND_NAME}</command-name>`;
const COMMAND_MARKER = `${COMMAND_NAME}</command-name>`;
const AUTO_LAND_FLAG = '--auto-land';
const CHUNK_SIZE = 1024 * 1024;

// Extract the text of a user message from one transcript line. Returns null
// when the line is not JSON, not a user entry, or has no usable text content.
function userTextFromLine(line) {
  let entry;
  try {
    entry = JSON.parse(line);
  } catch (_error) {
    return null;
  }
  if (entry === null || typeof entry !== 'object') return null;
  if (entry.type !== 'user') return null;

  const message = entry.message;
  if (message === null || typeof message !== 'object') return null;

  const content = message.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    const parts = [];
    for (const item of content) {
      if (
        item !== null &&
        typeof item === 'object' &&
        item.type === 'text' &&
        typeof item.text === 'string'
      ) {
        parts.push(item.text);
      }
    }
    return parts.join('\n');
  }
  return null;
}

// Extract the text of an assistant message from one transcript line: the
// message content when it is a plain string, otherwise the last text block.
// Entries copied from a subagent (isSidechain) are skipped so a subagent's
// question does not count as the main agent's last message. Returns null when
// the line is not an assistant entry or has no text block at all.
function assistantTextFromLine(line) {
  if (!line.includes('assistant')) return null;
  let entry;
  try {
    entry = JSON.parse(line);
  } catch (_error) {
    return null;
  }
  if (entry === null || typeof entry !== 'object') return null;
  if (entry.type !== 'assistant') return null;
  if (entry.isSidechain === true) return null;

  const message = entry.message;
  if (message === null || typeof message !== 'object') return null;

  const content = message.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return null;

  let text = null;
  for (const item of content) {
    if (
      item !== null &&
      typeof item === 'object' &&
      item.type === 'text' &&
      typeof item.text === 'string'
    ) {
      text = item.text;
    }
  }
  return text;
}

// True when the command-args of an /implement-spec-split call contain the
// --auto-land flag as a whole word.
function hasAutoLandFlag(args) {
  if (typeof args !== 'string') return false;
  return args.split(/\s+/).some(token => token === AUTO_LAND_FLAG);
}

// From one transcript line, return the <command-args> of an
// /implement-spec-split invocation, or null when the line is not one.
function commandArgsFromLine(line) {
  if (!line.includes(COMMAND_MARKER)) return null;
  const text = userTextFromLine(line);
  if (text === null || !text.includes(COMMAND_NAME_TAG)) return null;
  const match = text.match(/<command-args>([\s\S]*?)<\/command-args>/);
  if (match === null) return null;
  return match[1];
}

// True when the line is a user entry that invokes /implement-spec-split.
// Unlike commandArgsFromLine this does not require <command-args>, so a call
// with no arguments still counts.
function isCommandInvocationLine(line) {
  if (!line.includes(COMMAND_MARKER)) return false;
  const text = userTextFromLine(line);
  return text !== null && text.includes(COMMAND_NAME_TAG);
}

// Read a JSONL transcript in chunks and call onLine for every complete line.
// Return false from onLine to stop early. Returns false only when the file
// cannot be opened; bad lines are the caller's concern.
function scanTranscript(transcriptPath, onLine) {
  let fileDescriptor;
  try {
    fileDescriptor = fs.openSync(transcriptPath, 'r');
  } catch (_error) {
    return false;
  }

  const buffer = Buffer.alloc(CHUNK_SIZE);
  const decoder = new StringDecoder('utf8');
  let remainder = '';
  let stopped = false;

  const consume = data => {
    const lines = (remainder + data).split('\n');
    remainder = lines.pop();
    for (const line of lines) {
      if (onLine(line) === false) {
        stopped = true;
        break;
      }
    }
  };

  try {
    let bytesRead;
    while (
      !stopped &&
      (bytesRead = fs.readSync(
        fileDescriptor,
        buffer,
        0,
        CHUNK_SIZE,
        null
      )) > 0
    ) {
      consume(decoder.write(buffer.subarray(0, bytesRead)));
    }
    if (!stopped) {
      const tail = decoder.end();
      if (tail !== '') remainder += tail;
      if (remainder !== '') onLine(remainder);
    }
  } finally {
    fs.closeSync(fileDescriptor);
  }
  return true;
}

// Return the <command-args> of the last /implement-spec-split call, or null.
function readLastCommandArgs(transcriptPath) {
  let lastArgs = null;
  scanTranscript(transcriptPath, line => {
    const args = commandArgsFromLine(line);
    if (args !== null) lastArgs = args;
    return true;
  });
  return lastArgs;
}

// True when the transcript contains at least one /implement-spec-split call.
// Stops at the first match so a large transcript is not fully parsed.
function hasCommandInvocation(transcriptPath) {
  let found = false;
  scanTranscript(transcriptPath, line => {
    if (isCommandInvocationLine(line)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

// Return the text of the last assistant message in the transcript, or null
// when the transcript has no assistant text. The last assistant entry decides,
// even when it only contains tool_use or thinking blocks (then the answer is
// null: that message is not talking to the user).
function readLastAssistantText(transcriptPath) {
  let lastText = null;
  let sawAssistant = false;
  scanTranscript(transcriptPath, line => {
    if (!line.includes('assistant')) return true;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (_error) {
      return true;
    }
    if (entry === null || typeof entry !== 'object') return true;
    if (entry.type !== 'assistant' || entry.isSidechain === true) return true;
    sawAssistant = true;
    lastText = assistantTextFromLine(line);
    return true;
  });
  return sawAssistant ? lastText : null;
}

// True when the transcript contains at least one Bash tool_use whose command
// contains `needle`. Stops at the first match; a missing or unreadable
// transcript answers false. Subagent (isSidechain) entries are skipped.
function hasBashCommandContaining(transcriptPath, needle) {
  if (typeof needle !== 'string' || needle === '') return false;
  let found = false;
  scanTranscript(transcriptPath, line => {
    if (!line.includes('Bash')) return true;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (_error) {
      return true;
    }
    if (entry === null || typeof entry !== 'object') return true;
    if (entry.type !== 'assistant' || entry.isSidechain === true) return true;
    const content = entry.message && entry.message.content;
    if (!Array.isArray(content)) return true;
    for (const item of content) {
      if (
        item === null ||
        typeof item !== 'object' ||
        item.type !== 'tool_use' ||
        item.name !== 'Bash'
      ) {
        continue;
      }
      const command = item.input && item.input.command;
      if (typeof command === 'string' && command.includes(needle)) {
        found = true;
        return false;
      }
    }
    return true;
  });
  return found;
}

module.exports = {
  hasAutoLandFlag,
  readLastCommandArgs,
  readLastAssistantText,
  hasBashCommandContaining,
  hasCommandInvocation,
};
