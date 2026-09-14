import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'sync_models.dart';

/// Codec exception for encryption/decryption errors.
class SyncCodecException implements Exception {
  const SyncCodecException(this.message);

  final String message;

  @override
  String toString() => message;
}

const String _encName = 'aes-gcm';
const int _pbkdf2Iterations = 120000;
const int _saltLength = 16;

final AesGcm _aesGcm = AesGcm.with256bits();

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

Future<SecretKey> _deriveKey(
  String passphrase,
  List<int> salt,
  int iterations,
) {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  return pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
}

/// Sync codec for encrypting/decrypting event payloads.
class SyncCodec {
  const SyncCodec({required this.passphrase});

  final String passphrase;

  /// Encode a sync event to JSON envelope.
  /// If passphrase is non-empty, encrypts the payload; otherwise returns plaintext envelope.
  Future<Map<String, Object?>> encode(
    SyncEvent event,
    String protocolVersion,
  ) async {
    final payload = event.payload;
    final payloadHash = event.payloadHash;
    final keyFingerprint = passphrase.isEmpty
        ? 'none'
        : _computeKeyFingerprint(passphrase);

    if (passphrase.isEmpty) {
      // Plaintext envelope.
      return <String, Object?>{
        'protocolVersion': protocolVersion,
        'keyFingerprint': keyFingerprint,
        'payload': payload,
        'payloadHash': payloadHash,
      };
    } else {
      // Encrypted envelope.
      final salt = _randomBytes(_saltLength);
      final key = await _deriveKey(passphrase, salt, _pbkdf2Iterations);
      final nonce = _aesGcm.newNonce();
      final plaintext = utf8.encode(jsonEncode(payload));
      final box = await _aesGcm.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
      );

      return <String, Object?>{
        'protocolVersion': protocolVersion,
        'keyFingerprint': keyFingerprint,
        'salt': base64Encode(salt),
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'payloadHash': payloadHash,
      };
    }
  }

  /// Decode a JSON envelope to extract payload.
  /// If encrypted, decrypts with the passphrase; otherwise extracts plaintext payload.
  Future<Object?> decode(Map<String, Object?> envelope) async {
    final keyFingerprint = envelope['keyFingerprint'] as String?;
    if (keyFingerprint == null) {
      throw const SyncCodecException('Missing keyFingerprint in envelope');
    }

    if (keyFingerprint == 'none') {
      // Plaintext envelope.
      return envelope['payload'];
    } else {
      // Encrypted envelope.
      if (passphrase.isEmpty) {
        throw const SyncCodecException(
          'Passphrase required to decrypt envelope',
        );
      }

      final expectedFingerprint = _computeKeyFingerprint(passphrase);
      if (keyFingerprint != expectedFingerprint) {
        throw const SyncCodecException('Key fingerprint mismatch');
      }

      try {
        final salt = base64Decode(envelope['salt'] as String);
        final nonce = base64Decode(envelope['nonce'] as String);
        final ciphertext = base64Decode(envelope['ciphertext'] as String);

        final key = await _deriveKey(passphrase, salt, _pbkdf2Iterations);
        final box = SecretBox(ciphertext, nonce: nonce, mac: Mac.empty);
        final decrypted = await _aesGcm.decrypt(box, secretKey: key);
        final payloadJson = utf8.decode(decrypted);
        return jsonDecode(payloadJson);
      } on SecretBoxAuthenticationError {
        throw const SyncCodecException(
          'Decryption failed: wrong passphrase or corrupted data',
        );
      } catch (e) {
        throw SyncCodecException('Decryption error: $e');
      }
    }
  }

  /// Compute a fingerprint of the passphrase for key identification.
  String _computeKeyFingerprint(String passphrase) {
    final bytes = utf8.encode(passphrase);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }
}
