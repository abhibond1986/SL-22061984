// lib/screens/force_password_change_screen.dart
// ═══════════════════════════════════════════════════════════════════════════
//  The gate between a bulk-imported account and the portal.
//
//  Imported employees start with their SAIL P.no as their password. That value
//  is printed on their ID card and sits in a spreadsheet that HR, the safety
//  cell and every plant admin holds a copy of — so it lets the right person in
//  once, and it must not survive past that.
//
//  This screen is therefore deliberately hard to escape. There is no back
//  button, and cancelling signs the session out rather than continuing into the
//  app: an account that is one tap away from the dashboard on a password
//  thousands of people can look up is not meaningfully protected.
//
//  It is also shown after an admin resets someone's password, for the same
//  reason — the admin knows that value too.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../services/local_db.dart';
import '../services/validators.dart';

class ForcePasswordChangeScreen extends StatefulWidget {
  const ForcePasswordChangeScreen({
    super.key,
    required this.username,
    required this.currentPassword,
    this.name = '',
  });

  final String username;

  /// The password they just signed in with, passed through so they do not have
  /// to type it a second time — they are here because it was handed to them, not
  /// because they chose it.
  final String currentPassword;

  final String name;

  @override
  State<ForcePasswordChangeScreen> createState() =>
      _ForcePasswordChangeScreenState();
}

class _ForcePasswordChangeScreenState extends State<ForcePasswordChangeScreen> {
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String _err = '';

  @override
  void dispose() {
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final next = _newCtrl.text;
    final confirm = _confirmCtrl.text;

    final strengthErr = Validators.validatePassword(next);
    if (strengthErr != null) {
      setState(() => _err = strengthErr);
      return;
    }
    if (next != confirm) {
      setState(() => _err = 'The two passwords do not match.');
      return;
    }
    // Case-insensitive on purpose. "a000168" is not a new password just because
    // the P.no was written "A000168".
    if (next.trim().toLowerCase() ==
        widget.currentPassword.trim().toLowerCase()) {
      setState(() => _err =
          'Choose something other than your employee number — everyone who has '
          'the employee list already knows it.');
      return;
    }

    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      final res = await AuthService.changePassword(
        username: widget.username,
        currentPassword: widget.currentPassword,
        newPassword: next,
      );
      if (!mounted) return;
      if (res.ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _err = res.message);
      }
    } catch (e) {
      if (mounted) setState(() => _err = 'Could not save the new password: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    // Sign out rather than let a half-authenticated session through. signIn has
    // already written the current user, so simply popping would leave the app
    // signed in on the very password this screen exists to retire.
    await LocalDB.signOut();
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return WillPopScope(
      // The system back gesture must not slip past this screen.
      onWillPop: () async {
        await _cancel();
        return false;
      },
      child: Scaffold(
        backgroundColor: sl.bg,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: sl.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: sl.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.lock_reset_rounded,
                          size: 40, color: sl.accentText),
                      const SizedBox(height: 14),
                      Text(
                        widget.name.trim().isEmpty
                            ? 'Choose your password'
                            : 'Welcome, ${widget.name.trim()}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: sl.text1,
                            fontSize: 20,
                            fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Your account was created with your employee number as '
                        'its password. Anyone with the employee list can read '
                        'that, so please set your own before you continue. Your '
                        'username stays ${widget.username}.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: sl.text3, fontSize: 13, height: 1.5),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _newCtrl,
                        obscureText: _obscure,
                        autofocus: true,
                        style: TextStyle(color: sl.text1),
                        decoration: InputDecoration(
                          labelText: 'New password',
                          labelStyle: TextStyle(color: sl.text3),
                          helperText: 'At least '
                              '${AuthService.minPasswordLength} characters',
                          helperStyle:
                              TextStyle(color: sl.text4, fontSize: 11),
                          filled: true,
                          fillColor: sl.card2,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: sl.border)),
                          suffixIcon: IconButton(
                            icon: Icon(
                                _obscure
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
                                color: sl.text4, size: 20),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmCtrl,
                        obscureText: _obscure,
                        style: TextStyle(color: sl.text1),
                        onSubmitted: (_) => _busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: 'Confirm new password',
                          labelStyle: TextStyle(color: sl.text3),
                          filled: true,
                          fillColor: sl.card2,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: sl.border)),
                        ),
                      ),
                      if (_err.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(_err,
                            style: TextStyle(
                                color: sl.critText, fontSize: 12.5, height: 1.4)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 15)),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.4, color: Colors.white))
                            : const Text('Save and continue'),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy ? null : _cancel,
                        child: Text('Sign out instead',
                            style: TextStyle(color: sl.text4, fontSize: 12.5)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
