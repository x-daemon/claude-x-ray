// Localization helper for the Windows sources (run with tsx from windows/).
//   keys          prints, as JSON, every catalog key the sources use (L``, tr(), N(), Fmt.plural)
//                 and every Russian text that is shown without going through them
//   wrap <file>…  wraps such texts in L`` (the migration helper; review the diff after it)
// scripts/l10n.py runs `keys` to check l10n/strings.json against the code.
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";

const CYRILLIC = /[А-Яа-яЁё]/;
const ROOT = path.resolve(import.meta.dirname, "..");
/** Files whose Russian is not interface text: the catalog itself and the language names. */
const SKIP = new Set(["src/core/l10n.generated.ts", "src/core/i18n.ts"]);

interface Key { key: string; plural?: boolean; file: string; line: number }
interface Problem { file: string; line: number; text: string; problem: string }

function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) out.push(...sourceFiles(full));
    else if (/\.(ts|tsx)$/.test(name)) out.push(full);
  }
  return out;
}

function parse(file: string): ts.SourceFile {
  const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  return ts.createSourceFile(file, readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true, kind);
}

const isPlainString = (n: ts.Node | undefined): n is ts.StringLiteral | ts.NoSubstitutionTemplateLiteral =>
  !!n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n));

function calleeName(e: ts.Expression): string | undefined {
  if (ts.isIdentifier(e)) return e.text;
  if (ts.isPropertyAccessExpression(e)) return e.name.text;
  return undefined;
}

function templateKey(template: ts.TemplateLiteral): string {
  if (ts.isNoSubstitutionTemplateLiteral(template)) return template.text;
  return template.head.text + template.templateSpans.map((s, i) => `{${i}}` + s.literal.text).join("");
}

function isIdentifierUse(node: ts.StringLiteral | ts.NoSubstitutionTemplateLiteral): boolean {
  const p = node.parent;
  if (ts.isLiteralTypeNode(p) || ts.isCaseClause(p)) return true;
  if ((ts.isPropertyAssignment(p) || ts.isPropertySignature(p)) && p.name === node) return true;
  return ts.isBinaryExpression(p) && [ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsEqualsToken].includes(p.operatorToken.kind);
}

/** True when the node runs as the module loads (not inside a function, method or instance field). */
function atLoadTime(node: ts.Node): boolean {
  for (let p = node.parent; p; p = p.parent) {
    if (ts.isFunctionLike(p)) return false;
    if (ts.isPropertyDeclaration(p) && !p.modifiers?.some((m) => m.kind === ts.SyntaxKind.StaticKeyword)) return false;
  }
  return true;
}

