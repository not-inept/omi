/// Reading DJI Mic internal recordings: the WAV header, and turning the audio
/// inside into the one format the rest of Omi's pipeline already speaks.
///
/// A transmitter records to its own storage in a format the app never sees
/// live. DJI's Mic 3 page and manual describe 24-bit and 32-bit float internal
/// recording (dual-file, both written at once — the `_orig` and `_edit`
/// variants), at 48 kHz mono; the older Mic/Mic 2 units were verified as
/// 24-bit/48 kHz mono against real hardware by the sibling desktop tool
/// `labs/dji-mic-controller`. Omi's own capture path, by contrast, is 16 kHz
/// mono PCM16 everywhere: that is what the live DJI Bluetooth route emits
/// (see android/.../djimic/DjiMicCaptureEngine.kt), what
/// `DjiMicSource`/`PhoneMicSource` frame, and what the backend decodes from a
/// `_pcm16_16000_` WAL upload.
///
/// So an import has exactly one job beyond bookkeeping: read whatever the
/// transmitter wrote, and hand back 16 kHz mono PCM16. Everything here is
/// pure — bytes in, bytes out, no file IO, no platform channels — so it is
/// tested against synthetic recordings on a laptop rather than needing a
/// transmitter and a phone.
///
/// **Do not derive duration from a hardcoded byte rate.** A 32-bit float take
/// is 4 bytes per sample where a 24-bit take is 3, so assuming the 24-bit rate
/// overstates a float file's length by a third — which would then feed
/// `findDjiMicSplitChains` a wrong end time and silently break the 30-minute
/// chunk detection. [DjiMicWavInfo.durationSec] uses the rate the file itself
/// declares.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// `fmt ` audio format codes this can read.
const int wavFormatPcm = 1;
const int wavFormatIeeeFloat = 3;

/// `WAVE_FORMAT_EXTENSIBLE`. Its real format code lives in the first two bytes
/// of the SubFormat GUID in the `fmt ` chunk's extension, which is where DJI's
/// 32-bit float files have been reported to declare themselves.
const int wavFormatExtensible = 0xFFFE;

/// The rate every downstream stage in Omi assumes.
const int omiPcmSampleRate = 16000;

/// What a DJI recording's own header says about it.
class DjiMicWavInfo {
  /// Resolved format code: [wavFormatPcm] or [wavFormatIeeeFloat], with
  /// `WAVE_FORMAT_EXTENSIBLE` already unwrapped to whichever of those it names.
  final int audioFormat;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;

  /// Bytes per second as the file declares it. Authoritative for duration.
  final int byteRate;

  /// Bytes per sample frame (all channels).
  final int blockAlign;

  /// Byte offset of the first audio byte.
  final int dataOffset;

  /// Length of the audio in bytes as the `data` chunk header declares it. A
  /// recording interrupted by a flat battery can declare more than the file
  /// actually holds, so a caller with the real file length should take the
  /// smaller of the two — see [durationSecForDataBytes].
  final int dataLength;

  const DjiMicWavInfo({
    required this.audioFormat,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.byteRate,
    required this.blockAlign,
    required this.dataOffset,
    required this.dataLength,
  });

  bool get isFloat => audioFormat == wavFormatIeeeFloat;

  /// Duration implied by the declared data length.
  double get durationSec => durationSecForDataBytes(dataLength);

  /// Duration of [dataBytes] of this file's audio. Pass the truncated length
  /// when the file on disk is shorter than its header claims.
  double durationSecForDataBytes(int dataBytes) {
    if (byteRate <= 0) return 0;
    return dataBytes / byteRate;
  }

  /// Whether [decodeWavSamples] can read this file's audio.
  bool get isSupported {
    if (channels < 1) return false;
    if (audioFormat == wavFormatIeeeFloat) return bitsPerSample == 32 || bitsPerSample == 64;
    if (audioFormat == wavFormatPcm) {
      return bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32;
    }
    return false;
  }

  @override
  String toString() =>
      'DjiMicWavInfo(format: $audioFormat, ${sampleRate}Hz, ${bitsPerSample}bit, ${channels}ch, '
      'data: $dataLength bytes @ $dataOffset)';
}

/// Thrown when a file that was expected to be a DJI recording is not readable
/// as one. Carries a reason the UI can show verbatim — an import that skips a
/// file has to be able to say why it skipped it.
class DjiMicWavException implements Exception {
  final String message;
  const DjiMicWavException(this.message);
  @override
  String toString() => message;
}

