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
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:Scaffold(
    body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(22),child:ConstrainedBox(
      constraints:const BoxConstraints(maxWidth:440),child:Card(elevation:5,child:Padding(padding:const EdgeInsets.all(24),
        child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          const Icon(Icons.engineering_rounded,size:54),const SizedBox(height:12),
          const Text('بوابة العامل',textAlign:TextAlign.center,style:TextStyle(fontSize:25,fontWeight:FontWeight.w900)),
          const Text('تابع أعمالك ومستحقاتك وكشف حسابك',textAlign:TextAlign.center),
          const SizedBox(height:22),
          TextField(controller:user,autocorrect:false,decoration:const InputDecoration(labelText:'اسم المستخدم',prefixIcon:Icon(Icons.person_outline),border:OutlineInputBorder())),
          const SizedBox(height:12),
          TextField(controller:pass,obscureText:hide,onSubmitted:(_)=>login(),decoration:InputDecoration(labelText:'كلمة المرور',prefixIcon:const Icon(Icons.lock_outline),border:const OutlineInputBorder(),
            suffixIcon:IconButton(onPressed:()=>setState(()=>hide=!hide),icon:Icon(hide?Icons.visibility:Icons.visibility_off)))),
          if(error!=null)Padding(padding:const EdgeInsets.only(top:10),child:Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
          const SizedBox(height:16),FilledButton.icon(onPressed:busy?null:login,icon:const Icon(Icons.login),label:Text(busy?'جارٍ التحقق…':'تسجيل الدخول')),
          const SizedBox(height:8),const Text('بيانات الدخول والصلاحيات ينشئها مدير المحطة.',textAlign:TextAlign.center,style:TextStyle(fontSize:12))
        ]))))))),
  ));
}

class WorkerHomePage extends StatefulWidget{
  const WorkerHomePage({required this.auth,super.key});
  final LocalWorkerAuthService auth;
  @override State<WorkerHomePage> createState()=>_WorkerHomePageState();
}
class _WorkerHomePageState extends State<WorkerHomePage>{
  late final repo=StationRepository(widget.auth.db);
  int? id;Map<String,Object?>? worker,summary;
  List<Map<String,Object?>> ledger=[],irrigations=[];Set<String> permissions={};
  bool loading=true;String? error;int tab=0;
  int n(Object? v)=>v is num?v.round():int.tryParse('$v')??0;
  String money(Object? v)=>NumberFormat('#,##0').format(n(v));
  String date(Object? v){final d=DateTime.tryParse('$v');return d==null?'—':DateFormat('yyyy/MM/dd • hh:mm a','en').format(d);}
  @override void initState(){super.initState();load();}
  Future<void> load() async{
    if(mounted)setState(()=>loading=true);
    try{
      final wid=await widget.auth.currentWorkerId();if(wid==null)throw StateError('انتهت جلسة الدخول.');
      final x=await Future.wait([
        repo.db.rawQuery('SELECT id,name,pay_type,fixed_salary,hourly_rate,percentage_rate FROM workers WHERE id=? AND station_id=? AND active=1',[wid,widget.auth.stationId]),
        repo.partyFinancialSummary('worker',wid),repo.workerTransactions(wid),widget.auth.currentPermissions(),
        repo.db.rawQuery("""SELECT wt.id,wt.date,wt.amount,wt.hours,wt.notes,wt.reference_id irrigation_id,i.start_datetime,COALESCE(b.name,p.name,'غير محدد') party_name
          FROM worker_transactions wt LEFT JOIN irrigations i ON wt.reference_type='irrigation' AND i.id=wt.reference_id
          LEFT JOIN beneficiaries b ON b.id=i.beneficiary_id LEFT JOIN partners p ON p.id=i.partner_id
          WHERE wt.worker_id=? AND wt.type='irrigation' AND COALESCE(wt.notes,'') LIKE 'استحقاق%'
          ORDER BY wt.date DESC,wt.id DESC LIMIT 100""",[wid])
      ]);
      if(!mounted)return;final workers=x[0] as List<Map<String,Object?>>;if(workers.isEmpty)throw StateError('العامل غير موجود أو غير نشط.');
      setState(() { id=wid; worker=workers.first; summary=x[1] as Map<String,Object?>; ledger=(x[2] as List).cast<Map<String,Object?>>(); permissions=x[3] as Set<String>; irrigations=(x[4] as List).cast<Map<String,Object?>>(); loading=false; error=null; });
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
    final w=worker!,s=summary??{};final balance=n(s['balance']);
    final pay=switch('${w['pay_type']}'){'fixed'=>'راتب ثابت: ${money(w['fixed_salary'])} ريال','hourly'=>'أجر الساعة: ${money(w['hourly_rate'])} ريال','percentage'=>'النسبة: ${w['percentage_rate']}% من قيمة السقاية المحتسبة',_=>'الأجر غير محدد'};
    return ListView(padding:const EdgeInsets.all(16),children:[
      Card(color:Theme.of(context).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('مرحباً، ${w['name']}',style:const TextStyle(fontWeight:FontWeight.w700)),const SizedBox(height:8),
        const Text('ملخص حسابك',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),Text(pay),
        const SizedBox(height:12),Text(balance==0?'حسابك متوازن':balance>0?'مستحق لك ${money(balance)} ريال':'عليك ${money(balance.abs())} ريال',style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900))]))),
      Row(children:[metric('الاستحقاقات',money(s['earnings']),Icons.trending_up),metric('المدفوع لك',money(s['paid']),Icons.payments)]),
      Row(children:[metric('استحقاقات السقايات','${irrigations.length}',Icons.water_drop),metric('حركات الحساب','${ledger.length}',Icons.receipt_long)]),
      const Padding(padding:EdgeInsets.symmetric(vertical:12),child:Text('آخر الحركات',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900))),
      for(final row in ledger.take(5))tile(row)
    ]);
  }
  Widget account()=>ListView(padding:const EdgeInsets.all(16),children:[
    Row(children:[const Expanded(child:Text('كشف حسابي',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900))),
      if(permissions.contains('view_reports'))IconButton(icon:const Icon(Icons.picture_as_pdf),onPressed:()async{try{await ReportService(repo).printPdf('worker_transactions',workerId:id);}catch(e){if(mounted)message('تعذر إنشاء PDF: $e');}})]),
    for(final row in ledger)tile(row),if(ledger.isEmpty)const Text('لا توجد حركات مسجلة.')
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
      if(permissions.contains('view_account'))(title:'حسابي',icon:Icons.account_balance_wallet,page:account())
    ];
    if(tabs.isEmpty)return Scaffold(appBar:AppBar(title:const Text('بوابة العامل'),actions:[IconButton(onPressed:logout,icon:const Icon(Icons.logout))]),body:const Center(child:Text('لم يمنحك المدير صلاحية عرض الشاشات.')));
    final index=tab.clamp(0,tabs.length-1);
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:Text('بوابة العامل • ${worker!['name']}'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh)),
        PopupMenuButton<String>(onSelected:(v){if(v=='password')changePassword();if(v=='logout')logout();},itemBuilder:(_)=>const[
          PopupMenuItem(value:'password',child:Text('تغيير كلمة المرور')),PopupMenuItem(value:'logout',child:Text('تسجيل الخروج'))])]),
      body:tabs[index].page,bottomNavigationBar:NavigationBar(selectedIndex:index,onDestinationSelected:(v)=>setState(()=>tab=v),
        destinations:[for(final t in tabs)NavigationDestination(icon:Icon(t.icon),label:t.title)])
    ));
  }
}
