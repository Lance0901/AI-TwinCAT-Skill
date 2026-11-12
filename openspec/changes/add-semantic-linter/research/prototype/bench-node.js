// Throwaway: same simplified lexer as Lex-Ps in Bench.ps1, in Node. NOT product code.
const fs = require('fs');
const s0 = fs.readFileSync(process.argv[2], 'utf8');
function lex(s) {
  let i = 0, n = s.length, c = 0;
  const isW = ch => /[A-Za-z0-9_#\u0080-\uffff]/.test(ch);
  while (i < n) {
    const ch = s[i];
    if (/\s/.test(ch)) { i++; continue; }
    if (ch === '/' && s[i + 1] === '/') { const j = s.indexOf('\n', i); i = j < 0 ? n : j; continue; }
    if (ch === '(' && s[i + 1] === '*') { let d = 1; i += 2; while (i < n && d > 0) { if (s[i] === '(' && s[i + 1] === '*') { d++; i += 2; } else if (s[i] === '*' && s[i + 1] === ')') { d--; i += 2; } else i++; } continue; }
    if (ch === '{') { i = s.indexOf('}', i) + 1; c++; continue; }
    if (ch === "'" || ch === '"') { i++; while (i < n && s[i] !== ch) { if (s[i] === '$') i++; i++; } i++; c++; continue; }
    if (isW(ch)) { while (i < n && isW(s[i])) i++; c++; continue; }
    const two = s.substr(i, 2);
    if ([':=', '=>', '<>', '<=', '>=', '..', '**'].includes(two)) { i += 2; c++; continue; }
    i++; c++;
  }
  return c;
}
const t0 = process.hrtime.bigint(); let tot = 0;
for (let k = 0; k < 5; k++) tot += lex(s0);
console.log(`node tokens/5runs=${tot} ms_per_run=${Number((process.hrtime.bigint() - t0) / 5000000n)}`);
