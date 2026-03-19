// Login Screen
// Shown when the user is not authenticated.
// Presents a clean Blue Arrow branded sign-in page with a Google Sign-In button.
// Only @bluearrowmail.com accounts are accepted — any other account shows an error.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../utils/app_theme.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.navyDark,
      body: Center(
        child: ChangeNotifierProvider.value(
          value: AuthService.instance,
          child: const _LoginCard(),
        ),
      ),
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return Container(
      width: 420,
      margin: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.navyMid,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.teal.withValues(alpha: 0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 44, 36, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Logo / icon ───────────────────────────────────────────
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.teal.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppTheme.teal.withValues(alpha: 0.4), width: 1.5),
              ),
              child: const Icon(Icons.location_on,
                  size: 36, color: AppTheme.tealLight),
            ),
            const SizedBox(height: 24),

            // ── App name ──────────────────────────────────────────────
            const Text(
              'Activation Tracker',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Blue Arrow GPS',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.tealLight,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Sign in with your @bluearrowmail.com account',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),

            const SizedBox(height: 36),

            // ── Error message ─────────────────────────────────────────
            if (auth.errorMessage.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.red.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 16, color: AppTheme.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        auth.errorMessage,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.red,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── Sign-In button ────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: auth.isLoading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                AppTheme.tealLight),
                          ),
                        ),
                      ),
                    )
                  : _GoogleSignInButton(
                      onPressed: () => AuthService.instance.signIn(),
                    ),
            ),

            const SizedBox(height: 28),

            // ── Footer ────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 12, color: Colors.white.withValues(alpha: 0.3)),
                const SizedBox(width: 5),
                Text(
                  'Restricted to @bluearrowmail.com',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Google Sign-In button widget ──────────────────────────────────────────────

class _GoogleSignInButton extends StatefulWidget {
  final VoidCallback onPressed;
  const _GoogleSignInButton({required this.onPressed});

  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter:  (_) => setState(() => _hovering = true),
      onExit:   (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: _hovering ? Colors.white : Colors.white.withValues(alpha: 0.93),
            borderRadius: BorderRadius.circular(10),
            boxShadow: _hovering
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Google "G" logo
              _GoogleLogo(size: 20),
              const SizedBox(width: 12),
              const Text(
                'Sign in with Google',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF3C4043),
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hand-drawn Google "G" logo using a CustomPainter — no image asset needed.
class _GoogleLogo extends StatelessWidget {
  final double size;
  const _GoogleLogo({this.size = 24});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final r  = size.width  / 2;

    // Blue segment (top-right)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -1.05, 1.57, false,
      Paint()..color = const Color(0xFF4285F4)..style = PaintingStyle.stroke..strokeWidth = size.width * 0.22,
    );
    // Red segment (top-left)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      -2.62, 1.57, false,
      Paint()..color = const Color(0xFFEA4335)..style = PaintingStyle.stroke..strokeWidth = size.width * 0.22,
    );
    // Yellow segment (bottom-left)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      2.09, 1.05, false,
      Paint()..color = const Color(0xFFFBBC05)..style = PaintingStyle.stroke..strokeWidth = size.width * 0.22,
    );
    // Green segment (bottom-right)
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r),
      3.14, 1.05, false,
      Paint()..color = const Color(0xFF34A853)..style = PaintingStyle.stroke..strokeWidth = size.width * 0.22,
    );

    // Horizontal bar of the G
    canvas.drawRect(
      Rect.fromLTWH(cx, cy - size.height * 0.11, r * 0.85, size.height * 0.22),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
