/// RFC 3339 in UTC with milliseconds (`2026-10-23T09:14:03.218Z`), the only timestamp format
/// the SDK writes. `DateTime.toIso8601String` would add microseconds on the VM.
String formatUtc(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = t.year.toString().padLeft(4, '0');
  final ms = t.millisecond.toString().padLeft(3, '0');
  return '$year-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${ms}Z';
}

String nowUtc() => formatUtc(DateTime.now());
