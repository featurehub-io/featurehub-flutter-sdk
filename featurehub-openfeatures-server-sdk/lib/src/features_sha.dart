import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:featurehub_client_api/api.dart';

/// The input of [featuresSha]: each feature as `<id>:<version>`, sorted by id
/// (plain string comparison), joined with `|`; empty for no features
/// (featurehub-protocol.yaml encoding.sha).
String featuresShaInput(Iterable<FeatureState> features) {
  final sorted = [...features]..sort((a, b) => a.id.compareTo(b.id));
  return sorted.map((f) => '${f.id}:${f.version}').join('|');
}

/// The SHA-256 (64 lowercase hex characters) of [features]' ids and
/// versions, as every FeatureHub SDK computes it: the Redis store's sha key,
/// and the base of a snapshot's sha. It identifies the features by id and
/// version only, not their values.
///
/// It belongs to the server SDK: nothing in the core SDK computes it.
String featuresSha(Iterable<FeatureState> features) =>
    _hex(featuresShaInput(features));

/// A snapshot's sha (feature-snapshot-protocol.yaml encoding.snapshot_sha):
/// the SHA-256 of [featuresInput] ([featuresShaInput]), `|sendContext=true`
/// for an [evaluated] snapshot or `|sendContext=false` for one served as
/// delivered, and, for a context, `|` and its x-featurehub [header]. The two
/// forms of the same features, and each context, never share a sha.
String snapshotSha(
  String featuresInput, {
  required bool evaluated,
  String? header,
}) {
  final form = evaluated ? 'sendContext=true' : 'sendContext=false';
  final context = header == null || header.isEmpty ? '' : '|$header';
  return _hex('$featuresInput|$form$context');
}

String _hex(String input) => sha256.convert(utf8.encode(input)).toString();
