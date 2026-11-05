// Development utility: extract UI literals with Dart ASTs, preserving expressions.
// Run from mobile-app: dart run tool/localization/migrate.dart [--rewrite|--generate]
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

final han = RegExp(r'[\u3400-\u9fff]');
final catalogFile = File('tool/localization/messages.json');
final catalog = catalogFile.existsSync()
    ? Map<String, dynamic>.from(
        jsonDecode(catalogFile.readAsStringSync()) as Map,
      )
    : <String, dynamic>{};
final ids = <String, String>{
  for (final entry in catalog.entries) entry.value['zh'] as String: entry.key,
};

String message(String template) => ids.putIfAbsent(template, () {
  final id = 'm${(catalog.length + 1).toString().padLeft(4, '0')}';
  catalog[id] = {'zh': template, 'en': ''};
  return id;
});

class Edit {
  Edit(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

String apply(String source, Iterable<Edit> changes, {int offset = 0}) {
  final edits = changes.toList()..sort((a, b) => b.start.compareTo(a.start));
  for (final edit in edits) {
    source = source.replaceRange(
      edit.start - offset,
      edit.end - offset,
      edit.text,
    );
  }
  return source;
}

class Rewriter extends RecursiveAstVisitor<void> {
  Rewriter(this.source, {this.offset = 0, this.requireContext = true});
  final String source;
  final int offset;
  final bool requireContext;
  final edits = <Edit>[];
  final constants = <int, Edit>{};
  final skipped = <String>[];

  bool hasContext(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is DefaultFormalParameter ||
          parent is ConstructorDeclaration) {
        return false;
      }
      if (parent is FunctionExpression &&
          parent.parameters?.parameters.any(
                (p) => p.name?.lexeme == 'context',
              ) ==
              true) {
        return true;
      }
      if (parent is MethodDeclaration &&
          parent.parameters?.parameters.any(
                (p) => p.name?.lexeme == 'context',
              ) ==
              true) {
        return true;
      }
      if (parent is ClassDeclaration &&
          (parent.extendsClause?.superclass.toSource().startsWith('State<') ??
              false)) {
        return true;
      }
    }
    return false;
  }

  void removeConstAncestors(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent.offset < offset || parent.end > offset + source.length) break;
      if (parent is InstanceCreationExpression &&
          parent.keyword?.lexeme == 'const') {
        final token = parent.keyword!;
        constants[token.offset] = Edit(token.offset, token.end, '');
      } else if (parent is TypedLiteral && parent.constKeyword != null) {
        final token = parent.constKeyword!;
        constants[token.offset] = Edit(token.offset, token.end, '');
      } else if (parent is VariableDeclarationList && parent.isConst) {
        final token = parent.keyword!;
        constants[token.offset] = Edit(token.offset, token.end, 'final');
      }
    }
  }

  String expression(Expression expression) {
    final nested = Rewriter(
      source.substring(expression.offset - offset, expression.end - offset),
      offset: expression.offset,
      requireContext: false,
    );
    expression.accept(nested);
    return apply(nested.source, [
      ...nested.edits,
      ...nested.constants.values,
    ], offset: expression.offset);
  }

  String replacement(StringLiteral literal) {
    final template = StringBuffer();
    final args = <String>[];
    void append(StringLiteral part) {
      if (part is SimpleStringLiteral) {
        template.write(part.value);
      } else if (part is AdjacentStrings) {
        for (final string in part.strings) {
          append(string);
        }
      } else if (part is StringInterpolation) {
        for (final element in part.elements) {
          if (element is InterpolationString) template.write(element.value);
          if (element is InterpolationExpression) {
            template.write('{${args.length}}');
            args.add(expression(element.expression));
          }
        }
      }
    }

    append(literal);
    final id = message(template.toString());
    return "${formatter(literal)}(context, '$id'${args.isEmpty ? '' : ', [${args.join(', ')}]'})";
  }

  void handle(StringLiteral node) {
    if (!han.hasMatch(node.toSource())) return;
    if (requireContext && !hasContext(node)) {
      skipped.add('${node.offset}: ${node.toSource().split('\n').first}');
      return;
    }
    edits.add(Edit(node.offset, node.end, replacement(node)));
    removeConstAncestors(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => handle(node);
  @override
  void visitStringInterpolation(StringInterpolation node) => handle(node);
  @override
  void visitAdjacentStrings(AdjacentStrings node) => handle(node);
}

String formatter(AstNode node) {
  for (AstNode? parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is MethodDeclaration) {
      return parent.name.lexeme == 'build' ? 'tr' : 'trNow';
    }
    if (parent is FunctionDeclaration) return 'trNow';
  }
  return 'trNow';
}