/// Largest header this will walk before giving up. A DJI header is a few
/// hundred bytes; anything past this is not a header, and refusing to keep
/// scanning stops a corrupt file turning into an unbounded read.
const int djiMicMaxHeaderBytes = 1 << 16;

/// Reads the RIFF header out of [bytes], which must be the beginning of the
/// file (the first [djiMicMaxHeaderBytes] are enough for any real recording).
///
/// Walks the chunk list rather than assuming the canonical 44-byte layout:
/// recorders routinely write `LIST`/`JUNK`/`bext` chunks before `data`, and a
/// fixed offset would read metadata as audio.
DjiMicWavInfo parseDjiMicWavHeader(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const DjiMicWavException('Not a WAV file: too short to hold a RIFF header.');
  }
  final view = ByteData.sublistView(bytes);
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  // RF64 is the >4 GiB variant of the same container. DJI's own 30-minute cut
  // means a file never gets near 4 GiB, so RF64 is not expected here and its
  // 64-bit sizes live in a separate `ds64` chunk this does not read — say so
  // rather than misreport its sizes as zero.
  if (riff == 'RF64') {
    throw const DjiMicWavException('RF64 files are not supported; this importer reads standard RIFF/WAVE.');
  }
  if (riff != 'RIFF' || wave != 'WAVE') {
    throw const DjiMicWavException('Not a WAV file: missing the RIFF/WAVE signature.');
  }

  int? audioFormat;
  int channels = 0;
  int sampleRate = 0;
  int byteRate = 0;
  int blockAlign = 0;
  int bitsPerSample = 0;

  int offset = 12;
  final limit = math.min(bytes.length, djiMicMaxHeaderBytes);
  while (offset + 8 <= limit) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 'fmt ') {
      if (body + 16 > bytes.length) {
        throw const DjiMicWavException('Truncated WAV: the fmt chunk runs past the end of the header.');
      }
      audioFormat = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      byteRate = view.getUint32(body + 8, Endian.little);
      blockAlign = view.getUint16(body + 12, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
      if (audioFormat == wavFormatExtensible && size >= 40 && body + 26 <= bytes.length) {
        // cbSize(2) + validBits(2) + channelMask(4) then the SubFormat GUID,
        // whose leading 16-bit word is the real format code.
        audioFormat = view.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      if (audioFormat == null) {
        throw const DjiMicWavException('Malformed WAV: the data chunk arrives before fmt.');
      }
      // Derive what the fmt chunk left at zero rather than dividing by it later.
      final resolvedBlockAlign = blockAlign > 0 ? blockAlign : (channels * (bitsPerSample ~/ 8));
      final resolvedByteRate = byteRate > 0 ? byteRate : (sampleRate * resolvedBlockAlign);
      return DjiMicWavInfo(
        audioFormat: audioFormat,
        channels: channels,
        sampleRate: sampleRate,
        bitsPerSample: bitsPerSample,
        byteRate: resolvedByteRate,
        blockAlign: resolvedBlockAlign,
        dataOffset: body,
        dataLength: size,
      );
    }

    // Chunks are word-aligned: an odd size is followed by one pad byte.
    final advance = size + (size.isOdd ? 1 : 0);
    if (advance <= 0) {
      throw const DjiMicWavException('Malformed WAV: a chunk declares a zero length.');
    }
    offset = body + advance;
  }

  throw const DjiMicWavException('Malformed WAV: no data chunk found in the header.');
}

