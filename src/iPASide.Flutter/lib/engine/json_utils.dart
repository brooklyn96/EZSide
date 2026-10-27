// Tolerant JSON readers shared by the engine layer's hand-written `fromJson`
// factories and by the NDJSON frame parsing in `EngineClient`.
//
// Nothing here fuzzy-matches key names: the engine mixes conventions (lockdown
// values are PascalCase, inventory values are snake_case), so callers always
// pass the exact wire key. A missing or wrongly-typed value degrades to
// null/false/empty instead of throwing, because a single odd field from a newer
// engine build must never take down a whole screen.

import 'dart:convert';

/// Returns [value] as a JSON object, or null when it is anything else.
Map<String, dynamic>? asJsonObject(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// Decodes one NDJSON line, returning it only when it is a JSON *object*.
///
/// Blank lines, malformed JSON, and valid-but-non-object JSON (arrays, bare
/// scalars) all yield null: the stdio protocol only ever frames objects, so
/// anything else is noise a library printed onto the wrong stream.
Map<String, dynamic>? tryDecodeJsonObject(String raw) {
  if (raw.trim().isEmpty) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// Reads a string field; a missing or non-string value counts as absent.
String? jsonString(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is String ? value : null;
}

/// Reads a boolean field; anything that is not a JSON boolean yields [orElse].
bool jsonBool(Map<String, dynamic> json, String key, {bool orElse = false}) {
  final Object? value = json[key];
  return value is bool ? value : orElse;
}

/// Reads a numeric field as a double, accepting JSON integers.
double? jsonDouble(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is num ? value.toDouble() : null;
}

/// Reads a counter field as an int, rounding a JSON double.
///
/// Counts and byte totals are integers on the wire, but a Python `float` (a
/// division that stayed a float, an exponent form) still has to land on a
/// usable number rather than blank out the figure it belongs to; anything that
/// is not a number at all yields [orElse].
int jsonInt(Map<String, dynamic> json, String key, {int orElse = 0}) {
  final Object? value = json[key];
  if (value is int) return value;
  if (value is double && value.isFinite) return value.round();
  return orElse;
}

/// Reads an ISO 8601 timestamp field.
///
/// A missing, non-string or unparseable value counts as absent, so one odd
/// timestamp cannot cost the caller the record it was attached to.
DateTime? jsonDateTime(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  return value is String ? DateTime.tryParse(value) : null;
}

/// Reads a nested object, yielding an empty map when it is absent or not an object.
///
/// Never null, for the same reason list-valued fields are not: a `fromJson`
/// factory can recurse straight into it, and a nested model built from an empty
/// map is exactly its all-defaults value.
Map<String, dynamic> jsonObject(Map<String, dynamic> json, String key) =>
    asJsonObject(json[key]) ?? const <String, dynamic>{};

/// Reads an array of strings, dropping any entry that is not a string.
List<String> jsonStringList(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is! List) {
    return const <String>[];
  }
  return <String>[
    for (final Object? item in value)
      if (item is String) item,
  ];
}

/// Reads an array of JSON objects, mapping each one through [fromJson].
List<T> jsonObjectList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic> json) fromJson,
) {
  final Object? value = json[key];
  if (value is! List) {
    return <T>[];
  }
  return <T>[
    for (final Object? item in value)
      if (item is Map<String, dynamic>) fromJson(item),
  ];
}