class ContextFixer extends RecursiveAstVisitor<void> {
  final edits = <Edit>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'tr' && formatter(node) == 'trNow') {
      edits.add(Edit(node.methodName.offset, node.methodName.end, 'trNow'));
    }
    super.visitMethodInvocation(node);
  }
}

class ErrorCollector extends RecursiveAstVisitor<void> {
  void collect(String type, ArgumentList arguments) {
    if (!type.endsWith('Error') && !type.endsWith('Exception')) return;
    if (arguments.arguments.isEmpty) return;
    final first = arguments.arguments.first;
    if (first is StringLiteral && han.hasMatch(first.toSource())) {
      Rewriter(
        first.toSource(),
        offset: first.offset,
        requireContext: false,
      ).replacement(first);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    collect(node.constructorName.type.toSource(), node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    collect(node.methodName.name, node.argumentList);
    super.visitMethodInvocation(node);
  }
}

void main(List<String> args) {
  if (args.contains('--generate')) {
    final output = StringBuffer(
      '// Generated from tool/localization/messages.json.\nconst messages = <String, (String, String)>{\n',
    );
    for (final entry in catalog.entries) {
      final value = entry.value as Map;
      if ((value['en'] as String).isEmpty && !args.contains('--draft')) {
        throw StateError('Missing translation: ${entry.key}');
      }
      String dartString(String input) =>
          jsonEncode(input).replaceAll(r'$', r'\$');
      output.writeln(
        '  ${dartString(entry.key)}: (${dartString(value['zh'] as String)}, ${dartString((value['en'] as String).isEmpty ? value['zh'] as String : value['en'] as String)}),',
      );
    }
    output.writeln('};');
    File('lib/l10n/messages.dart').writeAsStringSync(output.toString());
    return;
  }
  if (args.contains('--errors')) {
    final files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.dart') && !file.path.contains('/l10n/'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      parseString(
        content: file.readAsStringSync(),
        throwIfDiagnostics: false,
      ).unit.accept(ErrorCollector());
    }
    catalogFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(catalog)}\n',
    );
    stdout.writeln('Unique messages including errors: ${catalog.length}');
    return;
  }
  if (args.contains('--fix-context')) {
    for (final file in Directory('lib/ui').listSync().whereType<File>().where(
      (file) => file.path.endsWith('.dart'),
    )) {
      final source = file.readAsStringSync();
      final visitor = ContextFixer();
      parseString(
        content: source,
        throwIfDiagnostics: false,
      ).unit.accept(visitor);
      if (visitor.edits.isNotEmpty) {
        file.writeAsStringSync(apply(source, visitor.edits));
      }
    }
    return;
  }
  final files =
      Directory('lib/ui')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final source = file.readAsStringSync();
    final parsed = parseString(content: source, throwIfDiagnostics: false);
    final rewriter = Rewriter(source);
    parsed.unit.accept(rewriter);
    if (rewriter.edits.isNotEmpty) {
      stdout.writeln('${file.path}: ${rewriter.edits.length} messages');
      if (args.contains('--rewrite')) {
        final text = apply(source, [
          ...rewriter.edits,
          ...rewriter.constants.values,
        ]);
        file.writeAsStringSync("import '../l10n/app_strings.dart';\n\n$text");
      }
    }
    for (final skipped in rewriter.skipped) {
      stdout.writeln('MANUAL ${file.path}:$skipped');
    }
  }
  if (args.contains('--rewrite')) {
    catalogFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(catalog)}\n',
    );
  }
  stdout.writeln('Unique messages: ${catalog.length}');
}
