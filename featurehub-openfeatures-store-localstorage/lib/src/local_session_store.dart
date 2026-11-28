import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

final _log = Logger('featurehub_local_session_store');

/// The source [LocalSessionStore] gives the features it loads (the same as
/// the TypeScript SDK's store).
const localSessionStoreSource = 'local-session-store';

/// The storage key [LocalSessionStore] uses when the provider does not
/// connect to FeatureHub (so there is no feature URL to key by).
const localSessionStoreDefaultKey = 'featurehub-features';

/// Where [LocalSessionStore] keeps its data: browser storage by default.
abstract interface class FeatureStorage {
  String? getItem(String key);
  void setItem(String key, String value);
}

/// [FeatureStorage] over the browser's `sessionStorage` or `localStorage`.
class WebFeatureStorage implements FeatureStorage {
  final web.Storage _storage;

  /// `sessionStorage`: scoped to the browser tab, discarded when it closes.
  WebFeatureStorage.session() : _storage = web.window.sessionStorage;

  /// `localStorage`: kept across tabs and browser restarts.
  WebFeatureStorage.local() : _storage = web.window.localStorage;

  @override
  String? getItem(String key) => _storage.getItem(key);

  @override
  void setItem(String key, String value) => _storage.setItem(key, value);
}

/// Keeps the features in browser storage, so a web application starts with
/// the features it last had instead of waiting for FeatureHub.
///
/// Give it to the client provider's `stores`. On attaching it loads the
/// features stored for the environment (keyed by its feature URL) into the
/// repository, so they can be resolved straight away; from then on every
/// update from FeatureHub is written to storage. It stores the same data, in
/// the same format, as the FeatureHub TypeScript SDK's store.
///
/// For a server-evaluated API key (or a features server sent the context),
/// the features are evaluated for a context, so each context's are stored
/// apart (the storage key ends `?contextSha=<context>`): a start loads only
/// the features stored for the context it starts with.
class LocalSessionStore implements FeatureStore {
  final FeatureStorage _storage;
  String? _storageKey;

  /// The environment's storage key, before any context.
  String? _baseKey;
  ClientFeatureRepository? _repository;
  bool _perContext = false;
  Map<String, FeatureState> _store = {};
  StreamSubscription<RawFeatureUpdate>? _subscription;

  /// Uses [storage], `sessionStorage` by default.
  LocalSessionStore({FeatureStorage? storage})
    : _storage = storage ?? WebFeatureStorage.session();

  /// Uses `localStorage`, kept across tabs and browser restarts.
  LocalSessionStore.localStorage() : this(storage: WebFeatureStorage.local());

  @override
  bool get connected => _subscription != null;

  @override
  Future<void> attach(FeatureStoreTarget target) async {
    _baseKey = target.featureUrl ?? localSessionStoreDefaultKey;
    _repository = target.repository;
    _perContext = target.sendsContext;
    final key = _keyFor(target.contextHeader);
    _storageKey = key;
    final stored = _load(key);
    _subscription = target.repository.rawFeatureUpdates.listen(_update);
    if (stored != null) {
      _store = stored;
      target.repository.notify(
        SSEResultState.features,
        stored.values.toList(),
        source: localSessionStoreSource,
      );
    }
  }

  /// The storage key for the features of the context with [header].
  String _keyFor(String? header) => _perContext
      ? '$_baseKey?contextSha=${FeatureStoreTarget.contextKey(header)}'
      : _baseKey!;

  Map<String, FeatureState>? _load(String key) {
    try {
      final raw = _storage.getItem(key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          '${entry.key}': FeatureState.fromJson(entry.value),
      };
    } catch (e) {
      // unreadable or malformed data: start without it
      _log.fine('Ignoring stored features: $e');
      return null;
    }
  }

  void _update(RawFeatureUpdate update) {
    if (update.source == localSessionStoreSource) return;
    if (_perContext) {
      // the features are for the context they were fetched for: the current
      // one (a response for an earlier context is dropped before here)
      final key = _keyFor(_repository?.clientContext.generateHeader());
      if (key != _storageKey) {
        _storageKey = key;
        _store = {};
      }
    }
    switch (update) {
      case FeaturesReceived(:final features):
        _store = {for (final f in features) f.id: f};
      case FeatureReceived(:final feature):
        _store[feature.id] = feature;
      case FeatureDeleted(:final key):
        _store.removeWhere((_, f) => f.key == key);
    }
    _persist();
  }

  void _persist() {
    final key = _storageKey;
    if (key == null) return;
    try {
      _storage.setItem(
        key,
        jsonEncode({for (final e in _store.entries) e.key: e.value.toJson()}),
      );
    } catch (e) {
      // e.g. storage full or disabled: the application still works
      _log.warning('Unable to store features: $e');
    }
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
