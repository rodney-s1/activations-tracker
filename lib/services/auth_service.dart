// Authentication Service
// Uses Google Identity Services (GIS) JavaScript API directly via dart:js_interop.
// No Flutter plugin needed — works natively on Flutter Web.
//
// Domain enforcement:
//   • Only @bluearrowmail.com accounts are permitted.
//   • Any other Google account is rejected with a clear error message.
//
// Flow:
//   1. GIS renders a "Sign in with Google" button (or triggers One Tap prompt).
//   2. On success, Google returns a JWT credential (id_token).
//   3. We decode the JWT payload to extract email, name, picture.
//   4. Domain check: reject non-@bluearrowmail.com accounts immediately.
//   5. Store user in memory + cache email in SharedPreferences for UX continuity.

import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const String kAllowedDomain   = 'bluearrowmail.com';
const String kGoogleClientId  =
    '127481200033-mc2lspmv21bqii6eaarfop3n2ci5ueil.apps.googleusercontent.com';

const String _kCachedEmail       = 'auth_cached_email';
const String _kCachedDisplayName = 'auth_cached_display_name';
const String _kCachedPhotoUrl    = 'auth_cached_photo_url';

// ── JS interop declarations ───────────────────────────────────────────────────

@JS('google.accounts.id.initialize')
external void _gisInitialize(JSObject config);

@JS('google.accounts.id.prompt')
external void _gisPrompt([JSFunction? momentListener]);

@JS('google.accounts.id.renderButton')
external void _gisRenderButton(JSObject element, JSObject options);

@JS('google.accounts.id.disableAutoSelect')
external void _gisDisableAutoSelect();

@JS('document.getElementById')
external JSObject? _getElementById(String id);

// ── AuthUser value object ─────────────────────────────────────────────────────

class AuthUser {
  final String email;
  final String displayName;
  final String photoUrl;
  final String idToken;

  const AuthUser({
    required this.email,
    required this.displayName,
    required this.photoUrl,
    required this.idToken,
  });

  bool get isBlueArrow => email.toLowerCase().endsWith('@$kAllowedDomain');
}

// ── AuthService ───────────────────────────────────────────────────────────────

class AuthService extends ChangeNotifier {
  // Singleton
  static final AuthService instance = AuthService._();
  AuthService._();

  AuthUser? _currentUser;
  bool      _isLoading = false;
  String    _errorMsg  = '';

  AuthUser? get currentUser  => _currentUser;
  bool      get isSignedIn   => _currentUser != null;
  bool      get isLoading    => _isLoading;
  String    get errorMessage => _errorMsg;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    // Initialise GIS with our callback — called automatically on One Tap or
    // after renderButton click.
    try {
      _gisInitialize({
        'client_id': kGoogleClientId,
        'callback': _handleCredentialResponse.toJS,
        'auto_select': false,
        'cancel_on_tap_outside': true,
        'hosted_domain': kAllowedDomain,
      }.jsify()! as JSObject);
    } catch (e) {
      debugPrint('[AuthService] GIS init error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  /// Called by the LoginScreen button — triggers the One Tap / popup flow.
  Future<bool> signIn() async {
    _setLoading(true);
    _errorMsg = '';
    notifyListeners();

    // GIS handles the popup; result comes back via _handleCredentialResponse.
    // We prompt and then wait — the callback will call notifyListeners() when done.
    try {
      _gisPrompt(null);
    } catch (e) {
      _errorMsg = 'Could not open Google sign-in. Error: $e';
      _setLoading(false);
      return false;
    }

    // Return true optimistically; actual auth state set in callback.
    return true;
  }

  /// Renders the official Google Sign-In button inside the element with [elementId].
  void renderButton(String elementId) {
    try {
      final el = _getElementById(elementId);
      if (el == null) return;
      _gisRenderButton(el, {
        'theme': 'outline',
        'size': 'large',
        'width': 320,
        'text': 'signin_with',
        'shape': 'rectangular',
        'logo_alignment': 'left',
      }.jsify()! as JSObject);
    } catch (e) {
      debugPrint('[AuthService] renderButton error: $e');
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try { _gisDisableAutoSelect(); } catch (_) {}
    _currentUser = null;
    _errorMsg    = '';
    await _clearCache();
    notifyListeners();
  }

  // ── GIS credential callback ───────────────────────────────────────────────

  /// Called by Google Identity Services when the user completes sign-in.
  /// [response] is a JS object with a `credential` field (JWT id_token).
  void _handleCredentialResponse(JSObject response) {
    try {
      final credential = (response as JSAny).dartify() as Map?;
      final idToken = credential?['credential'] as String? ?? '';

      if (idToken.isEmpty) {
        _errorMsg = 'Sign-in failed: no credential received.';
        _setLoading(false);
        return;
      }

      // Decode JWT payload (middle section between the two dots).
      final parts = idToken.split('.');
      if (parts.length != 3) {
        _errorMsg = 'Sign-in failed: invalid token format.';
        _setLoading(false);
        return;
      }

      // Base64url decode the payload
      String payload = parts[1];
      // Pad to multiple of 4
      while (payload.length % 4 != 0) { payload += '='; }
      final decoded = utf8.decode(base64Url.decode(payload));
      final claims  = json.decode(decoded) as Map<String, dynamic>;

      final email   = (claims['email']   as String? ?? '').toLowerCase();
      final name    = claims['name']     as String? ?? email.split('@').first;
      final picture = claims['picture']  as String? ?? '';

      // Domain enforcement
      if (!email.endsWith('@$kAllowedDomain')) {
        _errorMsg = 'Access restricted to @$kAllowedDomain accounts.\n'
            '"$email" is not authorised.';
        _setLoading(false);
        // Force sign out of the Google session too
        try { _gisDisableAutoSelect(); } catch (_) {}
        return;
      }

      _currentUser = AuthUser(
        email:       email,
        displayName: name,
        photoUrl:    picture,
        idToken:     idToken,
      );

      _persistCache(_currentUser!);
      _errorMsg = '';
      _setLoading(false);
      notifyListeners();

    } catch (e) {
      _errorMsg = 'Sign-in error: $e';
      _setLoading(false);
      debugPrint('[AuthService] _handleCredentialResponse error: $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  Future<void> _persistCache(AuthUser u) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCachedEmail,       u.email);
      await prefs.setString(_kCachedDisplayName, u.displayName);
      await prefs.setString(_kCachedPhotoUrl,    u.photoUrl);
    } catch (_) {}
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCachedEmail);
      await prefs.remove(_kCachedDisplayName);
      await prefs.remove(_kCachedPhotoUrl);
    } catch (_) {}
  }

  static Future<String?> getCachedEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kCachedEmail);
    } catch (_) {
      return null;
    }
  }
}
