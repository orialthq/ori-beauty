import 'dart:io';

import 'eval_core.dart';
import 'local_backend_client.dart';

const _defaultManifestPath = 'tool/evals/local/manifest.json';
const _defaultDataDirectory = 'tool/evals/local/samples';
const _defaultOutputPath = 'tool/evals/reports/latest.json';
const _defaultEndpoint = 'http://127.0.0.1:8787/v1/analyze';

/// Enough to reproduce the 10-run measurements in docs/PLACE_ENRICHMENT.md
/// twice over; beyond that a typo costs more than it tells.
const _maxRepeat = 20;

Future<void> main(List<String> arguments) async {
  _CliOptions options;
  try {
    options = _CliOptions.parse(arguments);
  } on FormatException {
    stderr.writeln('Invalid eval arguments. Use --help for usage.');
    exitCode = 64;
    return;
  }
  if (options.showHelp) {
    stdout.writeln(_usage);
    return;
  }

  final endpointSource =
      Platform.environment['ORI_EVAL_ENDPOINT'] ?? _defaultEndpoint;
  final apiKey = Platform.environment['ORI_EVAL_API_KEY'];
  final endpoint = Uri.tryParse(endpointSource);
  if (endpoint == null) {
    stderr.writeln('Eval configuration is invalid.');
    exitCode = 64;
    return;
  }

  EvalManifest manifest;
  try {
    manifest = EvalManifest.fromJsonString(
      await File(options.manifestPath).readAsString(),
    );
    manifest.validateFullHoldoutCoverage();
  } on Object {
    stderr.writeln(
      'Could not load the private eval manifest. '
      'See tool/evals/README.md.',
    );
    exitCode = 66;
    return;
  }

  EvalVocabulary? vocabulary;
  if (options.vocabularyPath case final path?) {
    try {
      vocabulary = EvalVocabulary.fromJsonString(
        await File(path).readAsString(),
      );
    } on Object {
      stderr.writeln(
        'Could not load the vocabulary file. See tool/evals/README.md.',
      );
      exitCode = 66;
      return;
    }
  }

  LocalBackendClient backend;
  try {
    backend = LocalBackendClient(endpoint: endpoint, apiKey: apiKey);
  } on FormatException {
    stderr.writeln('ORI_EVAL_ENDPOINT must point to a loopback server.');
    exitCode = 64;
    return;
  }

  try {
    final aggregate = await EvalRunner(backend: backend).run(
      manifest,
      Directory(options.dataDirectory),
      onlySampleIds: options.sampleIds.isEmpty ? null : options.sampleIds,
      repeat: options.repeat,
      vocabulary: vocabulary,
      growVocabulary: options.growVocabulary,
    );
    final outputFile = File(options.outputPath);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString('${aggregate.toPrettyJson()}\n');

    stdout.writeln(
      'Eval complete: ${aggregate.passedCount} passed, '
      '${aggregate.failedCount} failed.',
    );
    if (aggregate.tagReproducibility case final reproducibility?) {
      stdout.writeln(
        'Tag reproducibility over ${aggregate.repeat} runs: '
        '${reproducibility.toStringAsFixed(3)}.',
      );
    }
    stdout.writeln('Aggregate report written without sample content.');
    if (aggregate.failedCount > 0) {
      exitCode = 1;
    }
  } on FormatException {
    stderr.writeln('Eval selection or manifest coverage is invalid.');
    exitCode = 64;
  } on FileSystemException {
    stderr.writeln('Could not write the aggregate report.');
    exitCode = 73;
  } finally {
    backend.close();
  }
}

final class _CliOptions {
  const _CliOptions({
    required this.manifestPath,
    required this.dataDirectory,
    required this.outputPath,
    required this.sampleIds,
    required this.repeat,
    required this.vocabularyPath,
    required this.growVocabulary,
    required this.showHelp,
  });

  final String manifestPath;
  final String dataDirectory;
  final String outputPath;
  final Set<String> sampleIds;
  final int repeat;
  final String? vocabularyPath;
  final bool growVocabulary;
  final bool showHelp;

  factory _CliOptions.parse(List<String> arguments) {
    var manifestPath = _defaultManifestPath;
    var dataDirectory = _defaultDataDirectory;
    var outputPath = _defaultOutputPath;
    final sampleIds = <String>{};
    var repeat = 1;
    String? vocabularyPath;
    var growVocabulary = false;
    var showHelp = false;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
        continue;
      }
      if (argument == '--grow-vocabulary') {
        growVocabulary = true;
        continue;
      }
      if (argument == '--manifest' ||
          argument == '--data-dir' ||
          argument == '--output' ||
          argument == '--sample' ||
          argument == '--repeat' ||
          argument == '--vocabulary') {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value.');
        }
        final value = arguments[++index];
        switch (argument) {
          case '--manifest':
            manifestPath = value;
          case '--data-dir':
            dataDirectory = value;
          case '--output':
            outputPath = value;
          case '--sample':
            if (!RegExp(r'^holdout-[0-9]{2}$').hasMatch(value)) {
              throw const FormatException(
                '--sample must use an opaque holdout-NN ID.',
              );
            }
            sampleIds.add(value);
          case '--repeat':
            final parsed = int.tryParse(value);
            if (parsed == null || parsed < 1 || parsed > _maxRepeat) {
              throw const FormatException(
                '--repeat must be an integer from 1 to $_maxRepeat.',
              );
            }
            repeat = parsed;
          case '--vocabulary':
            validatePrivateRelativePath(value, '--vocabulary');
            vocabularyPath = value;
        }
        continue;
      }
      throw FormatException('Unknown argument.');
    }

    return _CliOptions(
      manifestPath: manifestPath,
      dataDirectory: dataDirectory,
      outputPath: outputPath,
      sampleIds: sampleIds,
      repeat: repeat,
      vocabularyPath: vocabularyPath,
      growVocabulary: growVocabulary,
      showHelp: showHelp,
    );
  }
}

const _usage =
    '''
Run private local holdout evaluation.

Usage:
  dart run tool/evals/run_local_eval.dart [options]

Options:
  --manifest <path>    Private manifest (default: $_defaultManifestPath)
  --data-dir <path>    Private sample directory (default: $_defaultDataDirectory)
  --output <path>      Aggregate JSON output (default: $_defaultOutputPath)
  --sample <id>        Run one opaque ID; repeat to run more than one
  --repeat <n>         Analyze each sample n times, 1 to $_maxRepeat (default: 1)
  --vocabulary <path>  Relative path to a vocabulary JSON sent with every request
  --grow-vocabulary    Add each sample's first-run tags to the vocabulary
  -h, --help           Show this help

Environment:
  ORI_EVAL_ENDPOINT  Loopback endpoint (default: $_defaultEndpoint)
  ORI_EVAL_API_KEY   Optional bearer key; never written to output
''';
