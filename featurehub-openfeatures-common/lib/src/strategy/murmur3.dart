import 'dart:convert';

/// MurmurHash3 (x86, 32-bit) of [key] encoded as UTF-8.
///
/// This must produce exactly the same value as the `murmurhash` npm package's
/// `v3` function (and the other FeatureHub SDKs), otherwise percentage
/// rollouts would place the same user in different buckets on different
/// platforms.
int murmur3String(String key, [int seed = 0]) =>
    murmur3Bytes(utf8.encode(key), seed);

/// MurmurHash3 (x86, 32-bit) of [key]. Returns an unsigned 32-bit value.
int murmur3Bytes(List<int> key, [int seed = 0]) {
  const c1 = 0xcc9e2d51;
  const c2 = 0x1b873593;

  final length = key.length;
  final remainder = length & 3;
  final bytes = length - remainder;

  var h1 = seed & 0xffffffff;
  var i = 0;

  while (i < bytes) {
    var k1 =
        (key[i] & 0xff) |
        ((key[i + 1] & 0xff) << 8) |
        ((key[i + 2] & 0xff) << 16) |
        ((key[i + 3] & 0xff) << 24);
    i += 4;

    k1 = _mul32(k1, c1);
    k1 = _rotl32(k1, 15);
    k1 = _mul32(k1, c2);

    h1 ^= k1;
    h1 = _rotl32(h1, 13);
    h1 = (_mul32(h1, 5) + 0xe6546b64) & 0xffffffff;
  }

  var k1 = 0;
  switch (remainder) {
    case 3:
      k1 ^= (key[i + 2] & 0xff) << 16;
      k1 ^= (key[i + 1] & 0xff) << 8;
      k1 ^= key[i] & 0xff;
    case 2:
      k1 ^= (key[i + 1] & 0xff) << 8;
      k1 ^= key[i] & 0xff;
    case 1:
      k1 ^= key[i] & 0xff;
  }
  if (remainder > 0) {
    k1 = _mul32(k1, c1);
    k1 = _rotl32(k1, 15);
    k1 = _mul32(k1, c2);
    h1 ^= k1;
  }

  h1 ^= length;

  h1 ^= h1 >>> 16;
  h1 = _mul32(h1, 0x85ebca6b);
  h1 ^= h1 >>> 13;
  h1 = _mul32(h1, 0xc2b2ae35);
  h1 ^= h1 >>> 16;

  return h1 & 0xffffffff;
}

/// 32-bit multiply, done in 16-bit halves so that it is exact on every
/// platform (including the web, where integers are doubles).
int _mul32(int a, int b) {
  a &= 0xffffffff;
  b &= 0xffffffff;
  final low = (a & 0xffff) * b;
  final high = (((a >>> 16) * b) & 0xffff) << 16;
  return (low + high) & 0xffffffff;
}

int _rotl32(int x, int r) {
  x &= 0xffffffff;
  return ((x << r) | (x >>> (32 - r))) & 0xffffffff;
}
