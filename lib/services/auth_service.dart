// Authentication Service
// Handles Google Sign-In with @bluearrowmail.com domain restriction.
// Uses the google_sign_in package (wraps Google Identity Services on web).
//
// Domain enforcement:
//   • Only accounts ending in @bluearrowmail.com are permitted.
//   • Any other Google account is signed out immediately with a clear error.
//
// The signed-in user's email is used as the Cloud Sync userId so each
// employee's data is stored under their own path in Firebase RTDB.

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const String kAllowedDomain = 'bluearrowmail.com';

// SharedPreferences key — persists the last signed-in email so the app can
// show the user's name on subsequent launches before the token is refreshed.
const String _kCachedEmail       = 'auth_cached_email';
const String _kCachedDisplayName = 'auth_cached_display_name';
const String _kCachedPhotoUrl    = 'auth_cached_photo_url';

// ── AuthUser value object ─────────────────────────────────────────────────────

class AuthUser {
  final String email;
  final String displayName;
  final String photoUrl;
  final String idToken; // Google ID token — used as Firebase RTDB auth token

  const AuthUser({
    required this.email,
    required this.displayName,
    required this.photoUrl,
    required this.idToken,
  });

  /// The sanitised email prefix used as the Cloud Sync userId.
  /// e.g. "john.smith@bluearrowmail.com" → "john.smith_bluearrowmail.com"
  String get syncUserId =>
      email.toLowerCase().replaceAll('@', '_').replaceAll(RegExp(r'[^a-z0-9._-]'), '_');

  bool get isBlueArrow =>
      email.toLowerCase().endsWith('@$kAllowedDomain');
}

// ── AuthService ───────────────────────────────────────────────────────────────

class AuthService extends ChangeNotifier {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final AuthService instance = AuthService._();
  AuthService._();

  // ── Google Sign-In instance ───────────────────────────────────────────────
  // clientId is set via web/index.html meta tag (see setup instructions).
  // scopes: email + profile are sufficient for domain check + display name.
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile', 'openid'],
    hostedDomain: kAllowedDomain, // restricts the Google account picker to @bluearrowmail.com
  );

  // ── State ─────────────────────────────────────────────────────────────────
  AuthUser? _currentUser;
  bool      _isLoading  = false;
  String    _errorMsg   = '';

  AuthUser? get currentUser  => _currentUser;
  bool      get isSignedIn   => _currentUser != null;
  bool      get isLoading    => _isLoading;
  String    get errorMessage => _errorMsg;

  // ── Initialise ────────────────────────────────────────────────────────────

  /// Call once in main() — attempts silent sign-in to restore session.
  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    try {
      // Try to restore a previous session silently (no UI popup).
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        await _handleAccount(account, silent: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] Silent sign-in failed: $e');
      // Non-fatal — user will see the login screen
    }

    _isLoading = false;
    notifyListeners();
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  /// Triggers the Google account picker popup.
  /// Returns true on success, false on failure/domain mismatch.
  Future<bool> signIn() async {
    _setLoading(true);
    _errorMsg = '';

    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        // User dismissed the popup
        _setLoading(false);
        return false;
      }
      return await _handleAccount(account);
    } catch (e) {
      _errorMsg = 'Sign-in failed. Please try again.';
      if (kDebugMode) debugPrint('[AuthService] signIn error: $e');
      _setLoading(false);
      return false;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    _currentUser = null;
    _errorMsg    = '';
    await _clearCache();
    notifyListeners();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<bool> _handleAccount(GoogleSignInAccount account, {bool silent = false}) async {
    final email = account.email.toLowerCase();

    // ── Domain enforcement ─────────────────────────────────────────────────
    if (!email.endsWith('@$kAllowedDomain')) {
      await _googleSignIn.signOut();
      _errorMsg = 'Access restricted to @$kAllowedDomain accounts.\n'
          '"$email" is not authorised.';
      _setLoading(false);
      return false;
    }

    // ── Retrieve ID token ──────────────────────────────────────────────────
    String idToken = '';
    try {
      final auth = await account.authentication;
      idToken = auth.idToken ?? '';
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] Could not get idToken: $e');
      // Continue without token — RTDB rules won't work but app still loads
    }

    _currentUser = AuthUser(
      email:       email,
      displayName: account.displayName ?? email.split('@').first,
      photoUrl:    account.photoUrl    ?? '',
      idToken:     idToken,
    );

    await _persistCache(_currentUser!);
    _errorMsg = '';
    _setLoading(false);
    notifyListeners();
    return true;
  }

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

  /// Read the cached email from SharedPreferences (available before init completes).
  static Future<String?> getCachedEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kCachedEmail);
    } catch (_) {
      return null;
    }
  }
}
