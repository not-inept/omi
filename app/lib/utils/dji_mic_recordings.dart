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
/// This labels recordings found among files the user picked off a transmitter
/// (over USB-C, or already copied onto the phone). Turning them into
/// conversations is `lib/services/dji_mic_import_service.dart`; reading their
/// audio is `lib/utils/dji_mic_wav.dart`.
library;

import 'dart:math' as math;

import 'package:omi/utils/dji_mic_wav.dart';

/// 24-bit PCM, 48kHz, mono — DJI Mic 3's default internal-recording format
/// (32-bit float is also selectable in the transmitter's own settings, which
/// changes this; this constant matches only the 24-bit default).
///
/// **A last resort for estimating duration, not a measurement.** A 32-bit
/// float take is 4 bytes per sample, so dividing its size by this overstates
/// its length by a third — and a wrong end time is exactly what breaks
/// [findDjiMicSplitChains], which decides whether two files are one take by
/// asking whether the second starts where the first ended. Use
/// [djiMicRecordingFromHeader], which reads the rate the file declares.
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

  /// True when [durationSec] came from the 24-bit byte-rate assumption
  /// because the file's own header could not be read. Chain detection is only
  /// as good as the end times it is given, so an estimate has to be visible
  /// rather than silently equal to a measurement.
  final bool durationEstimated;

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
    this.durationEstimated = false,
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

/// Builds a [DjiMicRecording] from a picked file, measuring its duration from
/// its own header rather than guessing at its format.
///
/// [header] is what [parseDjiMicWavHeader] returned for this file. Pass null
/// only when the header could not be read at all — the duration then falls
/// back to the 24-bit assumption, and [DjiMicRecording.durationEstimated] says
/// so, so the UI can mark it rather than present a guess as a measurement.
///
/// [sizeBytes] is the real file length. A recording cut short by a flat
/// battery declares more audio in its header than it holds, so the smaller of
/// the two is what gets measured.
///
/// Returns null when [fileName] is not a DJI recording name — that is the
/// filter that keeps everything else in a picked folder out of the list.
DjiMicRecording? djiMicRecordingFromHeader({
  required String path,
  required String fileName,
  required int sizeBytes,
  required String folderKey,
  DjiMicWavInfo? header,
}) {
  final parsed = parseDjiMicRecordingName(fileName);
  if (parsed == null) return null;

  final double durationSec;
  if (header != null && header.byteRate > 0) {
    final available = math.max(0, sizeBytes - header.dataOffset);
    durationSec = header.durationSecForDataBytes(math.min(header.dataLength, available));
  } else {
    durationSec = math.max(0, sizeBytes - wavHeaderBytes) / bytesPerSec24_48Mono;
  }

  return DjiMicRecording(
    path: path,
    fileName: fileName,
    txUnit: parsed.txUnit,
    micIndex: parsed.micIndex,
    startedAt: parsed.startedAt,
    variant: parsed.variant,
    sizeBytes: sizeBytes,
    durationSec: durationSec,
    folderKey: folderKey,
    durationEstimated: header == null || header.byteRate <= 0,
  );
}

/// The `_orig` variant is the raw recording; `_edit` is the same take with the
/// transmitter's voice preset, low cut, noise cancellation and adaptive gain
/// applied (DJI writes both at once in dual-file mode). Importing both would
/// hand Omi the same conversation twice, so an import offers one by default.
///
/// The processed one is the default: DJI's own processing is tuned for this
/// microphone, and a transcript benefits from noise cancellation more than it
/// benefits from an untouched original.
const String djiMicPreferredVariant = 'edit';

/// Given every recording found, the ones to offer by default — the preferred
/// variant of each take, and any take that only exists in one variant.
///
/// Never drops a recording that has no sibling: a transmitter set to record a
/// single file writes only `_orig`, and a user who set it that way must still
/// see their takes.
List<DjiMicRecording> preferredDjiMicVariants(
  List<DjiMicRecording> recordings, {
  String preferred = djiMicPreferredVariant,
}) {
  final byTake = <String, List<DjiMicRecording>>{};
  for (final r in recordings) {
    final key = '${r.folderKey}|${r.txUnit}|${r.micIndex}|${r.startedAt.millisecondsSinceEpoch}';
    (byTake[key] ??= []).add(r);
  }
  final out = <DjiMicRecording>[];
  for (final group in byTake.values) {
    if (group.length == 1) {
      out.add(group.first);
      continue;
    }
    out.add(group.firstWhere((r) => r.variant == preferred, orElse: () => group.first));
  }
  out.sort((a, b) {
    final byTime = a.startedAt.compareTo(b.startedAt);
    return byTime != 0 ? byTime : a.fileName.compareTo(b.fileName);
  });
  return out;
}

/// One picked recording's default state on the import screen.
class DjiMicOffer {
  final DjiMicRecording recording;

  /// Ticked when the screen opens.
  final bool selected;

  /// True when this is the copy of a take that is not offered by default — the
  /// raw `_orig` beside a processed `_edit`.
  final bool hasSiblingVariant;

  const DjiMicOffer({
    required this.recording,
    required this.selected,
    required this.hasSiblingVariant,
  });
}

/// Decides what an import screen ticks when a folder has just been picked.
///
/// Two rules, and they are the difference between a clean import and a
/// duplicated day:
///
///  * a take already imported is shown but not ticked — a transmitter holds
///    every recording since it was last formatted, so the same forty takes
///    come back every time the picker is opened;
///  * of the two copies DJI's dual-file mode writes for every take, only the
///    processed one is ticked. Importing both makes two conversations out of
///    one moment.
///
/// Nothing is ever dropped from the list. The user picked these files.
List<DjiMicOffer> djiMicImportOffers(
  List<DjiMicRecording> recordings, {
  required bool Function(DjiMicRecording) isAlreadyImported,
  String preferredVariant = djiMicPreferredVariant,
}) {
  final preferred = preferredDjiMicVariants(recordings, preferred: preferredVariant)
      .map((r) => r.fileName)
      .toSet();
  return recordings.map((r) {
    final isPreferred = preferred.contains(r.fileName);
    return DjiMicOffer(
      recording: r,
      hasSiblingVariant: !isPreferred,
      selected: isPreferred && !isAlreadyImported(r),
    );
  }).toList();
}
