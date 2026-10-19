enum AppRole { manager, accountant, operations, beneficiary }

class Permissions {
  static bool can(AppRole role, String action) => switch (action) {
    'settings' ||
    'users' ||
    'restore' ||
    'override_queue' ||
    'delete_records' ||
    'close_period' => role == AppRole.manager,
    'beneficiaries' ||
    'irrigation' ||
    'payments' ||
    'expenses' ||
    'queue' ||
    'bookings' ||
    'diesel' ||
    'reports' ||
    'journal' => role == AppRole.manager || role == AppRole.accountant,
    'start_session' || 'postpone_queue' =>
      role == AppRole.manager ||
          role == AppRole.accountant ||
          role == AppRole.operations,
    'view_dashboard' || 'view_sessions' || 'view_queue' || 'view_diesel' =>
      role == AppRole.manager ||
          role == AppRole.accountant ||
          role == AppRole.operations,
    'view_own' || 'request_booking' => role == AppRole.beneficiary,
    _ => false,
  };
}
