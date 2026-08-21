/// Pure domain logic for DJI Mic 3 (and the older DJI Mic) recordings —
/// filename parsing and 30-minute auto-split chain detection.
///
/// Ported from `labs/dji-mic-controller/src/model.ts` and
/// `labs/dji-mic-controller/src/organize.ts` (a separate desktop CLI tool in
/// this same monorepo, already validated against real hardware: two
/// transmitters, FAT32, 24-bit/48kHz mono — see that tool's README for the
/// field notes this logic encodes). Deliberately has zero platform/file-IO
/// dependency so it is fully unit-testable without a transmitter or an
/// Android device — see the "cannot verify" note in this feature's plan for
/// why that separation matters here.
///
/// This is groundwork for DJI Mic 3 file import (Phase 2 of that plan): it
/// prepares and labels recordings found in a user-picked folder (an
/// OTG-mounted transmitter, or files already copied off one), but does not
/// itself upload/ingest anything — see import_history_page.dart's
/// `otherDevicesComingSoon` slot, the intended landing spot, and the TODO
/// there for what's still missing on the backend side.
library;

/// 24-bit PCM, 48kHz, mono — DJI Mic 3's default internal-recording format
/// (32-bit float is also selectable in the transmitter's own settings, which
/// changes this; this constant matches only the 24-bit default).
const int bytesPerSec24_48Mono = 48000 * 3;

/// FAT32 cannot hold a file of 4 GiB or more. A WAV header also stores its
/// size in a 32-bit field, so a WAV is capped at the same limit — a merged
/// WAV over this size is silently corrupt (many players still open the first
/// part, which is worse than refusing outright).
const int fat32MaxFileBytes = 4 * 1024 * 1024 * 1024 - 1;
const int wavMaxBytes = fat32MaxFileBytes;

/// Canonical 44-byte PCM WAV header.
const int wavHeaderBytes = 44;

/// DJI cuts a continuous recording every 30 minutes — this is why long takes
/// arrive as multiple files, not the FAT32 ceiling (which at 24-bit/48kHz
/// mono would take ~8.3 hours to reach).
const int splitChunkSec = 30 * 60;

/// Within this fraction of [splitChunkSec] counts as a confident chunk-cut
/// match. Deliberately tight: a 29m36s take is one you stopped, not one the
/// recorder cut, and calling it a chunk would send you hunting for parts
/// that don't exist.
const double confidentRatio = 0.005;

/// Parsed identity from a DJI Mic recording's filename:
/// `TX{unit}_MIC{index}_{yyyyMMdd}_{HHmmss}_{variant}.wav`, e.g.
/// `TX01_MIC002_20250527_202904_orig.wav`. Observed unchanged across DJI Mic,
/// Mic 2, and Mic 3 transmitters.
class DjiMicParsedName {
  final int txUnit;
  final int micIndex;
  final DateTime startedAt;

  /// `'orig'` is the only variant observed so far; DJI names it that way
  /// because other variants (e.g. `.edit.wav`) exist or are planned. Empty
  /// string when the filename has no variant segment.
  final String variant;

  const DjiMicParsedName({
    required this.txUnit,
    required this.micIndex,
    required this.startedAt,
    required this.variant,
  });
}

final RegExp _nameRe = RegExp(
  r'^TX(\d+)_MIC(\d+)_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?:_([^.]+))?\.(wav|WAV)$',
);

/// Parses a DJI Mic recording filename. Returns null for anything that
/// doesn't match — including a filename with an invalid calendar date/time
/// (e.g. month 13), which the regex alone cannot reject.
DjiMicParsedName? parseDjiMicRecordingName(String fileName) {
  final m = _nameRe.firstMatch(fileName);
  if (m == null) return null;

  final year = int.parse(m.group(3)!);
  final month = int.parse(m.group(4)!);
  final day = int.parse(m.group(5)!);
  final hour = int.parse(m.group(6)!);
  final minute = int.parse(m.group(7)!);
  final second = int.parse(m.group(8)!);

  // DateTime normalizes out-of-range components (e.g. month 13 -> next
  // year's January) instead of throwing, so validate explicitly rather than
  // trust the constructed value.
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
    return null;
  }
  final startedAt = DateTime(year, month, day, hour, minute, second);
  if (startedAt.month != month || startedAt.day != day) return null; // e.g. Feb 30

  return DjiMicParsedName(
    txUnit: int.parse(m.group(1)!),
    micIndex: int.parse(m.group(2)!),
    startedAt: startedAt,
    variant: m.group(9) ?? '',
  );
}