/** Russian texts that reach the screen through a translation function, and those that do not. */
function scan(sf: ts.SourceFile, rel: string): { keys: Key[]; problems: Problem[]; raw: ts.Node[] } {
  const keys: Key[] = [];
  const problems: Problem[] = [];
  const raw: ts.Node[] = [];
  const line = (n: ts.Node) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1;
  const loadTime = (n: ts.Node, what: string) =>
    problems.push({ file: rel, line: line(n), text: n.getText(sf).slice(0, 80), problem: `${what} runs when the module loads, before the language is set: keep N() in the table and call tr() where it is shown` });

  function visit(node: ts.Node): void {
    if (ts.isTaggedTemplateExpression(node) && ts.isIdentifier(node.tag) && node.tag.text === "L") {
      keys.push({ key: templateKey(node.template), file: rel, line: line(node) });
      if (atLoadTime(node)) loadTime(node, "L``");
      if (ts.isTemplateExpression(node.template)) node.template.templateSpans.forEach((s) => visit(s.expression));
      return;
    }
    if (ts.isCallExpression(node)) {
      const name = calleeName(node.expression);
      const [first, ...rest] = node.arguments;
      if ((name === "tr" || name === "N") && isPlainString(first)) {
        keys.push({ key: first.text, file: rel, line: line(node) });
        if (name === "tr" && atLoadTime(node)) loadTime(node, "tr()");
        rest.forEach(visit);
        return;
      }
      if (name === "plural" && node.arguments.length === 4 && rest.every(isPlainString)) {
        keys.push({ key: rest.map((a) => (a as ts.StringLiteral).text).join("|"), plural: true, file: rel, line: line(node) });
        visit(first);
        return;
      }
    }
    // A Russian name used as an identifier (a type, a key, a comparison) is shown through tr()
    // elsewhere, e.g. tr(category): it belongs in the catalog but needs no wrapper here.
    if (isPlainString(node) && CYRILLIC.test(node.text) && isIdentifierUse(node)) {
      keys.push({ key: node.text, file: rel, line: line(node) });
      return;
    }
    const shown =
      (isPlainString(node) && CYRILLIC.test(node.text)) ||
      (ts.isTemplateExpression(node) && [node.head, ...node.templateSpans.map((s) => s.literal)].some((p) => CYRILLIC.test(p.text))) ||
      (ts.isJsxText(node) && CYRILLIC.test(node.text));
    if (shown) {
      raw.push(node);
      problems.push({ file: rel, line: line(node), text: node.getText(sf).trim().slice(0, 80), problem: "Russian text without L``, tr() or N()" });
      if (!ts.isTemplateExpression(node)) return;
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
  return { keys, problems, raw };
}

// MARK: keys

function keysCommand(): void {
  const keys: Key[] = [];
  const problems: Problem[] = [];
  for (const file of sourceFiles(path.join(ROOT, "src"))) {
    const rel = path.relative(ROOT, file).split(path.sep).join("/");
    if (SKIP.has(rel)) continue;
    const result = scan(parse(file), rel);
    keys.push(...result.keys);
    problems.push(...result.problems);
  }
  process.stdout.write(JSON.stringify({ keys, problems }, null, 1) + "\n");
}

// MARK: wrap (migration)

const escapeTemplate = (s: string) => s.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$\{/g, "\\${");

/** JSX's own whitespace rule for a text child (as Babel and TypeScript apply it). */
function cleanJsxText(text: string): string {
  const lines = text.split(/\r\n|\n|\r/);
  let lastNonEmpty = 0;
  lines.forEach((l, i) => { if (/[^ \t]/.test(l)) lastNonEmpty = i; });
  let out = "";
  lines.forEach((l, i) => {
    let s = l.replace(/\t/g, " ");
    if (i > 0) s = s.replace(/^ +/, "");
    if (i < lines.length - 1) s = s.replace(/ +$/, "");
    if (s) out += i === lastNonEmpty ? s : s + " ";
  });
  return out;
}

/** Expressions that render as plain text, so they can move into an L`` template. */
function isTextExpression(e: ts.Expression): boolean {
  if (ts.isParenthesizedExpression(e)) return isTextExpression(e.expression);
  if (ts.isIdentifier(e) || ts.isStringLiteral(e) || ts.isNumericLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) return true;
  if (ts.isTemplateExpression(e) || ts.isTaggedTemplateExpression(e)) return true;
  if (ts.isPropertyAccessExpression(e) || ts.isElementAccessExpression(e)) return !e.getText().includes("<");
  if (ts.isConditionalExpression(e)) return isTextExpression(e.whenTrue) && isTextExpression(e.whenFalse);
  if (ts.isBinaryExpression(e)) return e.operatorToken.kind === ts.SyntaxKind.PlusToken || e.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken;
  if (ts.isCallExpression(e)) {
    const callee = e.expression.getText();
    return /^(Fmt\.\w+|String|Number|tr|plural|\w+\.(toFixed|join|slice|toLowerCase|toUpperCase|trim))$/.test(callee) || /^Fmt\./.test(callee);
  }
  return false;
}

function wrapCommand(files: string[]): void {
  for (const file of files) {
    const sf = parse(path.resolve(file));
    const rel = path.relative(ROOT, path.resolve(file)).split(path.sep).join("/");
    const { raw } = scan(sf, rel);
    const edits: { start: number; end: number; text: string }[] = [];
    const done = new Set<ts.Node>();

    for (const node of raw) {
      if (done.has(node)) continue;
      if (ts.isJsxText(node)) {
        // Merge the run of text and plain expressions around it into one template.
        const parent = node.parent as ts.JsxElement | ts.JsxFragment;
        const children = Array.from(parent.children);
        let i = children.indexOf(node as ts.JsxChild);
        let a = i, b = i;
        const mergeable = (c: ts.JsxChild) => ts.isJsxText(c) || (ts.isJsxExpression(c) && !!c.expression && isTextExpression(c.expression));
        while (a > 0 && mergeable(children[a - 1])) a--;
        while (b < children.length - 1 && mergeable(children[b + 1])) b++;
        // Leading/trailing text runs that are only layout whitespace stay where they are.
        let parts = "";
        let prefix = "", suffix = "";
        for (let k = a; k <= b; k++) {
          const c = children[k];
          done.add(c);
          if (ts.isJsxText(c)) {
            let text = c.getFullText(sf);
            if (k === a) { const m = /^\s*\n\s*/.exec(text); if (m) { prefix = m[0]; text = text.slice(m[0].length); } }
            if (k === b) { const m = /\s*\n\s*$/.exec(text); if (m) { suffix = m[0]; text = text.slice(0, text.length - m[0].length); } }
            parts += escapeTemplate(cleanJsxText(text));
          } else {
            const e = (c as ts.JsxExpression).expression!;
            parts += ts.isStringLiteral(e) ? escapeTemplate(e.text) : "${" + e.getText(sf) + "}";
          }
        }
        const start = children[a].getFullStart();
        const end = children[b].getEnd();
        edits.push({ start, end, text: `${prefix}{L\`${parts}\`}${suffix}` });
        continue;
      }
      if (ts.isTemplateExpression(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
        if (ts.isTaggedTemplateExpression(node.parent)) continue; // another tag: leave for review
        edits.push({ start: node.getStart(sf), end: node.getStart(sf), text: "L" });
        continue;
      }
      if (ts.isStringLiteral(node)) {
        const p = node.parent;
        // Keys, comparisons, switch cases and imports keep their literal: review by hand.
        if ((ts.isPropertyAssignment(p) && p.name === node) || ts.isCaseClause(p) || ts.isImportDeclaration(p) || ts.isLiteralTypeNode(p)) continue;
        if (ts.isBinaryExpression(p) && [ts.SyntaxKind.EqualsEqualsEqualsToken, ts.SyntaxKind.ExclamationEqualsEqualsToken].includes(p.operatorToken.kind)) continue;
        const text = `L\`${escapeTemplate(node.text)}\``;
        edits.push({ start: node.getStart(sf), end: node.getEnd(), text: ts.isJsxAttribute(p) ? `{${text}}` : text });
      }
    }
    if (edits.length === 0) continue;
    let out = sf.getFullText();
    for (const e of edits.sort((x, y) => y.start - x.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
    if (!/\bimport\s*\{[^}]*\bL\b[^}]*\}\s*from\s*["'][./]+(core\/)?i18n["']/.test(out)) {
      const fromDir = path.dirname(path.resolve(file));
      let spec = path.relative(fromDir, path.join(ROOT, "src/core/i18n")).split(path.sep).join("/");
      if (!spec.startsWith(".")) spec = "./" + spec;
      const lastImport = [...out.matchAll(/^import [^;]*;\n/gm)].pop();
      const at = lastImport ? lastImport.index! + lastImport[0].length : 0;
      out = out.slice(0, at) + `import { L } from "${spec}";\n` + out.slice(at);
    }
    writeFileSync(file, out);
    console.log(`${rel}: ${edits.length} edits`);
  }
}

const [command, ...args] = process.argv.slice(2);
if (command === "keys") keysCommand();
else if (command === "wrap") wrapCommand(args);
else {
  console.error("usage: tsx scripts/l10n.ts keys | wrap <file>…");
  process.exit(2);
}
