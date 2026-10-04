// Check local source imports without installing an additional audit package.
import ts from "typescript";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const configPath = path.join(root, "tsconfig.json");
const config = ts.readConfigFile(configPath, ts.sys.readFile);
if (config.error) throw new Error(ts.flattenDiagnosticMessageText(config.error.messageText, "\n"));
const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, root);
const files = new Set(parsed.fileNames.map(p => path.resolve(p)));
const seen = new Set();
const errors = [];
function visit(file) {
  if (seen.has(file)) return;
  seen.add(file);
  const source = ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true);
  function walk(node) {
    const specifier = ts.isImportDeclaration(node) || ts.isExportDeclaration(node) ? node.moduleSpecifier
      : ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword ? node.arguments[0] : undefined;
    if (specifier && ts.isStringLiteral(specifier) && specifier.text.startsWith(".")) {
      const resolved = ts.resolveModuleName(specifier.text, file, parsed.options, ts.sys).resolvedModule;
      if (resolved && files.has(path.resolve(resolved.resolvedFileName))) visit(path.resolve(resolved.resolvedFileName));
      else if (!resolved && !fs.existsSync(path.resolve(path.dirname(file), specifier.text))) errors.push(`${file}: missing ${specifier.text}`);
    }
    ts.forEachChild(node, walk);
  }
  walk(source);
}
visit(path.join(root, "src/main.tsx"));
const runtime = seen.size;
for (const file of files) if (/\.test\.tsx?$|\.d\.ts$|[/\\]test[/\\]setup\.ts$/.test(file)) visit(file);
for (const file of files) if (!seen.has(file)) errors.push(`Unreachable source: ${path.relative(root, file)}`);
if (errors.length) { console.error(errors.join("\n")); process.exitCode = 1; }
else console.log(`Source reachability passed: ${runtime} runtime modules, ${files.size} total source modules including tests and declarations.`);
