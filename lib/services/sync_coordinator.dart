import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';

import '../api/api_client.dart';
import '../data/local/database.dart';
import 'sync_service.dart';
import 'sync_inbox_applier.dart';

class SyncRuntimeStatus {
  final bool connected;
  final bool busy;
  final int pending;
  final int inboxPending;
  final String? error;
  final DateTime? lastSyncAt;

  const SyncRuntimeStatus({
    this.connected = false,
    this.busy = false,
    this.pending = 0,
    this.inboxPending = 0,
    this.error,
    this.lastSyncAt,
  });

  SyncRuntimeStatus copyWith({
    bool? connected,
    bool? busy,
    int? pending,
    int? inboxPending,
    String? error,
    bool clearError = false,
    DateTime? lastSyncAt,
  }) => SyncRuntimeStatus(
    connected: connected ?? this.connected,
    busy: busy ?? this.busy,
    pending: pending ?? this.pending,
    inboxPending: inboxPending ?? this.inboxPending,
    error: clearError ? null : error ?? this.error,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
  );
}

/// Owns the authenticated API client and drains the local Outbox when the
/// network returns, the app resumes, or the retry interval elapses.
class SyncCoordinator with WidgetsBindingObserver {
  SyncCoordinator._();
  static final SyncCoordinator instance = SyncCoordinator._();

  static const _tokenKey = 'saqia.sync.admin_token';
  static const _storage = FlutterSecureStorage();
  final status = ValueNotifier(const SyncRuntimeStatus());
  final _connectivity = Connectivity();

  SyncService? _service;
  ApiClient? get apiClient => _service?.api;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _retryTimer;
  bool _observing = false;
  bool _running = false;

  Future<void> connect({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final normalized = _normalizeBaseUrl(baseUrl);
    final client = ApiClient(normalized);
    final result = await client.post('/auth/login', {
      'username': username.trim(),
      'password': password,
    });
    if (result is! Map || result['token'] is! String) {
      throw StateError('استجابة تسجيل الدخول من الخادم غير صالحة.');
    }
    final token = result['token'] as String;
    client.setToken(token);
    await AppDatabase.instance.insert('settings', {
      'key': 'server_url',
      'value': normalized,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _storage.write(key: _tokenKey, value: token);
    _attach(client);
    await syncNow();
  }

  String _normalizeBaseUrl(String value) {
    final raw = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasAuthority ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError('أدخل عنوان خادم صحيحاً يبدأ بـ https:// أو http://.');
    }
    if (uri.path.endsWith('/api/v1')) {
      return raw.substring(0, raw.length - '/api/v1'.length);
    }
    return raw;
  }

  Future<void> resume() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null || token.isEmpty) return;
    final rows = await AppDatabase.instance.query(
      "SELECT value FROM settings WHERE key='server_url' LIMIT 1",
    );
    if (rows.isEmpty) return;
    final baseUrl = _normalizeBaseUrl('${rows.first['value'] ?? ''}');
    final client = ApiClient(baseUrl, token: token);
    _attach(client);
    await _refreshCounts();
    final connectivity = await _connectivity.checkConnectivity();
    final online = connectivity.any((x) => x != ConnectivityResult.none);
    status.value = status.value.copyWith(connected: online);
    if (online) unawaited(_syncQuietly());
  }

  void _attach(ApiClient client) {
    _service = SyncService.withInboxHandler(
      client,
      applyIncoming: SyncInboxApplier.apply,
    );
    _ensureObservers();
    status.value = status.value.copyWith(connected: true, clearError: true);
    _startRetryTimer();
  }

  void _ensureObservers() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        final online = results.any((x) => x != ConnectivityResult.none);
        status.value = status.value.copyWith(connected: online);
        if (online && _service != null) unawaited(_syncQuietly());
      },
      onError: (Object error) {
        status.value = status.value.copyWith(error: error.toString());
      },
    );
  }

  void _startRetryTimer() {
    _retryTimer ??= Timer.periodic(const Duration(seconds: 45), (_) {
      if (_service != null) unawaited(_syncQuietly());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _service != null) {
      unawaited(_syncQuietly());
    }
  }

  Future<void> _refreshCounts() async {
    final service = _service;
    if (service == null) return;
    final pending = await service.pendingCount();
    final inbox = await AppDatabase.instance.query(
      "SELECT COUNT(*) AS n FROM sync_inbox WHERE status='pending'",
    );
    status.value = status.value.copyWith(
      pending: pending,
      inboxPending: (inbox.first['n'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> _syncQuietly() async {
    try {
      await syncNow();
    } catch (_) {
      // Background retries expose failures through the status notifier.
    }
  }

  Future<void> syncNow() async {
    final service = _service;
    if (service == null || _running) return;
    _running = true;
    status.value = status.value.copyWith(busy: true, clearError: true);
    try {
      await service.push();
      await service.pull();
      await service.retryDeferredInbox();
      await service.applyInbox();
      await _refreshCounts();
      status.value = status.value.copyWith(
        lastSyncAt: DateTime.now(),
        clearError: true,
      );
    } catch (error) {
      status.value = status.value.copyWith(error: error.toString());
      rethrow;
    } finally {
      _running = false;
      status.value = status.value.copyWith(busy: false);
      await _refreshCounts();
    }
  }

  Future<void> disconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    _service = null;
    await _storage.delete(key: _tokenKey);
    status.value = const SyncRuntimeStatus();
  }
}
