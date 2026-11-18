/// The floors on reconnection delays. Not exported: they may be lowered by
/// this package's own tests only (importing this file directly), never by
/// applications, so that no configuration makes a tight reconnect loop.
library;

/// The shortest wait before any reconnection attempt, whatever the reconnect
/// policy or the server says. Policy delays and caps below it are raised to
/// it.
Duration minReconnectDelay = defaultMinReconnectDelay;

/// The default [minReconnectDelay].
const defaultMinReconnectDelay = Duration(milliseconds: 100);

/// The shortest a server's `retry:` field may set the reconnection time to
/// (`retry: 10` would otherwise reconnect every 10ms).
Duration minServerRetryDelay = defaultMinServerRetryDelay;

/// The default [minServerRetryDelay].
const defaultMinServerRetryDelay = Duration(seconds: 1);
