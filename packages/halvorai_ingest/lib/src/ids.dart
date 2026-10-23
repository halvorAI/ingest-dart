import 'dart:math';

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _random = Random.secure();

int _lastTime = -1;
final _lastRandom = List<int>.filled(16, 0);

/// A new event id: `evt_` plus a monotonic ULID, as the TypeScript SDK's `newId('evt')`.
String newEventId() => 'evt_${_ulid(DateTime.now().millisecondsSinceEpoch)}';

/// Monotonic so ids made in the same millisecond still sort in creation order. Uses only
/// division and modulo so it stays exact on the web, where bitwise ops are 32-bit.
String _ulid(int now) {
  if (now <= _lastTime) {
    // Same (or earlier) millisecond: increment the previous random part instead.
    var i = _lastRandom.length - 1;
    while (i >= 0 && _lastRandom[i] == 31) {
      _lastRandom[i] = 0;
      i--;
    }
    if (i < 0) {
      // 80 random bits overflowed within one millisecond; move to the next one.
      _lastTime++;
      _fillRandom();
    } else {
      _lastRandom[i]++;
    }
  } else {
    _lastTime = now;
    _fillRandom();
  }

  final chars = List<String>.filled(26, '0');
  var t = _lastTime;
  for (var i = 9; i >= 0; i--) {
    chars[i] = _crockford[t % 32];
    t ~/= 32;
  }
  for (var i = 0; i < 16; i++) {
    chars[10 + i] = _crockford[_lastRandom[i]];
  }
  return chars.join();
}

void _fillRandom() {
  for (var i = 0; i < _lastRandom.length; i++) {
    _lastRandom[i] = _random.nextInt(32);
  }
}
