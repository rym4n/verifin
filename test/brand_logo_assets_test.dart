import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _masterLogoPath = 'assets/brand/bubaiji_logo_1024.png';
const _sourceLogoPath = 'bubaiji_logo.png';

void main() {
  test('brand master keeps the supplied teal medallion artwork', () {
    final source = _decodePng(_sourceLogoPath);
    final logo = _decodePng(_masterLogoPath);

    expect((logo.width, logo.height), (1024, 1024));
    expect(logo.getPixel(0, 0).a, 255);
    _expectPixelsEqual(
      source,
      logo,
      'master must preserve the supplied source',
    );
    expect(_tealCoverage(logo), greaterThan(0.15));
  });

  test(
    'Android launcher icons use the supplied medallion at every density',
    () {
      const launcherSizes = <String, int>{
        'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
        'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
        'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
        'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
      };

      for (final entry in launcherSizes.entries) {
        final logo = _decodePng(entry.key);
        expect(
          (logo.width, logo.height),
          (entry.value, entry.value),
          reason: entry.key,
        );
        final expected = img.copyResize(
          _decodePng(_sourceLogoPath),
          width: entry.value,
          height: entry.value,
          interpolation: img.Interpolation.cubic,
        );
        _expectPixelsEqual(expected, logo, entry.key);
        expect(_tealCoverage(logo), greaterThan(0.15), reason: entry.key);
      }
    },
  );

  test('SVG logo is a self-contained wrapper around the PNG master', () {
    final masterBytes = File(_masterLogoPath).readAsBytesSync();
    final svg = File('assets/brand/bubaiji_logo.svg').readAsStringSync();
    final match = RegExp(
      r'href="data:image/png;base64,([A-Za-z0-9+/=\r\n]+)"',
    ).firstMatch(svg);

    expect(match, isNotNull);
    final embeddedBytes = base64Decode(match!.group(1)!.replaceAll('\n', ''));
    expect(sha256.convert(embeddedBytes), sha256.convert(masterBytes));
  });
}

img.Image _decodePng(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = img.decodePng(bytes);
  expect(decoded, isNotNull, reason: '$path must be a valid PNG');
  return decoded!;
}

void _expectPixelsEqual(img.Image expected, img.Image actual, String reason) {
  expect((actual.width, actual.height), (expected.width, expected.height));
  for (var y = 0; y < expected.height; y++) {
    for (var x = 0; x < expected.width; x++) {
      final expectedPixel = expected.getPixel(x, y);
      final actualPixel = actual.getPixel(x, y);
      if (expectedPixel.r != actualPixel.r ||
          expectedPixel.g != actualPixel.g ||
          expectedPixel.b != actualPixel.b ||
          expectedPixel.a != actualPixel.a) {
        fail('$reason differs at ($x, $y)');
      }
    }
  }
}

double _tealCoverage(img.Image image) {
  var tealPixels = 0;
  for (final pixel in image) {
    if (pixel.a > 200 &&
        pixel.r < 140 &&
        pixel.g > 105 &&
        pixel.g < 205 &&
        pixel.b > 120 &&
        pixel.b < 220 &&
        pixel.g > pixel.r + 20 &&
        pixel.b > pixel.r + 20) {
      tealPixels++;
    }
  }
  return tealPixels / (image.width * image.height);
}
