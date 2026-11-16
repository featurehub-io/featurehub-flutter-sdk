/// Helpers that reproduce the JavaScript conversions the TypeScript SDK's
/// strategy matching relies on, so that Dart evaluates strategies identically.
library;

/// JavaScript's `value.toString()` for the primitive values that appear in
/// strategies and contexts. Most importantly, a whole-number double prints
/// without a fractional part (`1.0` -> `"1"`), as JSON numbers do in JS.
String jsToString(Object value) {
  if (value is double) {
    if (value.isNaN) return 'NaN';
    if (value.isInfinite) return value > 0 ? 'Infinity' : '-Infinity';
    if (value == value.truncateToDouble() && value.abs() < 1e21) {
      return value.toInt().toString();
    }
  }
  return value.toString();
}

/// JavaScript's `Number(s)`: the whole (trimmed) string must be numeric;
/// an empty string is 0, anything else invalid is NaN.
double jsNumber(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  if (t == 'Infinity' || t == '+Infinity') return double.infinity;
  if (t == '-Infinity') return double.negativeInfinity;
  final hex = RegExp(r'^0[xX]([0-9a-fA-F]+)$').firstMatch(t);
  if (hex != null) return int.parse(hex.group(1)!, radix: 16).toDouble();
  final bin = RegExp(r'^0[bB]([01]+)$').firstMatch(t);
  if (bin != null) return int.parse(bin.group(1)!, radix: 2).toDouble();
  final oct = RegExp(r'^0[oO]([0-7]+)$').firstMatch(t);
  if (oct != null) return int.parse(oct.group(1)!, radix: 8).toDouble();
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(t)) {
    return double.nan;
  }
  return double.parse(t);
}

/// JavaScript's `parseFloat(s)`: the longest numeric prefix after leading
/// whitespace, or NaN.
double jsParseFloat(String s) {
  final t = s.trimLeft();
  final inf = RegExp(r'^([+-]?)Infinity').firstMatch(t);
  if (inf != null) {
    return inf.group(1) == '-' ? double.negativeInfinity : double.infinity;
  }
  final match = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').firstMatch(t);
  return match == null ? double.nan : double.parse(match.group(0)!);
}

/// JavaScript's `parseInt(s, 10)`: leading whitespace, sign, then digits;
/// NaN if there are none.
num jsParseInt(String s) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  return match == null ? double.nan : int.parse(match.group(1)!);
}

/// The `semver-compare` npm package (1.0.0): compares the first three
/// dot-separated parts numerically. Returns 1, -1 or 0.
int semverCompare(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  for (var i = 0; i < 3; i++) {
    final na = i < pa.length ? jsNumber(pa[i]) : double.nan;
    final nb = i < pb.length ? jsNumber(pb[i]) : double.nan;
    if (na > nb) return 1;
    if (nb > na) return -1;
    if (!na.isNaN && nb.isNaN) return 1;
    if (na.isNaN && !nb.isNaN) return -1;
  }
  return 0;
}