/// Decodes [bytes] of audio in the format [info] describes into mono samples
/// scaled to signed 16-bit range, as doubles so a resampler can filter them
/// without rounding twice.
///
/// [bytes] must start on a sample-frame boundary and hold a whole number of
/// frames; [DjiMicPcm16Converter] is what guarantees that across chunk
/// boundaries.
List<double> decodeWavSamples(Uint8List bytes, DjiMicWavInfo info) {
  final channels = info.channels;
  final bits = info.bitsPerSample;
  final bytesPerSample = bits ~/ 8;
  final frames = bytes.length ~/ info.blockAlign;
  final out = List<double>.filled(frames, 0);
  final view = ByteData.sublistView(bytes);

  for (int f = 0; f < frames; f++) {
    double sum = 0;
    for (int c = 0; c < channels; c++) {
      final at = f * info.blockAlign + c * bytesPerSample;
      double v;
      if (info.isFloat) {
        // A float take is normalized to ±1.0 but, being float, is not clamped
        // there — that is the entire point of 32-bit float recording. Scaling
        // then clamping is what a fixed-point export has to do; a take that
        // actually went above 0 dBFS will clip here, and the unclipped
        // original stays on the transmitter.
        final raw = bits == 64 ? view.getFloat64(at, Endian.little) : view.getFloat32(at, Endian.little);
        v = raw * 32767.0;
      } else if (bits == 8) {
        // 8-bit PCM is unsigned by the WAV spec; every wider depth is signed.
        v = (bytes[at] - 128) * 256.0;
      } else if (bits == 16) {
        v = view.getInt16(at, Endian.little).toDouble();
      } else if (bits == 24) {
        final lo = bytes[at];
        final mid = bytes[at + 1];
        final hi = bytes[at + 2];
        int value = (hi << 16) | (mid << 8) | lo;
        if ((value & 0x800000) != 0) value -= 0x1000000;
        v = value / 256.0;
      } else {
        v = view.getInt32(at, Endian.little) / 65536.0;
      }
      sum += v;
    }
    // Downmix by averaging. DJI's internal recordings are mono, so this is a
    // safety net for a file that isn't rather than a mixing decision.
    out[f] = sum / channels;
  }
  return out;
}

int _clampToInt16(double v) {
  if (v.isNaN) return 0;
  final r = v.round();
  if (r > 32767) return 32767;
  if (r < -32768) return -32768;
  return r;
}

/// Streaming rate conversion to [omiPcmSampleRate] with a real low-pass.
///
/// Naive decimation is the tempting shortcut and the wrong one: dropping two
/// of every three samples of a 48 kHz recording folds everything above 8 kHz
/// back down into speech range as aliasing, and sibilants are exactly what
/// lands up there. So the input is filtered with a Hamming-windowed sinc
/// before it is sampled down.
///
/// Stateful across calls: the filter's history and the fractional read
/// position carry over, so a file converted in chunks is bit-identical to the
/// same file converted in one go. Call [process] with chunks in order and
/// [flush] once at the end.
class DjiMicPcm16Downsampler {
  final int inputRate;
  final int outputRate;

  late final List<double> _taps;
  late final int _halfTaps;
  late final double _ratio;

  /// Input samples still needed as filter history, plus anything not yet
  /// consumed. Starts as zero padding so the first output sample is centred on
  /// the first input sample rather than [_halfTaps] samples into the file.
  List<double> _tail = const [];

  /// Next output sample's centre, as a fractional index into [_tail].
  double _pos = 0;

  bool _flushed = false;

  DjiMicPcm16Downsampler({required this.inputRate, this.outputRate = omiPcmSampleRate}) {
    if (inputRate <= 0) throw ArgumentError.value(inputRate, 'inputRate', 'must be positive');
    if (outputRate <= 0) throw ArgumentError.value(outputRate, 'outputRate', 'must be positive');
    _ratio = inputRate / outputRate;

    if (inputRate <= outputRate) {
      // Upsampling, or nothing to do. No anti-alias filter is needed going up,
      // and a one-tap kernel makes the same code path a plain (interpolating)
      // resampler.
      _taps = const [1.0];
      _halfTaps = 0;
    } else {
      // Six taps per output sample is a modest, cheap kernel: enough stopband
      // rejection that decimation artefacts sit well below speech, without the
      // cost of a broadcast-grade filter on a phone processing hours of audio.
      final decim = _ratio;
      final half = math.max(4, (3 * decim).round());
      final n = 2 * half + 1;
      // Cut just under the output Nyquist, expressed as a fraction of the
      // input rate.
      final cutoff = 0.45 * outputRate / inputRate;
      final taps = List<double>.filled(n, 0);
      double sum = 0;
      for (int i = 0; i < n; i++) {
        final x = i - half;
        final sinc = x == 0 ? 2 * cutoff : math.sin(2 * math.pi * cutoff * x) / (math.pi * x);
        final window = 0.54 - 0.46 * math.cos(2 * math.pi * i / (n - 1));
        taps[i] = sinc * window;
        sum += taps[i];
      }
      for (int i = 0; i < n; i++) {
        taps[i] /= sum; // unity gain at DC
      }
      _taps = taps;
      _halfTaps = half;
    }
    _tail = List<double>.filled(_halfTaps, 0);
    _pos = _halfTaps.toDouble();
  }

