import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'sync_models.dart';

/// Codec exception for encryption/decryption errors.
class SyncCodecException implements Exception {
  const SyncCodecException(this.message);

  final String message;

  @override
  String toString() => message;
}

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
    Object protocolVersion,
  ) => encodeValue(event.payload, protocolVersion);

  Future<Map<String, Object?>> encodeValue(
    Object? payload,
    Object protocolVersion,
  ) async {
    final payloadHash = computeSyncPayloadHash(payload);
    final keyFingerprint = passphrase.isEmpty
        ? 'none'
        : keyFingerprintFor(passphrase);

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
      final plaintext = utf8.encode(canonicalSyncJson(payload));
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
        'mac': base64Encode(box.mac.bytes),
        'payloadHash': payloadHash,
      };
    }
  }

  /// Decode a JSON envelope to extract payload.
  /// If encrypted, decrypts with the passphrase; otherwise extracts plaintext payload.
  Future<Object?> decode(Map<String, Object?> envelope) async {
    return decodeValue(envelope, expectedProtocolVersion: syncProtocolVersion);
  }

  /// Decode an envelope for a caller-selected protocol version.
  Future<Object?> decodeValue(
    Map<String, Object?> envelope, {
    required Object expectedProtocolVersion,
    int? maxPlaintextBytes,
  }) async {
    if (envelope['protocolVersion'] != expectedProtocolVersion) {
      throw const SyncCodecException('protocol_version');
    }
    final keyFingerprint = envelope['keyFingerprint'] as String?;
    if (keyFingerprint == null) {
      throw const SyncCodecException('Missing keyFingerprint in envelope');
    }

    if (keyFingerprint == 'none') {
      if (passphrase.isNotEmpty) {
        throw const SyncCodecException('Passphrase plaintext forbidden');
      }
      // Plaintext envelope.
      return _verifyHash(envelope, envelope['payload']);
    } else {
      // Encrypted envelope.
      if (passphrase.isEmpty) {
        throw const SyncCodecException(
          'Passphrase required to decrypt envelope',
        );
      }

      final expectedFingerprint = keyFingerprintFor(passphrase);
      if (keyFingerprint != expectedFingerprint) {
        throw const SyncCodecException('Key fingerprint mismatch');
      }

      try {
        final salt = base64Decode(envelope['salt'] as String);
        final nonce = base64Decode(envelope['nonce'] as String);
        final ciphertext = base64Decode(envelope['ciphertext'] as String);

        final key = await _deriveKey(passphrase, salt, _pbkdf2Iterations);
        final mac = base64Decode(envelope['mac'] as String);
        final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
        final decrypted = await _aesGcm.decrypt(box, secretKey: key);
        if (maxPlaintextBytes != null && decrypted.length > maxPlaintextBytes) {
          throw const SyncCodecException('snapshot_plaintext_too_large');
        }
        final payloadJson = utf8.decode(decrypted);
        return _verifyHash(envelope, jsonDecode(payloadJson));
      } on SyncCodecException {
        rethrow;
      } on SecretBoxAuthenticationError {
        throw const SyncCodecException(
          'Decryption failed: wrong passphrase or corrupted data',
        );
      } catch (e) {
        throw SyncCodecException('Decryption error: $e');
      }
    }
  }

  Object? _verifyHash(Map<String, Object?> envelope, Object? payload) {
    if (computeSyncPayloadHash(payload) != envelope['payloadHash']) {
      throw const SyncCodecException('payload_hash_mismatch');
    }
    return payload;
  }

  /// Compute a fingerprint of the passphrase for key identification.
  String get keyFingerprint =>
      passphrase.isEmpty ? 'none' : keyFingerprintFor(passphrase);

  static String keyFingerprintFor(String passphrase) {
    final bytes = utf8.encode(passphrase);
    final hash = crypto.sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }
}
