// Ported from iPASide.App/Services/IconCache.cs.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';

/// Decodes the engine's icon strings (`data:image/png;base64,...`; the engine
/// already normalizes CgBI PNGs) exactly once, keyed by the SHA-1 of the string,
/// and hands back bytes or a ready [MemoryImage].
///
/// Every lookup is synchronous and allocation-free on a hit, so it is safe to
/// call straight from a `build` method. A small LRU bounds memory. No locking is
/// needed - unlike the C# original, all callers share one isolate.
class IconCache {
  /// Creates a cache holding at most [capacity] decoded icons.
  IconCache({this.capacity = defaultCapacity}) : assert(capacity > 0);

  /// Default entry ceiling, matching the C# cache.
  static const int defaultCapacity = 128;

  static const String _base64Marker = 'base64,';

  /// Maximum number of decoded icons retained; the least recently used is
  /// evicted past this.
  final int capacity;

  // Insertion-ordered, most recently used LAST, so the eviction victim is always
  // the first key.
  final LinkedHashMap<String, _IconEntry> _entries =
      LinkedHashMap<String, _IconEntry>();

  /// Number of icons currently held.
  int get length => _entries.length;

  /// The cached (or newly decoded) PNG bytes for [iconData].
  ///
  /// Null for a missing icon or undecodable data, so callers fall back to their
  /// placeholder glyph instead of crashing. Repeated calls with the same string
  /// return the identical list.
  Uint8List? bytesFor(String? iconData) => _lookup(iconData)?.bytes;

  /// The cached (or newly decoded) image provider for [iconData].
  ///
  /// Null under the same conditions as [bytesFor]. The provider instance is
  /// stable per icon, which keeps Flutter's own image cache from re-resolving it
  /// on every rebuild.
  MemoryImage? imageFor(String? iconData) => _lookup(iconData)?.image;

  /// Drops every entry.
  void clear() => _entries.clear();

  /// The cache key for [iconData]: uppercase SHA-1 hex of the whole string,
  /// matching the C# `Convert.ToHexString(SHA1.HashData(...))`.
  static String keyFor(String iconData) =>
      sha1.convert(utf8.encode(iconData)).toString().toUpperCase();

  _IconEntry? _lookup(String? iconData) {
    if (iconData == null || iconData.isEmpty) return null;

    final String key = keyFor(iconData);
    final _IconEntry? cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached; // re-inserted as most recently used
      return cached;
    }

    final Uint8List? bytes = _decode(iconData);
    if (bytes == null) return null;

    final _IconEntry entry = _IconEntry(bytes);
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return entry;
  }

  static Uint8List? _decode(String iconData) {
    String payload = iconData;
    final int marker = payload.indexOf(_base64Marker);
    if (marker >= 0) payload = payload.substring(marker + _base64Marker.length);

    // Convert.FromBase64String ignored whitespace; Dart's decoder does not.
    payload = payload.replaceAll(_whitespace, '');
    if (payload.isEmpty) return null;

    try {
      final Uint8List bytes = base64.decode(payload);
      // The C# cache let Avalonia reject non-images while decoding. Flutter only
      // decodes asynchronously, and an undecodable payload would surface as an
      // error widget rather than a null, so the format is checked here instead.
      return _isSupportedImage(bytes) ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  static final RegExp _whitespace = RegExp(r'\s');

  static bool _isSupportedImage(Uint8List bytes) =>
      _startsWith(bytes, _pngSignature) ||
      _startsWith(bytes, _jpegSignature) ||
      _startsWith(bytes, _gifSignature) ||
      _startsWith(bytes, _bmpSignature) ||
      _isWebP(bytes);

  static const List<int> _pngSignature = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];
  static const List<int> _jpegSignature = <int>[0xFF, 0xD8, 0xFF];
  static const List<int> _gifSignature = <int>[0x47, 0x49, 0x46, 0x38]; // GIF8
  static const List<int> _bmpSignature = <int>[0x42, 0x4D]; // BM
  static const List<int> _riffSignature = <int>[0x52, 0x49, 0x46, 0x46]; // RIFF
  static const List<int> _webpSignature = <int>[0x57, 0x45, 0x42, 0x50]; // WEBP

  static bool _isWebP(Uint8List bytes) =>
      _startsWith(bytes, _riffSignature) &&
      _startsWith(bytes, _webpSignature, offset: 8);

  static bool _startsWith(
    Uint8List bytes,
    List<int> signature, {
    int offset = 0,
  }) {
    if (bytes.length < offset + signature.length) return false;
    for (int i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }
}

class _IconEntry {
  _IconEntry(this.bytes) : image = MemoryImage(bytes);

  final Uint8List bytes;
  final MemoryImage image;
}
