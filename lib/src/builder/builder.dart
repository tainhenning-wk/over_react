import 'dart:async';

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:build/build.dart';

import 'package:over_react/src/builder/generation/declaration_parsing.dart';
import 'package:over_react/src/builder/generation/impl_generation.dart';
import 'package:over_react/src/builder/builder_util.dart';
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';


Builder overReactBuilder(BuilderOptions options) => new OverReactBuilder();

class OverReactBuilder implements Builder {
  OverReactBuilder();

  /// Converts [id] to a "package:" URI.
  ///
  /// This will return a schemeless URI if [id] doesn't represent a library in
  /// `lib/`.
  static Uri idToPackageUri(AssetId id) {
    if (!id.path.startsWith('lib/')) {
      return new Uri(path: id.path);
    }

    return new Uri(scheme: 'package',
        path: p.url.join(id.package, id.path.replaceFirst('lib/', '')));
  }


  String _generateForFile(AssetId inputId, String primaryInputContents,
      CompilationUnit resolvedUnit, Map<String, String> libUriPathToImportAlias,
      List<String> importDirectives,
      Map<String, Set<String>> ancestorClassNamesToImportAlias,
      ImportCounter importCounter,
      AssetId outputId) {
    var sourceFile = new SourceFile.fromString(
        primaryInputContents, url: idToPackageUri(inputId));
    var output = new StringBuffer();

    ImplGenerator generator;
    ParsedDeclarations declarations;
    if (ParsedDeclarations.mightContainDeclarations(primaryInputContents)) {
      declarations = new ParsedDeclarations(resolvedUnit, sourceFile, log);
      // Don't need to add any imports if this generated class is in the base library

      declarations.propAncestorCompUnits?.forEach((compUnit) {
        addLibUriPathToMap(compUnit, libUriPathToImportAlias, outputId, importCounter);
      });

      declarations.stateAncestorCompUnits?.forEach((compUnit) {
        addLibUriPathToMap(compUnit, libUriPathToImportAlias, outputId, importCounter);
      });

      if (!declarations.hasErrors && declarations.hasDeclarations) {
        generator = new ImplGenerator(log, sourceFile, libUriPathToImportAlias, ancestorClassNamesToImportAlias, importCounter)
          ..generate(declarations);
      } else {
        if (declarations.hasErrors) {
          log.fine(
              'There was an error parsing the file declarations for file: ${inputId.toString()}');
        }
        if (!declarations.hasDeclarations) {
          log.fine(
              'There were no declarations found for file: ${inputId
                  .toString()}');
        }
      }
    } else {
      log.fine(
          'no declarations found for file: ${inputId.toString()}');
    }
    if (generator?.outputContentsBuffer?.isNotEmpty ?? false) {
      output.write(generator?.outputContentsBuffer);
      return output.toString();
    }
    return '';
  }

  @override
  Future build(BuildStep buildStep) async {
    // This check returns false if the file is a part file. We don't want to build
    // on part files, and instead rely on building from the library file and
    // accessing each part file from there
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) {
      return;
    }

    final outputId = buildStep.inputId.changeExtension(outputExtension);

    // Process both the main and part files of a given library.
    final entryLib = await buildStep.inputLibrary;

    final inputId = await buildStep.inputId;

    // part of directive
    var outputBuffer = StringBuffer();

    var contentBuffer = new StringBuffer();
    // flatten base and children compilation units
    final compUnits = [
      [entryLib.definingCompilationUnit],
      entryLib.parts.expand((p) => [p]),
    ].expand((t) => t).toList();

    // Always need to import over_react to get PropDescriptor type, etc.
    // (nearly) Always need to import the parent library file to access props
    // and component classes for the factory.
    // TODO: Don't need to add target class import in cases where the gen'd factory is not present
    var overReactImportDirective = 'import \'package:over_react/over_react.dart\';';
    var importDirectives = <String>[
      overReactImportDirective,
    ];

    // Maps library source uri to the named alias for that import
    var libUriPathToImportAlias = <String, String>{};

    // map ancestor class names to their respective import aliases
    var ancestorClassNamesToImportAlias = <String, Set<String>>{};

    var importCounter = new ImportCounter(0);

    for (final unit in compUnits) {
      log.fine('Generating implementations for file: ${unit.name}');
      // For the base library file, unit.uri will be null
      final assetId = AssetId.resolve(unit.uri ?? unit.name ?? '', from: inputId);

      // Only generate on part files which were not generated by this builder and
      // which can be read.
      if (!assetId.toString().contains(outputExtension) && await buildStep.canRead(assetId)) {
        final resolvedUnit = unit.computeNode();
        final inputContents = await buildStep.readAsString(assetId);
        contentBuffer.write(_generateForFile(assetId, inputContents, resolvedUnit, libUriPathToImportAlias, importDirectives, ancestorClassNamesToImportAlias, importCounter, outputId));
      }
    }

    libUriPathToImportAlias.forEach((libUriPath, importAlias) {
      if (!getImportDirective(libUriPath, importAlias).contains(outputId.pathSegments.last)) {
        importDirectives.add(getImportDirective(libUriPath, importAlias));
      }
    });

    entryLib.definingCompilationUnit.computeNode().directives.forEach((directive) {
      if (directive.keyword.toString().compareTo('import') == 0) {
        if (directive.toSource().compareTo(overReactImportDirective) != 0 &&
            !directive.toSource().contains(outputId.pathSegments.last)) {
          importDirectives.add(directive.toSource());
        }
      }
    });

    importDirectives.add('import \'${inputId.pathSegments.last}\';');

    if (contentBuffer.isNotEmpty) {
      // Remove duplicates
      importDirectives.toSet();
      outputBuffer.writeln(importDirectives.join('\n'));
      outputBuffer.write(contentBuffer);
      await buildStep.writeAsString(outputId, outputBuffer.toString());
    } else {
      log.fine('No output generated for file: ${inputId.toString()}');
    }
  }

  @override
  Map<String, List<String>> get buildExtensions =>
      {'.dart': const [outputExtension]};
}

void addLibUriPathToMap(CompilationUnitMember compUnit, Map<String, String> libUriPathToImportAlias, AssetId outputId, ImportCounter importCounter) {
  var libUriPath = compUnit.declaredElement.library.source.uri.path.replaceAll(
      '.dart', outputExtension);
  if (!libUriPath.contains(outputId.pathSegments.last)) {
    if (!libUriPathToImportAlias.containsKey(libUriPath)) {
      var importAlias = getLibAlias(importCounter.count++);
      libUriPathToImportAlias[libUriPath] = importAlias;
    }
  }
}
