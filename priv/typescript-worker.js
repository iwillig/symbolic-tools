#!/usr/bin/env node
'use strict';

// Worker protocol v1. This process loads only the selected project's
// TypeScript package; it never evaluates project scripts or emits Prolog.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_TYPE_NODES = 10000;
const MAX_FACTS = 100000;
const MAX_DEPTH = 12;
const MAX_PROPERTIES = 64;

function output(value) {
  process.stdout.write(JSON.stringify(value));
}

function fail(status, reason, extra = {}) {
  output({ schemaVersion: 1, status, reason, ...extra });
}

function byteOffset(source, utf16Offset) {
  return Buffer.byteLength(source.slice(0, Math.max(0, utf16Offset)), 'utf8');
}

function main() {
  if (Number(process.versions.node.split('.')[0]) < 20) {
    return fail('unavailable', 'unsupported_node', { nodeVersion: process.versions.node });
  }
  const requestPath = process.argv[2];
  if (!requestPath) return fail('failed', 'invalid_request');

  let request;
  try {
    request = JSON.parse(fs.readFileSync(requestPath, 'utf8'));
  } catch (_) {
    return fail('failed', 'invalid_request');
  }
  if (request.schemaVersion !== 1 || typeof request.configFile !== 'string' ||
      typeof request.projectId !== 'string' || !Array.isArray(request.scanFiles)) {
    return fail('failed', 'invalid_request');
  }

  let ts;
  try {
    const resolved = require.resolve('typescript', {
      paths: [path.dirname(path.resolve(request.configFile))],
    });
    ts = require(resolved);
  } catch (_) {
    return fail('unavailable', 'compiler_missing');
  }
  if (typeof ts.readConfigFile !== 'function' || typeof ts.parseJsonConfigFileContent !== 'function' ||
      typeof ts.createProgram !== 'function') {
    return fail('unavailable', 'unsupported_compiler_api', {
      compilerVersion: typeof ts.version === 'string' ? ts.version : null,
    });
  }

  let configRead;
  try {
    configRead = ts.readConfigFile(request.configFile, ts.sys.readFile);
  } catch (error) {
    return fail('failed', 'bad_config', { message: String(error && error.message || error) });
  }
  if (configRead.error) {
    return fail('failed', 'bad_config', {
      diagnostics: [diagnosticToJson(ts, configRead.error)],
    });
  }

  const parsed = ts.parseJsonConfigFileContent(
    configRead.config,
    ts.sys,
    path.dirname(path.resolve(request.configFile)),
    undefined,
    path.resolve(request.configFile),
  );
  if (parsed.errors.length) {
    return fail('failed', 'bad_config', {
      diagnostics: parsed.errors.map((item) => diagnosticToJson(ts, item)),
    });
  }

  let program;
  try {
    program = ts.createProgram({
      rootNames: parsed.fileNames,
      options: parsed.options,
      projectReferences: parsed.projectReferences,
    });
  } catch (error) {
    return fail('failed', 'program_error', { message: String(error && error.message || error) });
  }

  const checker = program.getTypeChecker();
  const allowedFiles = new Set(request.scanFiles.map((file) => path.resolve(file)));
  const symbols = new Map();
  const declarations = [];
  const declaredTypes = [];
  const typeAt = [];
  const locationSymbols = [];
  const typeNodes = [];
  const typeEdges = [];
  const diagnostics = [];
  const typeIds = new Map();
  let truncated = false;
  let nextTypeId = 0;
  let nextLocationId = 0;

  const toByteRange = (sourceFile, node) => ({
    start: byteOffset(sourceFile.text, node.getStart(sourceFile)),
    end: byteOffset(sourceFile.text, node.getEnd()),
  });
  const sourcePath = (sourceFile) => path.resolve(sourceFile.fileName);
  const symbolKind = (symbol) => {
    const flags = symbol.flags;
    if (flags & ts.SymbolFlags.Class) return 'class';
    if (flags & ts.SymbolFlags.Interface) return 'interface';
    if (flags & ts.SymbolFlags.TypeAlias) return 'type_alias';
    if (flags & ts.SymbolFlags.Function) return 'function';
    if (flags & ts.SymbolFlags.Method) return 'method';
    if (flags & ts.SymbolFlags.Property) return 'property';
    if (flags & ts.SymbolFlags.Parameter) return 'parameter';
    if (flags & ts.SymbolFlags.TypeParameter) return 'type_parameter';
    if (flags & ts.SymbolFlags.Enum) return 'enum';
    if (flags & ts.SymbolFlags.Value) return 'value';
    return 'other';
  };
  const stableSymbolId = (symbol) => {
    if (symbols.has(symbol)) return symbols.get(symbol).id;
    const symbolDeclarations = (symbol.declarations || []).slice().sort((a, b) => {
      const af = sourcePath(a.getSourceFile());
      const bf = sourcePath(b.getSourceFile());
      return af.localeCompare(bf) || a.getStart(a.getSourceFile()) - b.getStart(b.getSourceFile());
    });
    const first = symbolDeclarations.find((decl) => allowedFiles.has(sourcePath(decl.getSourceFile()))) ||
      symbolDeclarations[0];
    let id;
    if (first) {
      const file = sourcePath(first.getSourceFile());
      const range = toByteRange(first.getSourceFile(), first);
      id = `sym:${file}:${range.start}:${range.end}`;
    } else {
      id = `sym:unlocated:${String(symbol.escapedName)}`;
    }
    symbols.set(symbol, { id, name: symbol.getName(), kind: symbolKind(symbol) });
    return id;
  };
  const kindOfType = (type) => {
    if (type.isUnion && type.isUnion()) return 'union';
    if (type.isIntersection && type.isIntersection()) return 'intersection';
    const flags = type.flags;
    if (flags & ts.TypeFlags.Any) return 'any';
    if (flags & ts.TypeFlags.Unknown) return 'unknown';
    if (flags & ts.TypeFlags.Never) return 'never';
    if (flags & ts.TypeFlags.StringLiteral) return 'string_literal';
    if (flags & ts.TypeFlags.NumberLiteral) return 'number_literal';
    if (flags & ts.TypeFlags.BooleanLiteral) return 'boolean_literal';
    if (flags & ts.TypeFlags.StringLike) return 'string';
    if (flags & ts.TypeFlags.NumberLike) return 'number';
    if (flags & ts.TypeFlags.BooleanLike) return 'boolean';
    if (flags & ts.TypeFlags.BigIntLike) return 'bigint';
    if (flags & ts.TypeFlags.Null) return 'null';
    if (flags & ts.TypeFlags.Undefined) return 'undefined';
    if (flags & ts.TypeFlags.TypeParameter) return 'type_parameter';
    if (flags & ts.TypeFlags.Object) return 'object';
    return 'other';
  };

  function addType(type, depth) {
    if (!type) return undefined;
    if (typeIds.has(type)) return typeIds.get(type);
    if (depth > MAX_DEPTH || typeNodes.length >= MAX_TYPE_NODES ||
        typeNodes.length + typeEdges.length >= MAX_FACTS) {
      truncated = true;
      return undefined;
    }
    const id = `type:${nextTypeId++}`;
    typeIds.set(type, id);
    let display = '';
    try {
      display = checker.typeToString(type, undefined, ts.TypeFormatFlags.NoTruncation);
    } catch (_) {
      display = '<unrenderable>';
    }
    typeNodes.push({ id, kind: kindOfType(type), display });
    const addEdge = (role, child) => {
      const childId = addType(child, depth + 1);
      if (childId !== undefined && typeEdges.length < MAX_FACTS) {
        typeEdges.push({ parent: id, role, child: childId });
      } else if (childId === undefined) {
        truncated = true;
      }
    };
    if (type.isUnion && type.isUnion()) {
      type.types.forEach((child, index) => addEdge(`union:${index}`, child));
    } else if (type.isIntersection && type.isIntersection()) {
      type.types.forEach((child, index) => addEdge(`intersection:${index}`, child));
    } else if (type.flags & ts.TypeFlags.Object) {
      if (type.objectFlags & ts.ObjectFlags.Reference) {
        try {
          checker.getTypeArguments(type).forEach((child, index) => addEdge(`type_argument:${index}`, child));
        } catch (_) { /* Not every object reference exposes arguments. */ }
      }
      let properties = [];
      try { properties = checker.getPropertiesOfType(type); } catch (_) { /* Partial graph is safer than worker failure. */ }
      if (properties.length > MAX_PROPERTIES) truncated = true;
      properties.slice(0, MAX_PROPERTIES).forEach((property) => {
        const declaration = property.valueDeclaration || (property.declarations || [])[0];
        if (!declaration) return;
        try {
          addEdge(`property:${property.getName()}`,
            checker.getTypeOfSymbolAtLocation(property, declaration));
        } catch (_) { truncated = true; }
      });
    }
    return id;
  }

  const pushLocationType = (sourceFile, node, type, origin, symbol) => {
    if (!type || typeAt.length >= MAX_FACTS) {
      truncated = true;
      return;
    }
    const range = toByteRange(sourceFile, node);
    const locationId = `loc:${sourcePath(sourceFile)}:${range.start}:${range.end}:${nextLocationId++}`;
    const typeId = addType(type, 0);
    if (typeId === undefined) {
      truncated = true;
      return;
    }
    typeAt.push({ locationId, typeId, origin, file: sourcePath(sourceFile), ...range });
    if (symbol && (symbol.declarations || []).some((declaration) =>
      allowedFiles.has(sourcePath(declaration.getSourceFile())))) {
      locationSymbols.push({ locationId, symbolId: stableSymbolId(symbol), role: 'reference' });
    }
  };

  const sourceFiles = program.getSourceFiles().filter((sourceFile) =>
    allowedFiles.has(sourcePath(sourceFile)) && /\.(ts|tsx)$/i.test(sourcePath(sourceFile)));
  for (const sourceFile of sourceFiles) {
    const visit = (node) => {
      const nameNode = node.name && ts.isIdentifier(node.name) ? node.name : undefined;
      if (nameNode) {
        let symbol;
        try { symbol = checker.getSymbolAtLocation(nameNode); } catch (_) { symbol = undefined; }
        if (symbol) {
          const symbolId = stableSymbolId(symbol);
          const symbolInfo = symbols.get(symbol);
          const range = toByteRange(sourceFile, node);
          const declarationId = `decl:${sourcePath(sourceFile)}:${range.start}:${range.end}`;
          if (!declarations.some((decl) => decl.id === declarationId)) {
            declarations.push({ id: declarationId, symbolId, file: sourcePath(sourceFile), ...range });
          }
          const explicit = !!node.type;
          try {
            if (node.type) {
              const type = checker.getTypeFromTypeNode(node.type);
              const typeId = addType(type, 0);
              if (typeId !== undefined) declaredTypes.push({ declarationId, typeId });
            }
            const effective = checker.getTypeAtLocation(node);
            pushLocationType(sourceFile, node, effective, explicit ? 'declared' : 'inferred', symbol);
          } catch (_) {
            truncated = true;
          }
          // Ensure the symbol record is materialized even when its only
          // checker type could not be represented within the output cap.
          symbolInfo.name = String(symbolInfo.name);
        }
      }
      if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
        try {
          const symbol = checker.getSymbolAtLocation(node.expression);
          pushLocationType(sourceFile, node, checker.getTypeAtLocation(node), 'call_result', symbol);
        } catch (_) { truncated = true; }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
  }

  const allDiagnostics = [
    ...program.getSyntacticDiagnostics(),
    ...program.getSemanticDiagnostics(),
  ];
  for (const diagnostic of allDiagnostics) {
    if (!diagnostic.file || diagnostic.start === undefined) continue;
    if (!allowedFiles.has(sourcePath(diagnostic.file))) continue;
    diagnostics.push(diagnosticToJson(ts, diagnostic));
  }

  const stableJson = (value) => {
    if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
    if (value && typeof value === 'object') {
      return `{${Object.keys(value).sort().map((key) =>
        `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
    }
    return JSON.stringify(value);
  };
  const optionsJson = stableJson(parsed.options);
  const optionsHash = crypto.createHash('sha256').update(optionsJson).digest('hex');
  const result = {
    schemaVersion: 1,
    status: 'ok',
    reason: 'none',
    compilerVersion: ts.version,
    optionsHash,
    filesProcessed: sourceFiles.length,
    symbols: Array.from(symbols.values()),
    declarations,
    declaredTypes,
    typeNodes,
    typeEdges,
    typeAt,
    locationSymbols,
    diagnostics,
  };
  const factArrays = ['symbols', 'declarations', 'declaredTypes', 'typeNodes',
    'typeEdges', 'typeAt', 'locationSymbols', 'diagnostics'];
  let remainingFacts = MAX_FACTS;
  for (const key of factArrays) {
    if (result[key].length > remainingFacts) {
      result[key] = result[key].slice(0, remainingFacts);
      truncated = true;
    }
    remainingFacts -= result[key].length;
  }
  if (truncated) {
    result.status = 'partial';
    result.reason = 'resource_limit';
  }
  output(result);
}

function diagnosticToJson(ts, diagnostic) {
  const message = ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n');
  const file = diagnostic.file;
  const start = file && diagnostic.start !== undefined
    ? byteOffset(file.text, diagnostic.start)
    : undefined;
  const end = file && diagnostic.start !== undefined
    ? byteOffset(file.text, diagnostic.start + (diagnostic.length || 0))
    : undefined;
  const category = diagnostic.category === ts.DiagnosticCategory.Error ? 'error'
    : diagnostic.category === ts.DiagnosticCategory.Warning ? 'warning'
    : diagnostic.category === ts.DiagnosticCategory.Suggestion ? 'suggestion'
    : 'message';
  return {
    code: diagnostic.code,
    category,
    file: file ? path.resolve(file.fileName) : undefined,
    start,
    length: start !== undefined ? end - start : undefined,
    message,
  };
}

try {
  main();
} catch (error) {
  process.stderr.write(`typescript worker failed: ${String(error && error.stack || error)}\n`);
  fail('failed', 'worker_crash');
  process.exitCode = 1;
}
