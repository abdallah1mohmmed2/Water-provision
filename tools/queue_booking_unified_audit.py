from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'lib/features/app.dart'
REPO = ROOT / 'lib/data/repositories/repositories.dart'
s = APP.read_text(encoding='utf-8')
r = REPO.read_text(encoding='utf-8')
checks=[]
def ck(name, cond):
    checks.append((name, bool(cond)))

# Queue/booking screen is a single user-facing turn lane.
page = s[s.index('class QueueBookingPage'):s.index('class DieselPage')]
ck('queue page reads queue_type', "settings['queue_type']" in page)
ck('circular mode loads queue only', "mode == 'booking' ? <Map<String, Object?>>[] : await widget.r.queue()" in page)
ck('booking mode loads booking requests only', "mode == 'booking'" in page and "await widget.r.bookings(status)" in page and "<Map<String, Object?>>[]" in page)
ck('single current-turn section', page.count("title: isBookingMode ? 'الدور الحالي' : 'ترتيب الدور الحالي'") == 1)
ck('no parallel booking section', "title: 'طلبات الحجز'" not in page)
ck('no parallel queue section', "title: 'الطابور الحالي'" not in page)
ck('action adapts to mode', "if (isBookingMode)" in page and "label: const Text('إضافة طلب للدور')" in page and "label: const Text('إضافة إلى الدور')" in page)

# New irrigation has one turn selector, not separate queue + booking selectors.
ni = s[s.index('class NewIrrigationPage'):s.index('class IrrigationsPage') if 'class IrrigationsPage' in s else s.index('class SessionsPage')]
ck('new irrigation has queue_type state', "String partyType = 'beneficiary', type = 'diesel', queueType = 'circular', search = '';" in ni)
ck('new irrigation one turn selector', "queueType == 'booking' ? 'الدور المحجوز' : 'الدور الحالي'" in ni)
ck('new irrigation clears the other turn id', "queueId = queueType == 'circular' ? v : null;" in ni and "bookingId = queueType == 'booking' ? v : null;" in ni)
ck('new irrigation no separate queue field', "fieldSelect<int>('دور الطابور'" not in ni)
ck('new irrigation no separate booking field', "fieldSelect<int>('الحجز'" not in ni)

# Sessions follow the same single-turn concept and configured pump.
ss = s[s.index('class SessionsPage'):s.index('class QueueBookingPage')]
ck('sessions have one turn selector', "queueType == 'booking' ? 'الدور المحجوز' : 'الدور الحالي'" in ss)
ck('sessions no pump selector', "decoration: const InputDecoration(labelText: 'المضخة')" not in ss)
ck('sessions derive pump from selected setting', "selected_pump_id" in ss)

# Accounting still stores the two underlying IDs, while UI treats them as one turn source.
ck('accounting persists booking linkage', "'booking_id': bookingId," in r or "booking_id" in s)
ck('accounting persists queue linkage', "'queue_entry_id': queueId," in r or "queue_entry_id" in s)


# Booking acceptance transition checks.
accept = r[r.index('Future<void> acceptBookingToQueue'):r.index('Future<void> updateBookingNotes')]
ck('booking acceptance is transactional', 'db.transaction((tx) async' in accept)
ck('circular acceptance inserts queue entry', "tx.insert('queue_entries'" in accept and "mode != 'booking'" in accept)
ck('acceptance marks booking accepted', "'status': 'accepted'" in accept)
ck('acceptance prevents duplicate active queue entries', "existing.isEmpty" in accept and "status IN ('waiting','postponed')" in accept)
ck('UI exposes explicit accept action', "label: const Text('قبول')" in page and "acceptBooking(booking)" in page)
ck('booking lane shows accepted entries only', "b.where((x) => const {'accepted', 'notified'}" in page)
ck('pending bookings separated from current lane', "pendingBookings.isNotEmpty" in page and "for (final booking in pendingBookings)" in page)


ck('beneficiary booking queue excludes unaccepted requests', "WHERE br.status IN ('accepted','notified')" in r)
ck('session start requires accepted booking', "'scheduled'," not in r[r.index('Future<int> startSession'):r.index('Future<void> stopSession')])
ck('irrigation booking link excludes unaccepted requests', "static const _openBookingStatuses = ['accepted', 'notified'];" in page)
ck('session booking selector only offers accepted requests', "const {'accepted', 'notified'}.contains('${x['status']}')" in page)


ck('circular booking filter remains available without pending requests', "if (!isBookingMode || pendingBookings.isNotEmpty)" in page)
ck('booking filter chips are not duplicated', page.count("_statusChip('كل الطلبات', null)") == 2)
ck('beneficiary booking queue excludes unaccepted requests', "WHERE br.status IN ('accepted','notified')" in r)
ck('session start requires accepted booking', "'scheduled'," not in r[r.index('Future<int> startSession'):r.index('Future<void> stopSession')])
ck('irrigation booking link excludes unaccepted requests', "static const _openBookingStatuses = ['accepted', 'notified'];" in page)
ck('session booking selector only offers accepted requests', "const {'accepted', 'notified'}.contains('${x['status']}')" in page)

failed=[n for n,ok in checks if not ok]
for n,ok in checks:
    print(('PASS' if ok else 'FAIL')+': '+n)
print(f'RESULT: {len(checks)-len(failed)}/{len(checks)} PASS')
if failed:
    sys.exit(1)
