import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStore {
  Future<void> write(String userId, String token);
  Future<String?> read(String userId);
  Future<void> delete(String userId);
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<void> write(String userId, String token) =>
      _storage.write(key: 'session:$userId', value: token);

  @override
  Future<String?> read(String userId) => _storage.read(key: 'session:$userId');

  @override
  Future<void> delete(String userId) => _storage.delete(key: 'session:$userId');
}
