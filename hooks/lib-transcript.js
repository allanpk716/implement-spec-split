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

module.exports = {
  readLastCommandArgs,
  hasCommandInvocation,
};
