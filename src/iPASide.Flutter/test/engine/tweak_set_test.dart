import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/models.dart';
import 'package:ipaside/engine/tweak_set.dart';

TweakDylib _dylib(String? path, {String? name}) =>
    TweakDylib(path: path, name: name ?? path);

List<String?> _paths(List<TweakDylib> dylibs) =>
    dylibs.map((TweakDylib dylib) => dylib.path).toList();

void main() {
  group('TweakSet.mergeDistinctByPath', () {
    test('appends new paths after the existing ones, in order', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        <TweakDylib>[_dylib('/a.dylib'), _dylib('/b.dylib')],
        <TweakDylib>[_dylib('/c.dylib'), _dylib('/d.dylib')],
      );
      expect(
        _paths(merged),
        <String>['/a.dylib', '/b.dylib', '/c.dylib', '/d.dylib'],
      );
    });

    test('drops an incoming duplicate of an existing path', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        <TweakDylib>[_dylib('/a.dylib', name: 'first')],
        <TweakDylib>[_dylib('/a.dylib', name: 'second'), _dylib('/b.dylib')],
      );
      expect(_paths(merged), <String>['/a.dylib', '/b.dylib']);
      expect(merged.first.name, 'first', reason: 'existing entry is kept as-is');
    });

    test('collapses duplicates inside the incoming list', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        const <TweakDylib>[],
        <TweakDylib>[
          _dylib('/a.dylib', name: 'first'),
          _dylib('/a.dylib', name: 'second'),
        ],
      );
      expect(_paths(merged), <String>['/a.dylib']);
      expect(merged.single.name, 'first');
    });

    test('compares paths exactly, so case and separators matter', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        <TweakDylib>[_dylib(r'C:\tweaks\A.dylib')],
        <TweakDylib>[_dylib(r'c:\tweaks\a.dylib')],
      );
      expect(_paths(merged), <String>[r'C:\tweaks\A.dylib', r'c:\tweaks\a.dylib']);
    });

    test('keeps every existing entry, including path-less ones', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        <TweakDylib>[_dylib(null, name: 'broken'), _dylib('/a.dylib')],
        const <TweakDylib>[],
      );
      expect(_paths(merged), <String?>[null, '/a.dylib']);
    });

    test('drops incoming entries without a path', () {
      final List<TweakDylib> merged = TweakSet.mergeDistinctByPath(
        const <TweakDylib>[],
        <TweakDylib>[_dylib(null, name: 'broken'), _dylib('/a.dylib')],
      );
      expect(_paths(merged), <String>['/a.dylib']);
    });

    test('merging two empty sets yields an empty set', () {
      expect(
        TweakSet.mergeDistinctByPath(
          const <TweakDylib>[],
          const <TweakDylib>[],
        ),
        isEmpty,
      );
    });

    test('does not alias either input list', () {
      final List<TweakDylib> existing = <TweakDylib>[_dylib('/a.dylib')];
      final List<TweakDylib> merged =
          TweakSet.mergeDistinctByPath(existing, <TweakDylib>[_dylib('/b.dylib')]);
      expect(existing, hasLength(1));
      expect(merged, hasLength(2));
    });
  });
}
