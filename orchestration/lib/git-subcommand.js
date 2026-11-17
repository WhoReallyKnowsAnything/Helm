#!/usr/bin/env node
// git-subcommand.js: read a shell command on stdin, print "commit" or "push" when
// it runs that git subcommand, else print nothing. Used by git-approval-gate.sh.
//
// The subcommand is the first non-option word after a `git` word, so
// `git stash push` and `git log --grep push` are not pushes. Anything unparsable
// or unresolved (`git $SUB`, an alias set with -c) prints "push": the gate holds
// it. Quoted text is scanned again as a command (`bash -c "git push"`).

const MAX_DEPTH = 4;
// Global options whose value is the next word.
const TAKES_VALUE = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace',
  '--super-prefix', '--config-env', '--attr-source', '--exec-path']);

// Split into segments (on ; & | ( ) ` newline outside quotes) of words. Quoted
// text stays one word and is also returned in `quoted` for a second scan.
function parse(cmd) {
  const segs = [[]];
  const quoted = [];
  let word = null;
  const endWord = () => { if (word !== null) { segs[segs.length - 1].push(word); word = null; } };
  const endSeg = () => { endWord(); if (segs[segs.length - 1].length) segs.push([]); };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === "'" || c === '"') {
      const end = (() => {
        for (let j = i + 1; j < cmd.length; j++) {
          if (c === '"' && cmd[j] === '\\') { j++; continue; }
          if (cmd[j] === c) return j;
        }
        return cmd.length; // unterminated: take the rest
      })();
      const inner = cmd.slice(i + 1, end);
      quoted.push(inner);
      word = (word || '') + inner;
      i = end;
    } else if (c === '\\') {
      word = (word || '') + (cmd[++i] || '');
    } else if (/\s/.test(c) && c !== '\n') {
      endWord();
    } else if (';&|()`\n'.includes(c)) {
      endSeg();
    } else {
      word = (word || '') + c;
    }
  }
  endSeg();
  return { segs, quoted };
}

function subcommand(words) {
  for (let i = 0; i < words.length; i++) {
    if (words[i].split('/').pop() !== 'git') continue;
    for (let j = i + 1; j < words.length; j++) {
      const w = words[j];
      if (/alias\./i.test(w)) return 'push';
      if (TAKES_VALUE.has(w)) { j++; if (/alias\./i.test(words[j] || '')) return 'push'; continue; }
      if (w.startsWith('-')) continue;
      if (w === 'commit' || w === 'push') return w;
      if (/[$]/.test(w)) return 'push';
      break;
    }
  }
  return '';
}

function classify(cmd, depth) {
  if (depth > MAX_DEPTH) return /\bgit\b/.test(cmd) ? 'push' : '';
  const { segs, quoted } = parse(cmd);
  let found = '';
  for (const s of segs) {
    const r = subcommand(s);
    if (r === 'commit') return 'commit';
    if (r) found = r;
  }
  for (const q of quoted) {
    const r = classify(q, depth + 1);
    if (r === 'commit') return 'commit';
    if (r) found = r;
  }
  return found;
}

let input = '';
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', () => {
  let out;
  try { out = classify(input, 0); } catch { out = 'push'; }
  process.stdout.write(out);
});
