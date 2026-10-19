import 'package:sqflite/sqflite.dart';

/// إنهاء دور مستفيد في الطابور داخل معاملة قائمة.
/// - الطابور الدائري: يُرقَّم المنتظرون من جديد ثم يُوضَع من خُدم في آخر الطابور (حالة waiting)
///   وتزداد دورته، فيدور الطابور بدل أن يختفي المستفيد بعد خدمته.
/// - غير الدائري: يُثبَّت الإدخال بحالة served.
Future<void> completeQueueEntryTx(
  DatabaseExecutor ex,
  int entryId,
  String now, {
  required bool circular,
}) async {
  final cur = await ex.rawQuery(
    'SELECT cycle_number FROM queue_entries WHERE id=?',
    [entryId],
  );
  if (cur.isEmpty) throw StateError('إدخال الطابور غير موجود');
  if (!circular) {
    await ex.update(
      'queue_entries',
      {'status': 'served', 'last_served_at': now, 'updated_at': now},
      where: 'id=?',
      whereArgs: [entryId],
    );
    return;
  }
  final rest = await ex.rawQuery(
    "SELECT id FROM queue_entries WHERE id<>? AND status IN ('waiting','postponed') ORDER BY position, id",
    [entryId],
  );
  for (var i = 0; i < rest.length; i++) {
    await ex.update(
      'queue_entries',
      {'position': i + 1},
      where: 'id=?',
      whereArgs: [rest[i]['id']],
    );
  }
  final cycle = ((cur.first['cycle_number'] as num?)?.toInt() ?? 1) + 1;
  await ex.update(
    'queue_entries',
    {
      'position': rest.length + 1,
      'status': 'waiting',
      'cycle_number': cycle,
      'last_served_at': now,
      'updated_at': now,
    },
    where: 'id=?',
    whereArgs: [entryId],
  );
}
