import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/icon_cache.dart';

/// A real 1x1 transparent PNG, the shape the engine emits for app icons.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB'
    '0C8AAAAASUVORK5CYII=';

const String _pngDataUri = 'data:image/png;base64,$_pngBase64';

final Uint8List _pngBytes = base64.decode(_pngBase64);

/// A distinct-but-still-valid PNG per [index]: bytes after `IEND` are ignored by
/// decoders, so each icon differs only in its cache key.
String _iconFor(int index) {
  final Uint8List bytes = Uint8List.fromList(<int>[
    ..._pngBytes,
    index & 0xFF,
    (index >> 8) & 0xFF,
  ]);
  return 'data:image/png;base64,${base64.encode(bytes)}';
}

void main() {
  group('IconCache decoding', () {
    test('decodes a data URI to the PNG bytes', () {
      expect(IconCache().bytesFor(_pngDataUri), _pngBytes);
    });

    test('decodes raw base64 with no marker at all', () {
      expect(IconCache().bytesFor(_pngBase64), _pngBytes);
    });

    test('finds the base64 marker whatever the media type says', () {
      expect(
        IconCache().bytesFor(
          'data:application/octet-stream;base64,$_pngBase64',
        ),
        _pngBytes,
      );
    });

    test('tolerates whitespace inside the payload', () {
      final String wrapped = _pngBase64.replaceRange(20, 20, '\r\n  ');

      expect(IconCache().bytesFor('data:image/png;base64,$wrapped'), _pngBytes);
    });

    test('returns null for null, empty and marker-only input', () {
      final IconCache cache = IconCache();

      expect(cache.bytesFor(null), isNull);
      expect(cache.bytesFor(''), isNull);
      expect(cache.bytesFor('data:image/png;base64,'), isNull);
    });

    test('returns null for input that is not base64', () {
      expect(
        IconCache().bytesFor('data:image/png;base64,not-base-64!!'),
        isNull,
      );
    });

    test('returns null for base64 that is not an image', () {
      final String text = base64.encode(utf8.encode('definitely not a png'));

      expect(IconCache().bytesFor('data:image/png;base64,$text'), isNull);
    });

    test('does not cache anything it could not decode', () {
      final IconCache cache = IconCache();

      cache.bytesFor('data:image/png;base64,not-base-64!!');

      expect(cache.length, 0);
    });

    test('exposes a stable image provider over the same bytes', () {
      final IconCache cache = IconCache();

      final MemoryImage? image = cache.imageFor(_pngDataUri);

      expect(image, isNotNull);
      expect(image!.bytes, same(cache.bytesFor(_pngDataUri)));
      expect(cache.imageFor(_pngDataUri), same(image));
    });
  });

  group('IconCache keys', () {
    test('hashes the whole input as uppercase SHA-1 hex', () {
      expect(
        IconCache.keyFor('abc'),
        'A9993E364706816ABA3E25717850C26C9CD0D89D',
      );
    });

    test('keys the full string, not just the base64 payload', () {
      expect(
        IconCache.keyFor('data:image/png;base64,$_pngBase64'),
        isNot(IconCache.keyFor(_pngBase64)),
      );
    });
  });

  group('IconCache hits and misses', () {
    test('returns the identical list for a repeated lookup', () {
      final IconCache cache = IconCache();

      expect(cache.bytesFor(_pngDataUri), same(cache.bytesFor(_pngDataUri)));
      expect(cache.length, 1);
    });

    test('decodes each distinct icon exactly once', () {
      final IconCache cache = IconCache();

      cache.bytesFor(_iconFor(1));
      cache.bytesFor(_iconFor(2));
      cache.bytesFor(_iconFor(1));

      expect(cache.length, 2);
    });

    test(
      'treats a different prefix on the same payload as a different icon',
      () {
        final IconCache cache = IconCache();

        cache.bytesFor(_pngDataUri);
        cache.bytesFor(_pngBase64);

        expect(cache.length, 2);
      },
    );

    test('clear drops every entry', () {
      final IconCache cache = IconCache();
      final Uint8List? before = cache.bytesFor(_pngDataUri);

      cache.clear();

      expect(cache.length, 0);
      expect(cache.bytesFor(_pngDataUri), isNot(same(before)));
    });
  });

  group('IconCache eviction', () {
    test('holds at most 128 icons by default', () {
      final IconCache cache = IconCache();

      for (int i = 0; i < IconCache.defaultCapacity + 40; i++) {
        cache.bytesFor(_iconFor(i));
      }

      expect(cache.length, IconCache.defaultCapacity);
    });

    test('evicts the least recently used icon past the 128th', () {
      final IconCache cache = IconCache();
      final Uint8List? oldest = cache.bytesFor(_iconFor(0));
      for (int i = 1; i < IconCache.defaultCapacity; i++) {
        cache.bytesFor(_iconFor(i));
      }
      expect(cache.length, IconCache.defaultCapacity);

      // The 129th icon pushes icon 0, untouched the longest, out.
      cache.bytesFor(_iconFor(IconCache.defaultCapacity));

      expect(cache.length, IconCache.defaultCapacity);
      expect(cache.bytesFor(_iconFor(0)), isNot(same(oldest)));
    });

    test('a lookup makes an icon the most recent again', () {
      final IconCache cache = IconCache(capacity: 3);
      final Uint8List? first = cache.bytesFor(_iconFor(1));
      cache.bytesFor(_iconFor(2));
      cache.bytesFor(_iconFor(3));

      // Touch icon 1 so icon 2 becomes the eviction victim instead.
      expect(cache.bytesFor(_iconFor(1)), same(first));
      cache.bytesFor(_iconFor(4));

      expect(cache.length, 3);
      expect(cache.bytesFor(_iconFor(1)), same(first));
    });

    test('honours a custom capacity', () {
      final IconCache cache = IconCache(capacity: 2);

      for (int i = 0; i < 5; i++) {
        cache.bytesFor(_iconFor(i));
      }

      expect(cache.length, 2);
    });
  });
}
