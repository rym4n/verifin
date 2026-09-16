import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

const _sourcePath = 'bubaiji_logo.png';
const _masterPath = 'assets/brand/bubaiji_logo_1024.png';
const _svgPath = 'assets/brand/bubaiji_logo.svg';

const _launcherSizes = <String, int>{
  'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
  'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
  'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
  'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
  'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
};

void main() {
  final sourceFile = File(_sourcePath);
  if (!sourceFile.existsSync()) {
    stderr.writeln('Missing source logo: $_sourcePath');
    exitCode = 1;
    return;
  }

  final decoded = img.decodePng(sourceFile.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('Source logo is not a valid PNG: $_sourcePath');
    exitCode = 1;
    return;
  }
  if (decoded.width != 1024 || decoded.height != 1024) {
    stderr.writeln(
      'Source logo must be 1024x1024, got ${decoded.width}x${decoded.height}',
    );
    exitCode = 1;
    return;
  }

  // Keep the user-supplied white canvas and pixel colors intact.
  final logo = decoded.convert(numChannels: 4);

  Directory('assets/brand').createSync(recursive: true);
  final masterBytes = img.encodePng(logo, level: 9);
  File(_masterPath).writeAsBytesSync(masterBytes);
  File(_svgPath).writeAsStringSync(_svgFor(masterBytes));

  for (final entry in _launcherSizes.entries) {
    final launcher = img.copyResize(
      logo,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.cubic,
    );
    File(entry.key).writeAsBytesSync(img.encodePng(launcher, level: 9));
  }

  stdout.writeln('Generated $_masterPath, $_svgPath, and launcher icons.');
}

String _svgFor(List<int> pngBytes) {
  final encoded = base64Encode(pngBytes);
  return '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>不白记</title>
  <image width="1024" height="1024" href="data:image/png;base64,$encoded"/>
</svg>
''';
}
