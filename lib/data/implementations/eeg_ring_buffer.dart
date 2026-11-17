import 'dart:typed_data';

/// Fixed-capacity circular buffer backed by an unboxed [Float64List].
///
/// Eliminates per-sample heap allocations and pointer chasing (`ListQueue<double>`,
/// `.toList()`, `.sublist()`) during 128–256 Hz EEG streaming on long meditation
/// sessions.
class EegFloat64RingBuffer {
  Float64List _data;
  int _head = 0;
  int _length = 0;

  EegFloat64RingBuffer(int capacity)
      : _data = Float64List(capacity < 1 ? 1 : capacity);

  int get capacity => _data.length;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length > 0;

  bool get isFull => _length == _data.length;

  /// Appends [value] in O(1) without heap allocation, overwriting the oldest
  /// sample once [capacity] is reached.
  void push(double value) {
    final cap = _data.length;
    if (_length < cap) {
      _data[(_head + _length) % cap] = value;
      _length++;
    } else {
      _data[_head] = value;
      _head = (_head + 1) % cap;
    }
  }

  /// Appends a batch of [values] (`[offset .. offset + count)`).
  void pushAll(List<double> values, [int offset = 0, int? count]) {
    final n = count ?? (values.length - offset);
    for (var i = 0; i < n; i++) {
      push(values[offset + i]);
    }
  }

  /// Chronological element access (`0` = oldest, `length - 1` = newest).
  double operator [](int index) {
    assert(index >= 0 && index < _length);
    return _data[(_head + index) % _data.length];
  }

  /// Ensures [capacity] matches [newCapacity], preserving the most recent
  /// samples when resizing.
  void ensureCapacity(int newCapacity) {
    final safeCap = newCapacity < 1 ? 1 : newCapacity;
    if (safeCap == _data.length) return;
    final next = Float64List(safeCap);
    final keep = _length < safeCap ? _length : safeCap;
    final skip = _length - keep;
    for (var i = 0; i < keep; i++) {
      next[i] = this[skip + i];
    }
    _data = next;
    _head = 0;
    _length = keep;
  }

  /// Copies the buffered samples in chronological order (`oldest -> newest`)
  /// into [scratch] when its length matches [length], or allocates a single
  /// contiguous [Float64List].
  Float64List toFloat64List([Float64List? scratch]) {
    final n = _length;
    final out = (scratch != null && scratch.length == n)
        ? scratch
        : Float64List(n);
    if (n == 0) return out;
    final cap = _data.length;
    final firstSpan = cap - _head;
    if (n <= firstSpan) {
      out.setRange(0, n, _data, _head);
    } else {
      out.setRange(0, firstSpan, _data, _head);
      out.setRange(firstSpan, n, _data, 0);
    }
    return out;
  }

  /// Resets the logical length to zero while retaining the backing array.
  void clear() {
    _head = 0;
    _length = 0;
  }
}
