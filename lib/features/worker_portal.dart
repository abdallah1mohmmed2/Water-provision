import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/repositories/repositories.dart';
import '../services/local_worker_auth_service.dart';
import '../services/report_service.dart';

class WorkerLoginPage extends StatefulWidget {
  const WorkerLoginPage({super.key,this.auth});
  final LocalWorkerAuthService? auth;
  @override State<WorkerLoginPage> createState()=>_WorkerLoginPageState();
}
class _WorkerLoginPageState extends State<WorkerLoginPage>{
  late final auth=widget.auth??LocalWorkerAuthService();
  final user=TextEditingController(),pass=TextEditingController();
  bool busy=false,hide=true;String? error;
  @override void dispose(){user.dispose();pass.dispose();super.dispose();}
  Future<void> login() async{
    if(busy)return;setState(() { busy=true; error=null; });
    try{
      final ok=await auth.login(user.text,pass.text);
      if(!mounted)return;
      if(!ok){setState(()=>error='بيانات الدخول غير صحيحة أو الحساب غير نشط.');return;}
      Navigator.pushReplacement(context,MaterialPageRoute<void>(builder:(_)=>WorkerHomePage(auth:auth)));
    }catch(e){if(mounted)setState(()=>error='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 5,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.engineering_rounded, size: 54),
                      const SizedBox(height: 12),
                      const Text(
                        'بوابة العامل',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                      ),
                      const Text(
                        'تابع أعمالك ومستحقاتك وكشف حسابك',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: user,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'اسم المستخدم',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: pass,
                        obscureText: hide,
                        onSubmitted: (_) => login(),
                        decoration: InputDecoration(
                          labelText: 'كلمة المرور',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => hide = !hide),
                            icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                          ),
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            error!,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: busy ? null : login,
                        icon: const Icon(Icons.login),
                        label: Text(busy ? 'جارٍ التحقق…' : 'تسجيل الدخول'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'بيانات الدخول والصلاحيات ينشئها مدير المحطة.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12),
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

class WorkerHomePage extends StatefulWidget{
  const WorkerHomePage({required this.auth,super.key});
  final LocalWorkerAuthService auth;
  @override State<WorkerHomePage> createState()=>_WorkerHomePageState();
}
class _WorkerHomePageState extends State<WorkerHomePage>{
  late final repo=StationRepository(widget.auth.db);
  int? id;Map<String,Object?>? worker,summary;
  List<Map<String,Object?>> ledger=[],irrigations=[],payments=[],assignments=[],complaints=[],notifications=[];Set<String> permissions={};
  bool loading=true;String? error;int tab=0;
  final profileName = TextEditingController();
  final profilePhone = TextEditingController();
  int n(Object? v)=>v is num?v.round():int.tryParse('$v')??0;
  String money(Object? v)=>NumberFormat('#,##0').format(n(v));
  String date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':DateFormat('yyyy/MM/dd • hh:mm a','en').format(d);}
  @override void initState(){super.initState();load();}
  @override void dispose(){profileName.dispose();profilePhone.dispose();super.dispose();}
  Future<void> load() async{
    if(mounted)setState(()=>loading=true);
    try{
      final wid=await widget.auth.currentWorkerId();
      if(wid==null)throw StateError('انتهت جلسة الدخول.');
      final granted=await widget.auth.currentPermissions();
      final workerColumns = <String>{
        'id', 'name',
        if (granted.contains('view_profile')) 'phone',
        if (granted.contains('view_account')) ...[
          'pay_type', 'fixed_salary', 'hourly_rate', 'percentage_rate',
        ],
      }.join(',');
      final x=await Future.wait([
        repo.db.rawQuery('SELECT $workerColumns FROM workers WHERE id=? AND station_id=? AND active=1 LIMIT 1',[wid,widget.auth.stationId]),
        granted.contains('view_account') ? repo.partyFinancialSummary('worker',wid) : Future.value(<String,Object?>{}),
        granted.contains('view_account') ? repo.workerTransactions(wid) : Future.value(<Map<String,Object?>>[]),
        granted.contains('view_irrigations') ? repo.db.rawQuery("""SELECT wt.id,wt.date,wt.amount,wt.hours,wt.notes,wt.reference_id irrigation_id,i.start_datetime,COALESCE(b.name,p.name,'غير محدد') party_name
          FROM worker_transactions wt LEFT JOIN irrigations i ON wt.reference_type='irrigation' AND i.id=wt.reference_id
          LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id LEFT JOIN partners p ON p.id=i.partner_id
          WHERE wt.worker_id=? AND wt.type='irrigation' AND COALESCE(wt.notes,'') LIKE 'استحقاق%'
          ORDER BY wt.date DESC,wt.id DESC LIMIT 100""",[wid]) : Future.value(<Map<String,Object?>>[]),
        granted.contains('view_payments') ? repo.db.rawQuery('''SELECT p.id,p.date,p.amount,p.reference_number,p.notes,pm.name payment_method_name,c.name cashbox_name
          FROM payments p LEFT JOIN payment_methods pm ON pm.id=p.payment_method_id
          LEFT JOIN cashboxes c ON c.id=p.cashbox_id
          WHERE p.worker_id=? AND p.status='posted' ORDER BY p.date DESC,p.id DESC''',[wid]) : Future.value(<Map<String,Object?>>[]),
        granted.contains('view_assignments') ? repo.db.rawQuery('''SELECT i.id,i.date,i.start_datetime,i.minutes,i.status,i.system_type,
          COALESCE(b.name,p.name,'غير محدد') party_name
          FROM irrigations i LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id
          LEFT JOIN partners p ON p.id=i.partner_id
          WHERE i.operator_worker_id=? AND i.station_id=?
          ORDER BY i.start_datetime DESC,i.id DESC LIMIT 200''',[wid,widget.auth.stationId]) : Future.value(<Map<String,Object?>>[]),
        granted.contains('view_complaints') ? widget.auth.currentWorkerReports() : Future.value(<Map<String,Object?>>[]),
        granted.contains('view_notifications') ? widget.auth.currentWorkerNotifications() : Future.value(<Map<String,Object?>>[]),
      ]);
      if(!mounted)return;
      final workers=x[0] as List<Map<String,Object?>>;
      if(workers.isEmpty)throw StateError('العامل غير موجود أو غير نشط.');
      setState(() { id=wid; worker=workers.first; profileName.text=workers.first['name']?.toString() ?? ''; profilePhone.text=workers.first['phone']?.toString() ?? ''; summary=x[1] as Map<String,Object?>; ledger=(x[2] as List).cast<Map<String,Object?>>(); permissions=granted; irrigations=(x[3] as List).cast<Map<String,Object?>>(); payments=(x[4] as List).cast<Map<String,Object?>>(); assignments=(x[5] as List).cast<Map<String,Object?>>(); complaints=(x[6] as List).cast<Map<String,Object?>>(); notifications=(x[7] as List).cast<Map<String,Object?>>(); loading=false; error=null; });
    }catch(e){if(mounted)setState(() { loading=false; error='$e'; });}
  }
  void message(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  Future<void> logout()async{await widget.auth.logout();if(!mounted)return;Navigator.pushAndRemoveUntil(context,MaterialPageRoute<void>(builder:(_)=>const WorkerLoginPage()),(_)=>false);}
  Future<void> changePassword()async{
    final old=TextEditingController(),next=TextEditingController(),confirm=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('تغيير كلمة المرور'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:old,obscureText:true,decoration:const InputDecoration(labelText:'الحالية')),
      TextField(controller:next,obscureText:true,decoration:const InputDecoration(labelText:'الجديدة (10 أحرف على الأقل)')),
      TextField(controller:confirm,obscureText:true,decoration:const InputDecoration(labelText:'تأكيد الجديدة'))]),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,old.text.isNotEmpty&&next.text.length>=10&&next.text==confirm.text),child:const Text('تغيير'))]));
    if(ok==true&&mounted){try{await widget.auth.changeCurrentPassword(currentPassword:old.text,newPassword:next.text);message('تم تغيير كلمة المرور');}catch(e){message('$e');}}
    old.dispose();next.dispose();confirm.dispose();
  }
  Widget tile(Map<String,Object?> row){
    final amount=n(row['signed_amount']),positive=amount>=0;
    return Card(elevation:0,child:ListTile(leading:CircleAvatar(child:Icon(positive?Icons.add:Icons.remove,color:positive?Colors.green:Colors.orange)),
      title:Text('${row['description']??row['notes']??'حركة حساب'}',maxLines:2,overflow:TextOverflow.ellipsis),
      subtitle:Text(date(row['date'])),trailing:Text('${positive?'+':'-'}${money(amount.abs())}',style:TextStyle(fontWeight:FontWeight.bold,color:positive?Colors.green:Colors.orange))));
  }
  Widget metric(String title,String value,IconData icon)=>Expanded(child:Card(elevation:0,child:Padding(padding:const EdgeInsets.all(13),child:Column(children:[Icon(icon),const SizedBox(height:6),Text(value,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),Text(title,style:const TextStyle(fontSize:11))]))));
  Widget home(){
    final w=worker!,s=summary??{};
    final balance=n(s['balance']);
    final pay=switch('${w['pay_type']}'){
      'fixed'=>'راتب ثابت: ${money(w['fixed_salary'])} ريال',
      'hourly'=>'أجر الساعة: ${money(w['hourly_rate'])} ريال',
      'percentage'=>'النسبة: ${w['percentage_rate']}% من قيمة السقاية المحتسبة',
      _=>'الأجر غير محدد'
    };
    return ListView(padding:const EdgeInsets.all(16),children:[
      Card(color:Theme.of(context).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('مرحباً، ${w['name']}',style:const TextStyle(fontWeight:FontWeight.w700)),
        const SizedBox(height:8),
        const Text('مساحتك الوظيفية',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
        if(permissions.contains('view_account'))Text(pay),
        if(!permissions.contains('view_account'))const Text('يمكنك متابعة بيانات العمل المسموح بها من هذه البوابة.'),
        if(permissions.contains('view_account'))...[
          const SizedBox(height:12),
          Text(balance==0?'حسابك متوازن':balance>0?'مستحق لك ${money(balance)} ريال':'عليك ${money(balance.abs())} ريال',
            style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900))
        ]
      ]))),
      if(permissions.contains('view_account'))Row(children:[
        metric('الاستحقاقات',money(s['earnings']),Icons.trending_up),
        metric('المدفوع لك',money(s['paid']),Icons.payments)
      ]),
      if(permissions.contains('view_irrigations'))Row(children:[
        metric('استحقاقات السقايات','${irrigations.length}',Icons.water_drop),
      ]),
      if(permissions.contains('view_account'))...[
        const Padding(padding:EdgeInsets.symmetric(vertical:12),child:Text('آخر الحركات',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900))),
        for(final row in ledger.take(5))tile(row)
      ]
    ]);
  }
  Widget assignmentsPage()=>ListView(padding:const EdgeInsets.all(16),children:[
    const Text('تكليفاتي',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
    const SizedBox(height:8),
    const Text('السقايات المسندة إليك كمشغّل من إدارة المحطة.'),
    for(final row in assignments) Card(elevation:0,child:ListTile(
      leading:const CircleAvatar(child:Icon(Icons.assignment_outlined)),
      title:Text('تكليف #${row['id']} • ${row['party_name']??'—'}'),
      subtitle:Text('${date(row['start_datetime']??row['date'])} • ${row['minutes']??0} دقيقة • ${row['system_type']??'—'}'),
      trailing:Text('${row['status']??'—'}'),
    )),
    if(assignments.isEmpty)const Padding(padding:EdgeInsets.all(20),child:Text('لا توجد تكليفات مسجلة لك حتى الآن.')),
  ]);
  Widget profilePage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('ملفي الشخصي', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          children: [
            const CircleAvatar(radius: 34, child: Icon(Icons.person, size: 36)),
            const SizedBox(height: 12),
            TextField(controller: profileName, readOnly: !permissions.contains('edit_profile'),
              decoration: const InputDecoration(labelText: 'الاسم')),
            const SizedBox(height: 10),
            TextField(controller: profilePhone, readOnly: !permissions.contains('edit_profile'),
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'رقم الهاتف')),
            if (!permissions.contains('edit_profile'))
              const Padding(padding: EdgeInsets.only(top: 10),
                child: Text('يمكنك عرض بياناتك فقط. تعديل الملف الشخصي غير مفعل من الإدارة.')),
            if (permissions.contains('edit_profile')) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await widget.auth.updateCurrentProfile(name: profileName.text, phone: profilePhone.text);
                    if (!mounted) return;
                    message('تم تحديث الملف الشخصي');
                    await load();
                  } catch (e) {
                    if (mounted) message('$e');
                  }
                },
                icon: const Icon(Icons.save_outlined), label: const Text('حفظ التعديلات')),
            ],
          ],
        ))),
      ],
    );
  }

  Future<void> createComplaint() async {
    final subject = TextEditingController();
    final description = TextEditingController();
    var category = 'operational';
    final sent = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('إرسال بلاغ للإدارة'),
          content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: category, decoration: const InputDecoration(labelText: 'نوع البلاغ'),
              items: const [
                DropdownMenuItem(value: 'operational', child: Text('مشكلة تشغيلية')),
                DropdownMenuItem(value: 'schedule', child: Text('جدول العمل والتكليف')),
                DropdownMenuItem(value: 'payment', child: Text('استفسار عن مستحقات')),
                DropdownMenuItem(value: 'safety', child: Text('سلامة ومعدات')),
                DropdownMenuItem(value: 'other', child: Text('أخرى')),
              ],
              onChanged: (value) { if (value != null) setDialogState(() => category = value); },
            ),
            const SizedBox(height: 10),
            TextField(controller: subject, maxLength: 120, onChanged: (_) => setDialogState(() {}), decoration: const InputDecoration(labelText: 'عنوان البلاغ')),
            TextField(controller: description, minLines: 4, maxLines: 7, maxLength: 3000, onChanged: (_) => setDialogState(() {}), decoration: const InputDecoration(labelText: 'التفاصيل')),
          ]))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
            FilledButton(onPressed: subject.text.trim().length < 4 || description.text.trim().length < 10 ? null : () => Navigator.pop(dialogContext, true), child: const Text('إرسال')),
          ],
        ),
      ),
    ) ?? false;
    if (sent && mounted) {
      try {
        await widget.auth.submitCurrentWorkerReport(category: category, subject: subject.text, description: description.text);
        message('تم إرسال البلاغ للإدارة');
        await load();
      } catch (e) { message('$e'); }
    }
    subject.dispose(); description.dispose();
  }

  String reportStatusLabel(Object? value) => switch ('$value') {
    'new' => 'جديد', 'under_review' => 'قيد المراجعة', 'accepted' => 'مقبول',
    'rejected' => 'مرفوض', 'resolved' => 'تمت المعالجة', _ => 'غير محدد',
  };

  Widget complaintsPage() => ListView(padding: const EdgeInsets.all(16), children: [
    Row(children: [
      const Expanded(child: Text('بلاغاتي وشكاواي', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
      if (permissions.contains('submit_complaints')) FilledButton.icon(onPressed: createComplaint, icon: const Icon(Icons.add), label: const Text('بلاغ جديد')),
    ]),
    const SizedBox(height: 8), const Text('تابع حالة البلاغ ورد الإدارة من هنا.'),
    for (final report in complaints) Card(child: ExpansionTile(
      leading: CircleAvatar(child: Icon(report['status'] == 'resolved' ? Icons.check_circle_outline : Icons.support_agent)),
      title: Text('${report['subject']}', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${report['category']} • ${date(report['created_at'])} • ${reportStatusLabel(report['status'])}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Align(alignment: Alignment.centerRight, child: Text('${report['description']}')),
        if ('${report['admin_reply'] ?? ''}'.trim().isNotEmpty) ...[
          const Divider(),
          const Align(alignment: Alignment.centerRight, child: Text('رد الإدارة', style: TextStyle(fontWeight: FontWeight.w900))),
          Align(alignment: Alignment.centerRight, child: Text('${report['admin_reply']}')),
        ],
      ],
    )),
    if (complaints.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد بلاغات سابقة.')),
  ]);
  Widget notificationsPage() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('إشعاراتي', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
    const SizedBox(height: 8),
    for (final item in notifications) Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(item['read_at'] == null ? Icons.notifications_active : Icons.notifications_none)),
        title: Text('${item['title']}', style: TextStyle(fontWeight: item['read_at'] == null ? FontWeight.w900 : FontWeight.normal)),
        subtitle: Text('${item['body']}\n${date(item['created_at'])}'),
        isThreeLine: true,
        trailing: item['read_at'] == null ? const Icon(Icons.mark_email_unread_outlined) : const Icon(Icons.done, color: Colors.green),
        onTap: item['read_at'] != null ? null : () async {
          try {
            await widget.auth.markCurrentWorkerNotificationRead((item['id'] as num).toInt());
            await load();
          } catch (e) { message('$e'); }
        },
      ),
    ),
    if (notifications.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد إشعارات حتى الآن.')),
  ]);
  Widget account()=>ListView(padding:const EdgeInsets.all(16),children:[
    Row(children:[const Expanded(child:Text('كشف حسابي',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900))),
      if(permissions.contains('view_reports'))IconButton(icon:const Icon(Icons.picture_as_pdf),onPressed:()async{try{await ReportService(repo).printPdf('worker_transactions',workerId:id);}catch(e){if(mounted)message('تعذر إنشاء PDF: $e');}})]),
    for(final row in ledger)tile(row),if(ledger.isEmpty)const Text('لا توجد حركات مسجلة.')
  ]);
  Widget paymentsPage()=>ListView(padding:const EdgeInsets.all(16),children:[
    const Text('مدفوعاتي',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
    const SizedBox(height:8),
    for(final row in payments)Card(elevation:0,child:ListTile(
      leading:const CircleAvatar(child:Icon(Icons.payments_outlined)),
      title:Text('${money(row['amount'])} ريال',style:const TextStyle(fontWeight:FontWeight.w900)),
      subtitle:Text('${date(row['date'])} • ${row['payment_method_name']??'طريقة غير محددة'}\nسند: ${row['reference_number']??row['id']}'),
      isThreeLine:true,
    )),
    if(payments.isEmpty)const Padding(padding:EdgeInsets.all(24),child:Text('لا توجد دفعات مسجلة لك حتى الآن.'))
  ]);
  Widget irrigationPage()=>ListView(padding:const EdgeInsets.all(16),children:[
    const Text('سجل استحقاقات السقايات',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
    for(final row in irrigations)Card(elevation:0,child:ListTile(leading:const CircleAvatar(child:Icon(Icons.water_drop)),
      title:Text('سقاية #${row['irrigation_id']??'—'} • ${row['party_name']??'—'}'),
      subtitle:Text('${date(row['start_datetime']??row['date'])} • ${row['hours']??0} ساعة'),
      trailing:Text('${money(row['amount'])} ريال',style:const TextStyle(fontWeight:FontWeight.w900)))),
    if(irrigations.isEmpty)const Text('لا توجد استحقاقات سقايات مسجلة.')
  ]);
  @override Widget build(BuildContext context){
    if(loading)return const Scaffold(body:Center(child:CircularProgressIndicator()));
    if(error!=null||worker==null)return Scaffold(appBar:AppBar(title:const Text('بوابة العامل')),body:Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Text(error??'تعذر تحميل البيانات'),FilledButton(onPressed:logout,child:const Text('العودة للدخول'))])));
    final tabs=<({String title,IconData icon,Widget page})>[
      if(permissions.contains('view_dashboard'))(title:'الرئيسية',icon:Icons.home,page:home()),
      if(permissions.contains('view_irrigations'))(title:'السقايات',icon:Icons.water_drop,page:irrigationPage()),
      if(permissions.contains('view_account'))(title:'حسابي',icon:Icons.account_balance_wallet,page:account()),
      if(permissions.contains('view_payments'))(title:'مدفوعاتي',icon:Icons.payments,page:paymentsPage()),
      if(permissions.contains('view_assignments'))(title:'تكليفاتي',icon:Icons.assignment,page:assignmentsPage()),
      if(permissions.contains('view_profile'))(title:'ملفي',icon:Icons.person,page:profilePage()),
      if(permissions.contains('view_complaints'))(title:'بلاغاتي',icon:Icons.support_agent,page:complaintsPage()),
      if(permissions.contains('view_notifications'))(title:'إشعاراتي',icon:Icons.notifications,page:notificationsPage())
    ];
    if(tabs.isEmpty)return Scaffold(appBar:AppBar(title:const Text('بوابة العامل'),actions:[IconButton(onPressed:logout,icon:const Icon(Icons.logout))]),body:const Center(child:Text('لم يمنحك المدير صلاحية عرض الشاشات.')));
    final index=tab.clamp(0,tabs.length-1);
    return Directionality(textDirection:ui.TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:Text('بوابة العامل • ${worker!['name']}'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh)),
        PopupMenuButton<String>(onSelected:(v){if(v=='password')changePassword();if(v=='logout')logout();},itemBuilder:(_)=>const[
          PopupMenuItem(value:'password',child:Text('تغيير كلمة المرور')),PopupMenuItem(value:'logout',child:Text('تسجيل الخروج'))])]),
      body:tabs[index].page,bottomNavigationBar:NavigationBar(selectedIndex:index,onDestinationSelected:(v)=>setState(()=>tab=v),
        destinations:[for(final t in tabs)NavigationDestination(icon:Icon(t.icon),label:t.title)])
    ));
  }
}
