/// The limits on FeatureHub streaming connections. Not exported: they may be
/// lowered by this package's own tests only (importing this file directly),
/// never by applications.
library;

/// A streaming connection that ends sooner than this after it opened, with
/// a `bye` or without, did not come from FeatureHub Edge working normally
/// (Edge only closes a connection itself at the end of its wait, 60 seconds
/// or more): typically a cache in front of Edge replaying a stream that is
/// already closed. It is a failed attempt, backed off as any other, and
/// nothing it delivered resets the count of failed attempts.
Duration shortConnectionThreshold = defaultShortConnectionThreshold;

/// The default [shortConnectionThreshold].
const defaultShortConnectionThreshold = Duration(seconds: 10);

/// How many short connections in a row are logged as a warning (once, until
/// a connection lasts).
const shortConnectionWarningAfter = 3;

/// How long FeatureHub Edge may keep a streaming connection open with nothing
/// to send, for a client whose `Last-Event-ID` is current. A read timeout
/// below it drops healthy connections.
const quietConnectionLimit = Duration(minutes: 5);

/// The warning logged after [shortConnectionWarningAfter] short connections.
String shortConnectionsWarning(int count) =>
    'featurehub: $count streaming connections in a row ended within '
    '${shortConnectionThreshold.inSeconds}s of opening. FeatureHub Edge does '
    'not end them that soon: something in front of it (a CDN, cache or proxy) '
    'is ending or replaying its event streams. Event streams must not be '
    'cached; the connection backs off meanwhile.';
