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

/// A NUMBER attribute's number: a finite [num] as is, or a string that is
/// exactly a decimal integer or float (an optional sign, digits, and an
/// optional fraction: `12`, `-5`, `2.5`). Anything else - `"12abc"`, `"1e3"`,
/// `"0x10"`, `".5"`, `" 3"`, `"Infinity"`, a boolean - is not a number, and
/// is null. Deliberately not JavaScript's parseInt / parseFloat.
num? strictNumber(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is! String || !_strictNumber.hasMatch(value)) return null;
  return value.contains('.') ? double.parse(value) : num.parse(value);
}

final _strictNumber = RegExp(r'^[+-]?[0-9]+(\.[0-9]+)?$');

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
