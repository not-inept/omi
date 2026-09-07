/// Remembering which transmitter recordings have already been imported.
///
/// A transmitter is not a queue: it is a 32 GB drive holding every take since
/// the last time it was formatted, and DJI's own advice is to format in the
/// device rather than delete files from a computer. So every time the user
/// opens the picker, the same forty recordings are sitting there, and the
/// import has to be able to say which of them Omi already has.
///
/// This is entirely app-side. The transmitter is never written to, never
/// renamed, never marked — that rule is inherited from the sibling desktop
/// tool `labs/dji-mic-controller`, which is read-only against the hardware for
/// the same reason: the recording on the mic is the only original.
///
/// Identity is `<file name>|<byte size>`. The filename alone carries the
/// transmitter's own timestamp and index and is unique in practice, but it is
/// also reused across a format, and size is what distinguishes a take that was
/// re-recorded into the same name. Nothing here reads file contents, so
/// deciding what is already imported never costs a read of a 250 MB file.
library;

import 'dart:convert';

/// One recording this app has taken a copy of.
class DjiMicImportRecord {
  final String fileName;
  final int sizeBytes;

  /// When the import finished, as milliseconds since the epoch, UTC.
  final int importedAtMs;

  /// How many WAL chunks the recording became. A 30-minute take is split into
  /// several so no single upload outlives the backend's job window; keeping
  /// the count makes "imported as 10 pieces" sayable in the UI, and makes a
  /// half-finished import visible as a count that does not match.
  final int chunkCount;

  /// The recording's real length in seconds, measured from its own header.
  final double durationSec;

  const DjiMicImportRecord({
    required this.fileName,
    required this.sizeBytes,
    required this.importedAtMs,
    required this.chunkCount,
    required this.durationSec,
  });

  DateTime get importedAt => DateTime.fromMillisecondsSinceEpoch(importedAtMs, isUtc: true);

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'importedAtMs': importedAtMs,
        'chunkCount': chunkCount,
        'durationSec': durationSec,
      };

  /// Returns null rather than throwing for anything malformed: this data is
  /// read at app start, and one bad row must not cost the user the rest of
  /// their import history (or a crash on launch).
  static DjiMicImportRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fileName = raw['fileName'];
    final sizeBytes = raw['sizeBytes'];
    if (fileName is! String || fileName.isEmpty) return null;
    if (sizeBytes is! int) return null;
    final importedAtMs = raw['importedAtMs'];
    final chunkCount = raw['chunkCount'];
    final durationSec = raw['durationSec'];
    return DjiMicImportRecord(
      fileName: fileName,
      sizeBytes: sizeBytes,
      importedAtMs: importedAtMs is int ? importedAtMs : 0,
      chunkCount: chunkCount is int ? chunkCount : 0,
      durationSec: durationSec is num ? durationSec.toDouble() : 0,
    );
  }
}

/// The identity a recording is remembered by.
String djiMicImportKey(String fileName, int sizeBytes) => '$fileName|$sizeBytes';

/// The set of imported recordings, as a value: every mutation returns a new
/// registry rather than editing in place, so persisting is always "write what
/// you were just handed" and there is no half-applied state to reason about.
class DjiMicImportRegistry {
  final Map<String, DjiMicImportRecord> _byKey;

  const DjiMicImportRegistry._(this._byKey);

  const DjiMicImportRegistry.empty() : _byKey = const {};

  int get length => _byKey.length;

  List<DjiMicImportRecord> get records => List.unmodifiable(_byKey.values);

  bool contains(String fileName, int sizeBytes) => _byKey.containsKey(djiMicImportKey(fileName, sizeBytes));

  DjiMicImportRecord? lookup(String fileName, int sizeBytes) => _byKey[djiMicImportKey(fileName, sizeBytes)];

  /// A re-import of the same recording replaces the earlier record rather than
  /// adding a second one — the user asked for it again, and the newest attempt
  /// is the one worth remembering.
  DjiMicImportRegistry withRecord(DjiMicImportRecord record) {
    final next = Map<String, DjiMicImportRecord>.from(_byKey);
    next[djiMicImportKey(record.fileName, record.sizeBytes)] = record;
    return DjiMicImportRegistry._(next);
  }

  /// Forgetting an import does not touch the transmitter or any conversation
  /// already created — it only makes the recording offerable again.
  DjiMicImportRegistry without(String fileName, int sizeBytes) {
    final next = Map<String, DjiMicImportRecord>.from(_byKey);
    next.remove(djiMicImportKey(fileName, sizeBytes));
    return DjiMicImportRegistry._(next);
  }

  /// Keeps the [limit] most recent records. A transmitter holds tens of hours
  /// of takes and this list is only ever an "already got it" check, so it is
  /// bounded rather than allowed to grow for the life of the install.
  DjiMicImportRegistry trimmedTo(int limit) {
    if (_byKey.length <= limit) return this;
    final sorted = _byKey.entries.toList()..sort((a, b) => b.value.importedAtMs.compareTo(a.value.importedAtMs));
    return DjiMicImportRegistry._(Map.fromEntries(sorted.take(limit)));
  }

  String encode() => jsonEncode(_byKey.values.map((r) => r.toJson()).toList());

  /// Never throws. A corrupt or hand-edited blob reads back as an empty
  /// registry, which costs the user a duplicate import at worst — where
  /// throwing would cost them the import screen entirely.
  static DjiMicImportRegistry decode(String? blob) {
    if (blob == null || blob.isEmpty) return const DjiMicImportRegistry.empty();
    Object? parsed;
    try {
      parsed = jsonDecode(blob);
    } catch (_) {
      return const DjiMicImportRegistry.empty();
    }
    if (parsed is! List) return const DjiMicImportRegistry.empty();
    final map = <String, DjiMicImportRecord>{};
    for (final raw in parsed) {
      final record = DjiMicImportRecord.fromJson(raw);
      if (record == null) continue;
      map[djiMicImportKey(record.fileName, record.sizeBytes)] = record;
    }
    return DjiMicImportRegistry._(map);
  }
}