  /// True when input and output rates match and the filter is a pass-through.
  bool get isPassthrough => inputRate == outputRate;

  /// Filters and resamples [samples] (mono, 16-bit-scaled doubles), returning
  /// whatever whole output samples are now available.
  List<int> process(List<double> samples) {
    if (_flushed) throw StateError('DjiMicPcm16Downsampler.process called after flush');
    if (samples.isEmpty) return const [];
    if (isPassthrough) return samples.map(_clampToInt16).toList();

    final combined = <double>[..._tail, ...samples];
    final out = <int>[];
    final n = combined.length;

    while (true) {
      final centre = _pos.round();
      if (centre + _halfTaps > n - 1) break;
      double acc = 0;
      for (int k = 0; k < _taps.length; k++) {
        acc += _taps[k] * combined[centre - _halfTaps + k];
      }
      out.add(_clampToInt16(acc));
      _pos += _ratio;
    }

    // Keep only what the next output sample still needs to see.
    final keepFrom = math.max(0, _pos.floor() - _halfTaps);
    _tail = combined.sublist(math.min(keepFrom, n));
    _pos -= keepFrom;
    return out;
  }

  /// Drains the filter's tail. Pads with silence so the final samples of the
  /// recording are emitted instead of being swallowed by the kernel's width.
  List<int> flush() {
    if (_flushed) return const [];
    if (isPassthrough) {
      _flushed = true;
      return const [];
    }
    final out = process(List<double>.filled(_halfTaps, 0));
    _flushed = true;
    return out;
  }
}

/// Converts a DJI recording's audio, arriving in arbitrary byte chunks, into
/// 16 kHz mono PCM16 bytes ready to be written as a WAL `.bin`.
///
/// Holds back any bytes that do not complete a sample frame and prepends them
/// to the next chunk, so the caller can stream a 250 MB file through in
/// whatever pieces the platform hands it without ever aligning anything
/// itself.
class DjiMicPcm16Converter {
  final DjiMicWavInfo info;
  final DjiMicPcm16Downsampler _downsampler;
  final BytesBuilder _partial = BytesBuilder(copy: true);
  bool _finished = false;

  DjiMicPcm16Converter(this.info, {int outputRate = omiPcmSampleRate})
      : _downsampler = DjiMicPcm16Downsampler(inputRate: info.sampleRate, outputRate: outputRate) {
    if (!info.isSupported) {
      throw DjiMicWavException(
        'Unsupported audio: ${info.bitsPerSample}-bit '
        '${info.isFloat ? 'float' : 'PCM'}, ${info.channels} channel(s).',
      );
    }
    if (info.blockAlign <= 0) {
      throw const DjiMicWavException('Malformed WAV: the header declares a zero-length sample frame.');
    }
  }

  int get outputRate => _downsampler.outputRate;

  /// Feeds the next slice of the file's audio bytes and returns whatever
  /// PCM16 has become available, little-endian.
  Uint8List addBytes(List<int> chunk) {
    if (_finished) throw StateError('DjiMicPcm16Converter.addBytes called after finish');
    _partial.add(chunk);
    final buffered = _partial.takeBytes();
    final usable = buffered.length - (buffered.length % info.blockAlign);
    if (usable < buffered.length) {
      _partial.add(Uint8List.sublistView(buffered, usable));
    }
    if (usable == 0) return Uint8List(0);
    final samples = decodeWavSamples(Uint8List.sublistView(buffered, 0, usable), info);
    return _toBytes(_downsampler.process(samples));
  }

  /// Drains the resampler. Any trailing bytes that never completed a sample
  /// frame — a recording cut off mid-sample by a flat battery — are dropped
  /// rather than decoded as a garbage sample.
  Uint8List finish() {
    if (_finished) return Uint8List(0);
    final out = _toBytes(_downsampler.flush());
    _finished = true;
    return out;
  }

  Uint8List _toBytes(List<int> samples) {
    final out = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(out);
    for (int i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return out;
  }
}

/// Builds a canonical 44-byte PCM WAV header. Used by tests to make synthetic
/// recordings, and available to any caller that needs to write one.
Uint8List buildPcmWavHeader({
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
  required int dataLength,
  int audioFormat = wavFormatPcm,
}) {
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final byteRate = sampleRate * blockAlign;
  final header = Uint8List(44);
  final view = ByteData.sublistView(header);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      header[at + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, audioFormat, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataLength, Endian.little);
  return header;
}