/// A DJI Mic recording found on disk: parsed filename identity plus the
/// file-system facts a caller (SAF folder listing, on-device WAV header
/// read) supplies — this class has no file-IO of its own.
class DjiMicRecording {
  final String path;
  final String fileName;
  final int txUnit;
  final int micIndex;
  final DateTime startedAt;
  final String variant;
  final int sizeBytes;
  final double durationSec;

  /// Groups recordings from the same folder — an OTG-mounted transmitter's
  /// take folder, or wherever the caller found the files. Chunk-chain
  /// detection only compares recordings sharing the same [folderKey].
  final String folderKey;

  const DjiMicRecording({
    required this.path,
    required this.fileName,
    required this.txUnit,
    required this.micIndex,
    required this.startedAt,
    required this.variant,
    required this.sizeBytes,
    required this.durationSec,
    required this.folderKey,
  });

  DateTime get endsAt => startedAt.add(Duration(milliseconds: (durationSec * 1000).round()));
}

/// Is this duration close enough to [splitChunkSec] to be a recorder cut?
bool isChunkLength(double sec, {int chunkSec = splitChunkSec}) {
  return (sec - chunkSec).abs() <= chunkSec * confidentRatio;
}

enum DjiMicSplitReason {
  /// Every part but the last runs to almost exactly 30 minutes — the
  /// recorder cut one long take. High confidence.
  chunkCut,

  /// Parts butt up against each other but are shorter than a chunk, so the
  /// recorder didn't cut them — usually a quick manual stop/restart. Worth
  /// merging if it was one session, but this can't know that; surface it
  /// rather than assume.
  contiguous,
}

class DjiMicSplitChain {
  final List<DjiMicRecording> parts;
  final double totalSec;
  final double maxGapSec;
  final DjiMicSplitReason reason;

  const DjiMicSplitChain({
    required this.parts,
    required this.totalSec,
    required this.maxGapSec,
    required this.reason,
  });

  bool get confident => reason == DjiMicSplitReason.chunkCut;
}

/// Finds runs of recordings that are really one take, cut every 30 minutes.
///
/// A part is a continuation when it's on the same [DjiMicRecording.folderKey]
/// and transmitter, its mic index increments by one, and it starts where the
/// previous part ended (within [toleranceSec]) — mirroring the desktop
/// `djimic` tool's `findSplitChains`. `toleranceSec` defaults to 5: filename
/// timestamps have one-second resolution and durations are floats, so a
/// genuine boundary can land a second or two out either way.
List<DjiMicSplitChain> findDjiMicSplitChains(
  List<DjiMicRecording> recordings, {
  int toleranceSec = 5,
  int chunkSec = splitChunkSec,
}) {
  final buckets = <String, List<DjiMicRecording>>{};
  for (final r in recordings) {
    final key = '${r.folderKey}|${r.txUnit}|${r.variant}';
    (buckets[key] ??= []).add(r);
  }

  final chains = <DjiMicSplitChain>[];

  for (final group in buckets.values) {
    final sorted = [...group]..sort((a, b) => a.micIndex.compareTo(b.micIndex));

    List<DjiMicRecording> run = [];
    double maxGap = 0;

    void flush() {
      if (run.length >= 2) {
        final nearLimit = run
            .take(run.length - 1)
            .every((r) => (r.durationSec - chunkSec).abs() <= chunkSec * confidentRatio);
        chains.add(DjiMicSplitChain(
          parts: List.unmodifiable(run),
          totalSec: run.fold(0.0, (s, r) => s + r.durationSec),
          maxGapSec: (maxGap * 10).round() / 10,
          reason: nearLimit ? DjiMicSplitReason.chunkCut : DjiMicSplitReason.contiguous,
        ));
      }
      run = [];
      maxGap = 0;
    }

    for (final r in sorted) {
      if (run.isEmpty) {
        run.add(r);
        continue;
      }
      final prev = run.last;
      final isNextIndex = r.micIndex == prev.micIndex + 1;
      final gapSec = r.startedAt.difference(prev.endsAt).inMilliseconds / 1000.0;
      final startsWherePreviousEnded = gapSec.abs() <= toleranceSec;

      if (isNextIndex && startsWherePreviousEnded) {
        run.add(r);
        if (gapSec.abs() > maxGap) maxGap = gapSec.abs();
      } else {
        flush();
        run.add(r);
      }
    }
    flush();
  }

  return chains;
}

/// Size a merged PCM file would be: all the audio payload, plus ONE header.
/// Slightly conservative (ignores odd-byte padding), which is the right
/// direction to err when the whole point is refusing to exceed [wavMaxBytes].
int predictedMergeBytes(List<DjiMicRecording> parts) {
  final payload = parts.fold<int>(0, (sum, r) => sum + (r.sizeBytes - wavHeaderBytes).clamp(0, 1 << 62));
  return payload + wavHeaderBytes;
}
