import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/json_utils.dart';

void main() {
  group('tryDecodeJsonObject', () {
    test('decodes a frame object', () {
      expect(
        tryDecodeJsonObject('{"id":1,"type":"result","ok":true}'),
        <String, dynamic>{'id': 1, 'type': 'result', 'ok': true},
      );
    });

    test('rejects blank input', () {
      expect(tryDecodeJsonObject(''), isNull);
      expect(tryDecodeJsonObject('   \t'), isNull);
    });

    test('rejects malformed JSON', () {
      expect(tryDecodeJsonObject('{"id":1'), isNull);
      expect(tryDecodeJsonObject('WARNING: something happened'), isNull);
    });

    test('rejects valid JSON that is not an object', () {
      expect(tryDecodeJsonObject('[1,2,3]'), isNull);
      expect(tryDecodeJsonObject('"ready"'), isNull);
      expect(tryDecodeJsonObject('null'), isNull);
      expect(tryDecodeJsonObject('7'), isNull);
    });
  });

  group('asJsonObject', () {
    test('passes an object through and rejects everything else', () {
      expect(asJsonObject(<String, dynamic>{'a': 1}), isNotNull);
      expect(asJsonObject(<dynamic>[]), isNull);
      expect(asJsonObject('a'), isNull);
      expect(asJsonObject(null), isNull);
    });
  });

  group('field readers', () {
    const Map<String, dynamic> json = <String, dynamic>{
      'text': 'hello',
      'flag': true,
      'count': 3,
      'ratio': 1.5,
      'nothing': null,
      'wrong': <dynamic>[],
    };

    test('jsonString reads strings only', () {
      expect(jsonString(json, 'text'), 'hello');
      expect(jsonString(json, 'count'), isNull);
      expect(jsonString(json, 'nothing'), isNull);
      expect(jsonString(json, 'absent'), isNull);
    });

    test('jsonBool reads booleans and falls back otherwise', () {
      expect(jsonBool(json, 'flag'), isTrue);
      expect(jsonBool(json, 'text'), isFalse);
      expect(jsonBool(json, 'absent'), isFalse);
      expect(jsonBool(json, 'absent', orElse: true), isTrue);
    });

    test('jsonDouble widens integers', () {
      expect(jsonDouble(json, 'count'), 3.0);
      expect(jsonDouble(json, 'ratio'), 1.5);
      expect(jsonDouble(json, 'text'), isNull);
      expect(jsonDouble(json, 'nothing'), isNull);
    });

    test('jsonInt reads integers and rounds a float', () {
      expect(jsonInt(json, 'count'), 3);
      expect(jsonInt(json, 'ratio'), 2, reason: '1.5 rounds away from zero');
      expect(jsonInt(json, 'text'), 0);
      expect(jsonInt(json, 'nothing'), 0);
      expect(jsonInt(json, 'absent'), 0);
      expect(jsonInt(json, 'absent', orElse: -1), -1);
    });

    test('jsonInt keeps a large byte count exact', () {
      // Byte totals run past what a float can hold exactly; an int must not be
      // routed through one.
      expect(
        jsonInt(<String, dynamic>{'bytes': 9007199254740993}, 'bytes'),
        9007199254740993,
      );
    });

    test('jsonDateTime parses ISO 8601 and rejects the rest', () {
      expect(
        jsonDateTime(
          <String, dynamic>{'at': '2026-07-25T12:00:00Z'},
          'at',
        ),
        DateTime.utc(2026, 7, 25, 12),
      );
      expect(
        jsonDateTime(<String, dynamic>{'at': '2026-07-25'}, 'at'),
        DateTime(2026, 7, 25),
      );
      expect(jsonDateTime(<String, dynamic>{'at': 'yesterday'}, 'at'), isNull);
      expect(jsonDateTime(json, 'count'), isNull);
      expect(jsonDateTime(json, 'nothing'), isNull);
      expect(jsonDateTime(json, 'absent'), isNull);
    });

    test('jsonStringList skips non-strings', () {
      expect(
        jsonStringList(
          <String, dynamic>{
            'items': <dynamic>['a', 1, null, 'b'],
          },
          'items',
        ),
        <String>['a', 'b'],
      );
      expect(jsonStringList(json, 'text'), isEmpty);
      expect(jsonStringList(json, 'absent'), isEmpty);
    });

    test('jsonObjectList skips non-objects', () {
      final List<String?> names = jsonObjectList(
        <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{'name': 'a'},
            'skip me',
            <String, dynamic>{'name': 'b'},
          ],
        },
        'items',
        (Map<String, dynamic> item) => jsonString(item, 'name'),
      );

      expect(names, <String>['a', 'b']);
      expect(
        jsonObjectList(json, 'absent', (Map<String, dynamic> _) => 1),
        isEmpty,
      );
    });
  });
}
