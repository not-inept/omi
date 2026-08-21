import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/dji_mic_recordings.dart';

/// Ports the key fixtures from the desktop `djimic` tool's
/// `organize.test.ts`/`model.test.ts` (labs/dji-mic-controller), which are
/// themselves grounded in real hardware behavior (see that tool's README) —
/// this is the same domain logic, just consumed from the mobile app instead
/// of the desktop CLI. Values below (30-minute chunks, the FIZZBO 2-second
/// gap, the 12-hour MAGGY gap) are carried over verbatim from that suite.

DjiMicRecording rec({
  int txUnit = 1,
  int micIndex = 1,
  String variant = 'orig',
  required DateTime startedAt,
  required double durationSec,
  String folderKey = 'FIZZBO|TX_MIC001',
  String fileName = 'f.wav',
}) {
  return DjiMicRecording(
    path: '/tree/$folderKey/$fileName',
    fileName: fileName,
    txUnit: txUnit,
    micIndex: micIndex,
    startedAt: startedAt,
    variant: variant,
    sizeBytes: (durationSec * bytesPerSec24_48Mono).round(),
    durationSec: durationSec,
    folderKey: folderKey,
  );
}

void main() {
  group('parseDjiMicRecordingName', () {
    test('parses a real DJI filename', () {
      final p = parseDjiMicRecordingName('TX02_MIC001_20260817_134834_orig.wav');
      expect(p, isNotNull);
      expect(p!.txUnit, 2);
      expect(p.micIndex, 1);
      expect(p.variant, 'orig');
      expect(p.startedAt, DateTime(2026, 8, 17, 13, 48, 34));
    });

    test('accepts a variant other than _orig, and no variant at all', () {
      expect(parseDjiMicRecordingName('TX01_MIC007_20260101_000000_denoised.wav')?.variant, 'denoised');
      expect(parseDjiMicRecordingName('TX01_MIC007_20260101_000000.wav')?.variant, '');
    });

    test('rejects names that are not DJI recordings', () {
      for (final n in ['notes.txt', 'TX_MIC001_20260817_134834', 'random.wav', 'TX01_MIC1_2026_1348_orig.wav']) {
        expect(parseDjiMicRecordingName(n), isNull, reason: n);
      }
    });

    test('rejects an invalid calendar date the regex alone cannot catch', () {
      expect(parseDjiMicRecordingName('TX01_MIC001_20260230_000000_orig.wav'), isNull); // Feb 30
      expect(parseDjiMicRecordingName('TX01_MIC001_20261301_000000_orig.wav'), isNull); // month 13
    });
  });

  group('findDjiMicSplitChains', () {
    test('detects a real 30-minute split: two full chunks plus a remainder', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1800);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 30, 0), durationSec: 1800);
      final c = rec(micIndex: 3, startedAt: DateTime(2026, 8, 17, 11, 0, 0), durationSec: 600);

      final chains = findDjiMicSplitChains([a, b, c]);
      expect(chains.length, 1);
      expect(chains[0].parts.length, 3);
      expect(chains[0].totalSec, 4200);
      expect(chains[0].confident, isTrue, reason: 'full chunks should read as confident');
      expect(chains[0].reason, DjiMicSplitReason.chunkCut);
    });

    test('a second of clock slop at the boundary still chains', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1799.4);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 30, 1), durationSec: 900);
      expect(findDjiMicSplitChains([a, b]).length, 1);
    });

    test('back-to-back short takes chain as contiguous, not as a chunk cut', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 300);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 5, 2), durationSec: 300);
      final chains = findDjiMicSplitChains([a, b]);
      expect(chains.length, 1);
      expect(chains[0].reason, DjiMicSplitReason.contiguous);
      expect(chains[0].confident, isFalse, reason: 'must not claim the recorder cut this');
    });

    test('the real FIZZBO case: 21m33s ending 2s before the next take', () {
      final a = rec(micIndex: 4, startedAt: DateTime(2026, 8, 19, 15, 0, 4), durationSec: 1293);
      final b = rec(micIndex: 5, startedAt: DateTime(2026, 8, 19, 15, 21, 39), durationSec: 46);
      final chains = findDjiMicSplitChains([a, b]);
      expect(chains.length, 1, reason: 'a 2-second gap is a continuation');
      expect(chains[0].reason, DjiMicSplitReason.contiguous);
      expect(chains[0].maxGapSec, 2);
    });

    test('a distant next take is never chained, however long the previous', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1800);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 14, 0, 0), durationSec: 600);
      expect(findDjiMicSplitChains([a, b]), isEmpty);
    });

    test('chunkSec controls how a chain is CLASSIFIED, not whether it chains', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 900);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 15, 0), durationSec: 400);

      final atDefault = findDjiMicSplitChains([a, b]);
      expect(atDefault[0].reason, DjiMicSplitReason.contiguous, reason: '15 minutes is not a 30-minute cut');
      expect(atDefault[0].confident, isFalse);

      final at15 = findDjiMicSplitChains([a, b], chunkSec: 900);
      expect(at15[0].reason, DjiMicSplitReason.chunkCut, reason: 'but it is a clean cut if the chunk is 15 minutes');
      expect(at15[0].confident, isTrue);
    });

    test('a 12-hour gap is two takes, not a split — the real MAGGY case', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 18, 22, 45, 51), durationSec: 683.98);
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 19, 10, 37, 52), durationSec: 1394.25);
      expect(findDjiMicSplitChains([a, b]), isEmpty);
    });

    test('non-consecutive indices are never chained', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1800);
      final c = rec(micIndex: 3, startedAt: DateTime(2026, 8, 17, 10, 30, 0), durationSec: 600);
      expect(findDjiMicSplitChains([a, c]), isEmpty);
    });

    test('different transmitters are never chained together', () {
      final a = rec(txUnit: 1, micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1800);
      final b = rec(txUnit: 2, micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 30, 0), durationSec: 600);
      expect(findDjiMicSplitChains([a, b]), isEmpty);
    });

    test('different folders (e.g. different transmitters\' take folders) are never chained', () {
      final a = rec(
          micIndex: 1, folderKey: 'FIZZBO|TX_MIC001', startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1800);
      final b = rec(
          micIndex: 2, folderKey: 'FIZZBO|TX_MIC002', startedAt: DateTime(2026, 8, 17, 10, 30, 0), durationSec: 600);
      expect(findDjiMicSplitChains([a, b]), isEmpty);
    });

    test('a 29m36s take is NOT flagged as a clean 30-minute cut', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 1776); // 29m36s
      final b = rec(micIndex: 2, startedAt: DateTime(2026, 8, 17, 10, 29, 36), durationSec: 60);
      final chains = findDjiMicSplitChains([a, b]);
      expect(chains[0].reason, DjiMicSplitReason.contiguous);
      expect(chains[0].confident, isFalse);
    });

    test('a single unmatched recording produces no chain', () {
      final a = rec(micIndex: 1, startedAt: DateTime(2026, 8, 17, 10, 0, 0), durationSec: 100);
      expect(findDjiMicSplitChains([a]), isEmpty);
    });
  });

  group('isChunkLength', () {
    test('is strict: 29m36s is a stopped take, not a cut', () {
      expect(isChunkLength(1776), isFalse); // 29m36s
      expect(isChunkLength(1800), isTrue); // exactly 30m
      expect(isChunkLength(1791), isTrue); // within 0.5% tolerance
    });
  });

  group('predictedMergeBytes', () {
    test('counts one header, not one per part', () {
      final a = rec(startedAt: DateTime(2026), durationSec: 100);
      final b = rec(startedAt: DateTime(2026), durationSec: 200);
      final predicted = predictedMergeBytes([a, b]);
      final expected = (a.sizeBytes - wavHeaderBytes) + (b.sizeBytes - wavHeaderBytes) + wavHeaderBytes;
      expect(predicted, expected);
    });

    test('a 30-minute chunk is about 259 MB — splits are ordinary, not exotic', () {
      const bytes = 1800 * bytesPerSec24_48Mono;
      expect(bytes, 259200000);
      expect(bytes, lessThan(4 * 1024 * 1024 * 1024), reason: 'nowhere near the FAT32 ceiling');
    });

    test('THE BIG ONE: a merge at 24-bit/48kHz mono would exceed 4 GiB well under 9 hours', () {
      // wavMaxBytes / bytesPerSec24_48Mono ~= 8.3 hours — the guard this
      // constant exists to support (enforced by the actual merge tool, not
      // by this pure-logic module, which only predicts the size).
      const hoursToLimit = wavMaxBytes / bytesPerSec24_48Mono / 3600;
      expect(hoursToLimit, closeTo(8.28, 0.05));
    });
  });
}
