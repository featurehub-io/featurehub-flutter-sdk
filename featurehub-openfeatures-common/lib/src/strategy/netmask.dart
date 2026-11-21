import 'dart:math' as math;

/// IPv4 network block matching, ported from the `netmask` npm package
/// (2.0.2) used by the TypeScript SDK so that IP address strategies match the
/// same addresses on every platform.
///
/// Like the npm package, addresses may be written in dotted quad notation, or
/// in the shorter long / class A / class B notations, and each part may be
/// decimal, octal (leading `0`) or hexadecimal (leading `0x`).
class Netmask {
  late final int _netLong;
  late final int _maskLong;
  late final int bitmask;

  /// Parses `net`, e.g. `10.0.0.0/8`, `192.168.1.0/255.255.255.0` or a single
  /// address (a `/32`). Throws a [FormatException] if it is invalid.
  Netmask(String net, [String? mask]) {
    var n = net;
    var m = mask;
    if (m == null || m.isEmpty) {
      final slash = n.indexOf('/');
      if (slash >= 0) {
        m = n.substring(slash + 1);
        n = n.substring(0, slash);
        // the npm package uses split('/', 2), which drops anything after a
        // second slash
        final second = m.indexOf('/');
        if (second >= 0) m = m.substring(0, second);
      }
    }

    if (m == null || m.isEmpty) {
      bitmask = 32;
      _maskLong = 0xffffffff;
    } else if (m.contains('.')) {
      final int maskLong;
      try {
        maskLong = ip2long(m);
      } on FormatException {
        throw FormatException('Invalid mask: $m');
      }
      int? bits;
      for (var i = 32; i >= 0; i--) {
        if (maskLong == _jsShl(0xffffffff, 32 - i)) {
          bits = i;
          break;
        }
      }
      if (bits == null) {
        // the npm package leaves the bitmask undefined, and then rejects it
        throw FormatException('Invalid mask for ip4: $m');
      }
      bitmask = bits;
      _maskLong = maskLong;
    } else {
      final bits = _jsParseInt(m);
      if (bits == null || bits < 0) {
        throw FormatException('Invalid mask: $m');
      }
      bitmask = bits;
      _maskLong = bits > 0 ? _jsShl(0xffffffff, 32 - bits) : 0;
    }

    try {
      _netLong = ip2long(n) & _maskLong;
    } on FormatException {
      throw FormatException('Invalid net address: $n');
    }

    if (bitmask > 32) {
      throw FormatException('Invalid mask for ip4: $m');
    }
  }

  int get _size => math.pow(2, 32 - bitmask).toInt();

  /// The network address of the block.
  String get base => long2ip(_netLong);

  /// The block's broadcast address, or null for a /31 or /32.
  String? get broadcast => bitmask <= 30 ? long2ip(_netLong + _size - 1) : null;

  /// The last usable address of the block.
  String get last => bitmask <= 30
      ? long2ip(_netLong + _size - 2)
      : long2ip(_netLong + _size - 1);

  /// True if [ip] (an address, or a block such as `10.1.0.0/16`) is within
  /// this block. Throws a [FormatException] if [ip] is invalid.
  bool contains(String ip) {
    if (ip.indexOf('/') > 0 || ip.split('.').length != 4) {
      final other = Netmask(ip);
      return contains(other.base) && contains(other.broadcast ?? other.last);
    }
    return (ip2long(ip) & _maskLong) == (_netLong & _maskLong);
  }

  @override
  String toString() => '$base/$bitmask';
}

/// Converts an IPv4 address to its unsigned 32-bit value.
int ip2long(String ip) {
  final b = <int>[];
  var rest = ip;
  for (var i = 0; i <= 3; i++) {
    if (rest.isEmpty) break;
    if (i > 0) {
      if (rest[0] != '.') throw const FormatException('Invalid IP');
      rest = rest.substring(1);
    }
    final (n, consumed) = _atob(rest);
    rest = rest.substring(consumed);
    b.add(n);
  }
  if (rest.isNotEmpty) throw const FormatException('Invalid IP');

  switch (b.length) {
    case 1:
      if (b[0] > 0xffffffff) throw const FormatException('Invalid IP');
      return b[0];
    case 2:
      if (b[0] > 0xff || b[1] > 0xffffff) {
        throw const FormatException('Invalid IP');
      }
      return ((b[0] << 24) | b[1]) & 0xffffffff;
    case 3:
      if (b[0] > 0xff || b[1] > 0xff || b[2] > 0xffff) {
        throw const FormatException('Invalid IP');
      }
      return ((b[0] << 24) | (b[1] << 16) | b[2]) & 0xffffffff;
    case 4:
      if (b[0] > 0xff || b[1] > 0xff || b[2] > 0xff || b[3] > 0xff) {
        throw const FormatException('Invalid IP');
      }
      return ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0xffffffff;
    default:
      throw const FormatException('Invalid IP');
  }
}

/// Converts an unsigned 32-bit value to a dotted quad.
String long2ip(int long) => [
  (long >>> 24) & 0xff,
  (long >>> 16) & 0xff,
  (long >>> 8) & 0xff,
  long & 0xff,
].join('.');

/// Parses one number from the start of [s]; returns the value and the number
/// of characters consumed.
(int, int) _atob(String s) {
  var n = 0;
  var base = 10;
  var dmax = 0x39; // '9'
  var i = 0;
  if (s.length > 1 && s[0] == '0') {
    if (s[1] == 'x' || s[1] == 'X') {
      i += 2;
      base = 16;
    } else if (_isDigit(s.codeUnitAt(1))) {
      i++;
      base = 8;
      dmax = 0x37; // '7'
    }
  }
  final start = i;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c >= 0x30 && c <= dmax) {
      n = n * base + (c - 0x30);
    } else if (base == 16 && c >= 0x61 && c <= 0x66) {
      n = n * base + (10 + c - 0x61);
    } else if (base == 16 && c >= 0x41 && c <= 0x46) {
      n = n * base + (10 + c - 0x41);
    } else {
      break;
    }
    if (n > 0xffffffff) throw const FormatException('too large');
    i++;
  }
  if (i == start) throw const FormatException('empty octet');
  return (n, i);
}

/// JavaScript's `(value << count) >>> 0`: the shift count is taken modulo 32.
int _jsShl(int value, int count) => (value << (count & 31)) & 0xffffffff;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// JavaScript `parseInt(s, 10)`: leading whitespace and sign, then digits.
int? _jsParseInt(String s) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  return match == null ? null : int.parse(match.group(1)!);
}
