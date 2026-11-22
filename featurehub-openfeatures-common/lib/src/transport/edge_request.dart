import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The protocol generation this SDK speaks to FeatureHub Edge, sent as the
/// `sdk_version` query parameter on every poll and streaming connection.
///
/// It is not this package's version: it changes only when the wire protocol
/// changes. Generation 2 is what lets Edge hold a quiet streaming connection
/// for a `Last-Event-ID` that is current, rather than send the features
/// again.
const edgeSdkVersion = 2;

/// The query parameters the SDK sends itself. A host's own query string
/// does not repeat them: each is sent once, in its place.
const _sdkParameters = {'apiKey', 'contextSha', 'sdk_version', 'xfeaturehub'};

/// The `contextSha` query parameter for [xFeatureHubHeader]: its sha256, or
/// `0` when there is none (a client-evaluated key, or no attributes).
///
/// Edge does not read it: it keeps a cache in front of Edge from serving
/// one context's features for another, as the `x-featurehub` header is not
/// part of a cache key.
String contextShaOf(String? xFeatureHubHeader) => xFeatureHubHeader == null
    ? '0'
    : sha256.convert(utf8.encode(xFeatureHubHeader)).toString();

/// A FeatureHub Edge host split into its URL without a query string
/// ([base]) and the query parameters it carried ([query]), in order, less
/// any the SDK sends itself.
class EdgeHost {
  /// The host without its query string.
  final String base;

  /// The host's own query parameters (decoded), sent before the SDK's.
  final List<MapEntry<String, String>> query;

  EdgeHost._(this.base, this.query);

  /// Splits [host].
  factory EdgeHost(String host) {
    final at = host.indexOf('?');
    if (at < 0) return EdgeHost._(host, const []);
    final query = <MapEntry<String, String>>[];
    for (final part in host.substring(at + 1).split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final name = Uri.decodeQueryComponent(
        eq < 0 ? part : part.substring(0, eq),
      );
      if (_sdkParameters.contains(name)) continue;
      final value = eq < 0
          ? ''
          : Uri.decodeQueryComponent(part.substring(eq + 1));
      query.add(MapEntry(name, value));
    }
    return EdgeHost._(host.substring(0, at), query);
  }

  /// The streaming URL for [apiKey]:
  /// `<host>/features/<key>?contextSha=<sha>&sdk_version=2`, after the host's
  /// own parameters, with `xfeaturehub` last when [xfeaturehub] is given
  /// (a browser, which cannot send the `x-featurehub` header).
  ///
  /// [xFeatureHubHeader] is the context for a server-evaluated key (null for
  /// a client-evaluated one): it gives the `contextSha`.
  String streamUrl(
    String apiKey, {
    String? xFeatureHubHeader,
    bool xfeaturehub = false,
  }) {
    final params = [
      ...query,
      MapEntry('contextSha', contextShaOf(xFeatureHubHeader)),
      MapEntry('sdk_version', '$edgeSdkVersion'),
      if (xfeaturehub && xFeatureHubHeader != null)
        MapEntry('xfeaturehub', xFeatureHubHeader),
    ];
    final encoded = params
        .map(
          (p) =>
              '${Uri.encodeQueryComponent(p.key)}='
              '${Uri.encodeQueryComponent(p.value)}',
        )
        .join('&');
    return '$base${base.endsWith('/') ? '' : '/'}features/$apiKey?$encoded';
  }
}
