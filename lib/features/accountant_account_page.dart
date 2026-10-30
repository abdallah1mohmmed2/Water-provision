import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_clock.dart';
import '../data/repositories/repositories.dart';
import '../services/report_service.dart';

class AccountantAccountPage extends StatefulWidget {
  final StationRepository repository;
  final int userId;
  final bool manager;
  const AccountantAccountPage({super.key,required this.repository,required this.userId,required this.manager});
  @override State<AccountantAccountPage> createState()=>_AccountantAccountPageState();
}
class _AccountantAccountPageState extends State<AccountantAccountPage>{
  List<Map<String,Object?>> workers=[],moves=[],cashboxes=[],methods=[],partners=[],reportRows=[];
  int? workerId; int tab=0; bool loading=true,saving=false;
  String reportKey='cash_flow'; DateTime? from,to;
  static const reports=<String,String>{'cash_flow':'التدفق النقدي','monthly_financial':'التقرير المالي الشهري','cashboxes':'الصناديق والتحويلات','worker_transactions':'معاملات العمال','journal':'دفتر اليومية','ledger':'دفتر الأستاذ العام','expenses':'المصروفات','payment_log':'سجل المدفوعات'};
  Map<String,Object?>? get worker {for(final w in workers){if((w['id'] as num).toInt()==workerId)return w;}return null;}
  int get balance=>(worker?['balance'] as num?)?.round()??0;
  String money(Object? n)=>NumberFormat('#,##0').format((n as num?)?.round()??0);
  String dateLabel(DateTime? d)=>d==null?'كل الفترات':DateFormat('yyyy/MM/dd').format(d);
  String get payType=>switch('${worker?['pay_type']}'){'fixed'=>'راتب ثابت شهري','hourly'=>'أجر بالساعة','percentage'=>'نسبة من السقايات',_=>'غير محدد'};
  @override void initState(){super.initState();load();}
  void msg(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
  Future<void> load() async{
    if(mounted)setState(()=>loading=true);
    try{
      final linked=await widget.repository.accountantWorkerForUser(widget.userId);
      final ws=await widget.repository.workers(includeInactive:true),cb=await widget.repository.cashboxes(),pm=await widget.repository.paymentMethods(),ps=await widget.repository.partners();
      final ids=ws.map((x)=>(x['id'] as num).toInt()).toSet();
      final selected=linked!=null&&ids.contains(linked)?linked:(workerId!=null&&ids.contains(workerId)?workerId:null);
      final tx=selected==null?<Map<String,Object?>>[]:await widget.repository.workerTransactions(selected);
      if(!mounted)return;setState(() { workers=ws; cashboxes=cb; methods=pm; partners=ps; workerId=selected; moves=tx; loading=false; });
      if(tab==2)await loadReport();
    }catch(e){if(mounted){setState(()=>loading=false);msg('تعذر تحميل الحساب: $e');}}
  }
  Future<void> assign() async{
    if(workerId==null)return;setState(()=>saving=true);
    try{await widget.repository.assignAccountantWorker(userId:widget.userId,workerId:workerId!);msg('تم ربط المستخدم بسجل العامل الموجود');await load();}
    catch(e){msg('تعذر الربط: $e');}finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> pickDate(bool start) async{
    final old=start?from:to;final d=await showDatePicker(context:context,initialDate:old??AppClock.now(),firstDate:DateTime(2000),lastDate:DateTime(2100));
    if(d==null||!mounted)return;setState(()=>start?from=DateTime(d.year,d.month,d.day):to=DateTime(d.year,d.month,d.day));if(tab==2)await loadReport();
  }
  bool inPeriod(Map<String,Object?> r){
    final d=DateTime.tryParse('${r['date']??r['created_at']}');if(d==null)return from==null&&to==null;
    if(from!=null&&d.isBefore(DateTime(from!.year,from!.month,from!.day)))return false;
    return to==null||d.isBefore(DateTime(to!.year,to!.month,to!.day+1));
  }
  Future<void> loadReport() async{
    if(reportKey=='worker_transactions'&&workerId==null){setState(()=>reportRows=[]);return;}
    try{final r=await widget.repository.report(reportKey,from:from,to:to,workerId:reportKey=='worker_transactions'?workerId:null);if(mounted)setState(()=>reportRows=r);}
    catch(e){msg('تعذر تحميل التقرير: $e');}
  }
  Future<void> pdf() async{
    if(reportKey=='worker_transactions'&&workerId==null){msg('اربط المحاسب بعامل أولًا');return;}
    try{await ReportService(widget.repository).printPdf(reportKey,from:from,to:to,workerId:reportKey=='worker_transactions'?workerId:null);}
    catch(e){msg('تعذر إنشاء PDF: $e');}
  }
  Future<void> movement() async{
    final w=worker;if(w==null)return;if((w['active'] as num?)?.toInt()!=1){msg('العامل غير نشط');return;}
    final amount=TextEditingController(text:worker?['pay_type']=='fixed'?'${worker?['fixed_salary']??0}':''),notes=TextEditingController();String kind=worker?['pay_type']=='fixed'?'salary':'accrual';
    int? cb=cashboxes.isEmpty?null:(cashboxes.first['id'] as num).toInt();
    final cash=methods.where((m)=>m['type']=='cash').toList(),available=cash.isNotEmpty?cash:methods;
    int? pm=available.isEmpty?null:(available.first['id'] as num).toInt();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
      title:Text('تسوية حساب ${w['name']}'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<String>(value:kind,items:const[DropdownMenuItem(value:'salary',child:Text('ترحيل راتب ثابت')),DropdownMenuItem(value:'accrual',child:Text('إضافة استحقاق آخر')),DropdownMenuItem(value:'payment',child:Text('صرف مستحق للمحاسب'))],onChanged:(v)=>refresh(()=>kind=v??'accrual'),decoration:const InputDecoration(labelText:'نوع الحركة')),
        TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ بالريال')),
        if(kind=='payment')...[
          DropdownButtonFormField<int>(value:cb,items:cashboxes.map((x)=>DropdownMenuItem<int>(value:(x['id'] as num).toInt(),child:Text('${x['name']}'))).toList(),onChanged:(v)=>refresh(()=>cb=v),decoration:const InputDecoration(labelText:'الصندوق')),
          DropdownButtonFormField<int>(value:pm,items:available.map((x)=>DropdownMenuItem<int>(value:(x['id'] as num).toInt(),child:Text('${x['name']}'))).toList(),onChanged:(v)=>refresh(()=>pm=v),decoration:const InputDecoration(labelText:'طريقة الدفع')),
        ],
        TextField(controller:notes,maxLines:2,decoration:const InputDecoration(labelText:'البيان / سبب التسوية')),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,(int.tryParse(amount.text.trim())??0)>0&&(kind!='payment'||(cb!=null&&pm!=null))),child:const Text('ترحيل'))],
    )));
    if(ok!=true||!mounted)return;setState(()=>saving=true);
    try{await widget.repository.workerTransaction(workerId:workerId!,type:kind,amount:int.parse(amount.text.trim()),cashboxId:kind=='payment'?cb:null,paymentMethodId:kind=='payment'?pm:null,notes:notes.text.trim().isEmpty?null:notes.text.trim(),userId:widget.userId);msg('تم ترحيل الحركة إلى حساب العامل والأستاذ العام');await load();}
    catch(e){msg('تعذر ترحيل الحركة: $e');}finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> depositDialog() async{
    if(workerId==null||cashboxes.isEmpty){msg('تأكد من ربط المحاسب ووجود صندوق نشط');return;}
    final amount=TextEditingController(),notes=TextEditingController();
    int? cb=(cashboxes.first['id'] as num).toInt();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
      title:const Text('إيداع من مال المحاسب'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<int>(value:cb,items:cashboxes.map((x)=>DropdownMenuItem<int>(value:(x['id'] as num).toInt(),child:Text('${x['name']}'))).toList(),onChanged:(v)=>refresh(()=>cb=v),decoration:const InputDecoration(labelText:'الصندوق الذي استلم النقدية')),
        TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ المودع')),
        TextField(controller:notes,decoration:const InputDecoration(labelText:'البيان')),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,(int.tryParse(amount.text.trim())??0)>0&&cb!=null),child:const Text('تسجيل الإيداع'))],
    )));
    if(ok!=true)return;
    try{await widget.repository.accounting.recordAccountantDeposit(workerId:workerId!,cashboxId:cb!,amount:int.parse(amount.text.trim()),userId:widget.userId,notes:notes.text.trim());msg('سُجل الإيداع: زاد الصندوق وزاد مستحق المحاسب، دون إيراد أو مصروف.');await load();}
    catch(e){msg('تعذر تسجيل الإيداع: $e');}
  }
  Future<void> partnerPayoutDialog() async{
    if(workerId==null||partners.isEmpty){msg('لا توجد شراكات نشطة للتسوية');return;}
    final amount=TextEditingController(),notes=TextEditingController();
    int? pid=(partners.first['id'] as num).toInt();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
      title:const Text('سداد مستحقات شريك من مال المحاسب'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        DropdownButtonFormField<int>(value:pid,items:partners.map((x)=>DropdownMenuItem<int>(value:(x['id'] as num).toInt(),child:Text('${x['name']}'))).toList(),onChanged:(v)=>refresh(()=>pid=v),decoration:const InputDecoration(labelText:'الشريك المستفيد من السداد')),
        TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'المبلغ المدفوع شخصيًا')),
        TextField(controller:notes,decoration:const InputDecoration(labelText:'البيان / رقم السند')),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,(int.tryParse(amount.text.trim())??0)>0&&pid!=null),child:const Text('تسجيل السداد'))],
    )));
    if(ok!=true)return;
    try{await widget.repository.accounting.recordAccountantPartnerPayout(workerId:workerId!,partnerId:pid!,amount:int.parse(amount.text.trim()),userId:widget.userId,notes:notes.text.trim());msg('سُجل السداد: انخفض مستحق الشريك وزاد مستحق المحاسب، دون حركة صندوق أو تغيير ديون المستفيدين.');await load();}
    catch(e){msg('تعذر تسجيل السداد: $e');}
  }
  Future<void> editPay() async{
    final w=worker;if(w==null||!widget.manager)return;
    final name=TextEditingController(text:'${w['name']??''}'),phone=TextEditingController(text:'${w['phone']??''}'),job=TextEditingController(text:'${w['job_title']??''}');
    final fixed=TextEditingController(text:'${w['fixed_salary']??0}'),hourly=TextEditingController(text:'${w['hourly_rate']??0}'),percent=TextEditingController(text:'${w['percentage_rate']??0}');
    String type='${w['pay_type']??'hourly'}';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
      title:const Text('تعديل استحقاق المحاسب'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:const InputDecoration(labelText:'اسم العامل / المحاسب')),
        TextField(controller:phone,decoration:const InputDecoration(labelText:'رقم الهاتف')),
        TextField(controller:job,decoration:const InputDecoration(labelText:'المسمى الوظيفي')),
        DropdownButtonFormField<String>(value:type,items:const[DropdownMenuItem(value:'fixed',child:Text('راتب ثابت')),DropdownMenuItem(value:'hourly',child:Text('بالساعة')),DropdownMenuItem(value:'percentage',child:Text('نسبة'))],onChanged:(v)=>refresh(()=>type=v??'hourly')),
        if(type=='fixed')TextField(controller:fixed,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الراتب الشهري')),
        if(type=='hourly')TextField(controller:hourly,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'أجر الساعة')),
        if(type=='percentage')TextField(controller:percent,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'النسبة %')),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,name.text.trim().isNotEmpty&&(type=='fixed'?(int.tryParse(fixed.text)??0)>0:type=='hourly'?(int.tryParse(hourly.text)??0)>0:(double.tryParse(percent.text)??-1)>=0&&(double.tryParse(percent.text)??101)<=100)),child:const Text('حفظ'))],
    )));
    if(ok!=true)return;
    try{await widget.repository.updateWorker(workerId!,{'name':name.text.trim(),'phone':phone.text.trim(),'job_title':job.text.trim(),'pay_type':type,'fixed_salary':int.tryParse(fixed.text)??0,'hourly_rate':int.tryParse(hourly.text)??0,'percentage_rate':double.tryParse(percent.text)??0},widget.userId);msg('تم تحديث الاستحقاق');await load();}
    catch(e){msg('تعذر تحديث الاستحقاق: $e');}
  }
  Widget metric(String title,String value,IconData icon)=>Expanded(child:Card(child:Padding(padding:const EdgeInsets.all(11),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(icon,size:19),const SizedBox(height:6),Text(title,style:Theme.of(context).textTheme.labelSmall),Text(value,style:const TextStyle(fontWeight:FontWeight.w900),maxLines:1,overflow:TextOverflow.ellipsis)]))));
  Widget linkPanel(){
    final active=workers.where((w)=>(w['active'] as num?)?.toInt()==1).toList();
    if(workerId!=null&&!active.any((w)=>(w['id'] as num).toInt()==workerId)){
      final inactive=worker;
      if(inactive!=null)active.add(inactive);
    }
    final canChange=widget.manager||workerId==null;
    return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('ربط المستخدم بسجل العامل',style:TextStyle(fontWeight:FontWeight.w900)),
      const Text('اختر عاملًا موجودًا ليكون هو المحاسب. لن يُنشأ عامل مكرر؛ وستبقى الرواتب والاستحقاقات والمدفوعات في دفتر العامل نفسه.',style:TextStyle(fontSize:12,height:1.5)),
      DropdownButtonFormField<int>(value:workerId,isExpanded:true,items:active.map((w)=>DropdownMenuItem<int>(value:(w['id'] as num).toInt(),child:Text('${w['name']}'))).toList(),onChanged:canChange?(v)=>setState(()=>workerId=v):null,decoration:const InputDecoration(labelText:'العامل المرتبط')),
      if(canChange)Align(alignment:AlignmentDirectional.centerEnd,child:FilledButton.icon(onPressed:saving||workerId==null?null:assign,icon:const Icon(Icons.link),label:const Text('حفظ الربط')))
      else const Text('تغيير العامل المرتبط متاح للمدير فقط.',style:TextStyle(fontSize:11)),
    ])));
  }
  Widget profile(){
    final w=worker;if(w==null)return const Card(child:Padding(padding:EdgeInsets.all(18),child:Text('اختر عاملًا واحفظ الربط لعرض حساب المحاسب.')));
    final active=(w['active'] as num?)?.toInt()==1;
    return Column(children:[
      Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.account_balance_wallet_outlined)),title:Text('${w['name']}',style:const TextStyle(fontWeight:FontWeight.w900)),subtitle:Text('${w['phone']??'لا يوجد هاتف'} • $payType • ${active?'نشط':'غير نشط'}'),trailing:widget.manager?IconButton(onPressed:editPay,icon:const Icon(Icons.edit_outlined),tooltip:'تعديل الاستحقاق'):null)),
      Row(children:[metric('الرصيد الحالي','${money(balance)} ريال',Icons.account_balance),metric('له على المحطة','${money(balance>0?balance:0)} ريال',Icons.south_west),metric('عليه للمحطة','${money(balance<0?-balance:0)} ريال',Icons.north_east)]),
      if('${w['pay_type']}'=='fixed')Card(child:ListTile(title:const Text('الراتب الشهري الثابت'),subtitle:Text('${money(w['fixed_salary'])} ريال • يستخدم ترحيل الرواتب الحالي ومنع التكرار')))
      else if('${w['pay_type']}'=='hourly')Card(child:ListTile(title:const Text('الأجر بالساعة'),subtitle:Text('${money(w['hourly_rate'])} ريال للساعة')))
      else Card(child:ListTile(title:const Text('نسبة الاستحقاق'),subtitle:Text('${w['percentage_rate']??0}% من السقايات المؤهلة'))),
    ]);
  }
  Widget period()=>Row(children:[
    Expanded(child:OutlinedButton(onPressed:()=>pickDate(true),child:Text('من: ${dateLabel(from)}'))),
    const SizedBox(width:6),
    Expanded(child:OutlinedButton(onPressed:()=>pickDate(false),child:Text('إلى: ${dateLabel(to)}'))),
    IconButton(onPressed:()=>setState(() { from=null; to=null; }),icon:const Icon(Icons.filter_alt_off)),
  ]);
  Widget accountTab(){
    final rows=moves.where(inPeriod).toList();
    return Column(children:[
      period(),
      Row(children:[Expanded(child:FilledButton.icon(onPressed:saving?null:movement,icon:const Icon(Icons.add_card),label:const Text('تسوية مالية'))),const SizedBox(width:8),Expanded(child:OutlinedButton.icon(onPressed:pdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('كشف PDF')))]),
      if(rows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(20),child:Text('لا توجد حركات في الفترة المحددة')))
      else ...rows.map((r){final lah=(r['lah'] as num?)?.round()??0,alayh=(r['alayh'] as num?)?.round()??0,d=DateTime.tryParse('${r['date']??''}');
        return Card(child:ListTile(leading:CircleAvatar(child:Icon(lah>0?Icons.add:alayh>0?Icons.remove:Icons.receipt_long)),title:Text('${r['description']??r['notes']??'حركة حساب'}',maxLines:2,overflow:TextOverflow.ellipsis),subtitle:Text(d==null?'تاريخ غير محدد':DateFormat('yyyy/MM/dd').format(d)),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[Text(lah>0?'له ${money(lah)}':alayh>0?'عليه ${money(alayh)}':'—',style:const TextStyle(fontWeight:FontWeight.w900)),Text('الرصيد ${money(r['balance'])}',style:Theme.of(context).textTheme.labelSmall)])));
      }),
    ]);
  }
  Widget reportsTab(){
    final keys=reportRows.isEmpty?<String>[]:reportRows.first.keys.take(5).toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      DropdownButtonFormField<String>(value:reportKey,items:reports.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text(e.value))).toList(),onChanged:(v){if(v!=null){setState(()=>reportKey=v);loadReport();}},decoration:const InputDecoration(labelText:'نوع التقرير')),
      const SizedBox(height:8),period(),
      Row(children:[Expanded(child:FilledButton.icon(onPressed:loadReport,icon:const Icon(Icons.search),label:const Text('عرض التقرير'))),const SizedBox(width:8),Expanded(child:OutlinedButton.icon(onPressed:pdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('تصدير PDF')))]),
      Text('عدد السجلات: ${reportRows.length}',style:const TextStyle(fontWeight:FontWeight.w800)),
      if(reportRows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(18),child:Text('لا توجد بيانات مطابقة')))
      else Card(clipBehavior:Clip.antiAlias,child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(columns:keys.map((k)=>DataColumn(label:Text(k))).toList(),rows:reportRows.take(100).map((r)=>DataRow(cells:keys.map((k)=>DataCell(ConstrainedBox(constraints:const BoxConstraints(maxWidth:145),child:Text('${r[k]??''}',overflow:TextOverflow.ellipsis)))).toList())).toList()))),
      if(reportRows.length>100)const Text('يعرض الجدول أول 100 سجل؛ PDF يتبع التقرير والفلاتر المحددة.'),
    ]);
  }
  @override Widget build(BuildContext context)=>Directionality(textDirection:TextDirection.rtl,child:loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
    Card(color:Theme.of(context).colorScheme.primaryContainer,child:const Padding(padding:EdgeInsets.all(15),child:Row(children:[Icon(Icons.manage_accounts,size:32),SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('حساب المحاسب والتسويات المالية',style:TextStyle(fontWeight:FontWeight.w900,fontSize:17)),Text('المحاسب هو مستخدم التطبيق والعامل نفسه؛ جميع الحركات تمر عبر دفتر العامل والأستاذ العام الحالي.',style:TextStyle(fontSize:12,height:1.45))]))]))),
    linkPanel(),
    if(worker!=null)...[profile(),const SizedBox(height:8),Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('مهام المحاسب داخل التطبيق',style:TextStyle(fontWeight:FontWeight.w900)),const Text('• تسجيل إيداعات النقدية التي يوردها للصندوق.\n• توثيق ما يدفعه للشركاء من ماله الشخصي.\n• متابعة راتبه واستحقاقاته وتسوية ما يُصرف له.\n• متابعة أرصدة الصناديق والعمال والشركاء والتقارير.\n• إصدار كشوف PDF موحدة بالفترة المحددة.',style:TextStyle(height:1.55,fontSize:12))]))),const SizedBox(height:8),SegmentedButton<int>(segments:const[ButtonSegment(value:0,label:Text('الحساب'),icon:Icon(Icons.receipt_long)),ButtonSegment(value:1,label:Text('التسويات'),icon:Icon(Icons.swap_horiz)),ButtonSegment(value:2,label:Text('تقارير عامة'),icon:Icon(Icons.analytics_outlined))],selected:{tab},onSelectionChanged:(v){setState(()=>tab=v.first);if(tab==2)loadReport();}),const SizedBox(height:10),
      if(tab==0)accountTab(),
      if(tab==1)Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const Text('تسويات المحاسب',style:TextStyle(fontWeight:FontWeight.w900,fontSize:16)),
        const Text('هذه العمليات منفصلة عن الراتب. الإيداع يزيد الصندوق ومستحق المحاسب، والسداد الشخصي للشريك يخفض مستحق الشريك ويزيد مستحق المحاسب دون حركة صندوق. أما صرف مستحق المحاسب فيخصم من صندوق المحطة.',style:TextStyle(height:1.5)),
        const SizedBox(height:12),
        FilledButton.icon(onPressed:saving?null:depositDialog,icon:const Icon(Icons.savings_outlined),label:const Text('تسجيل إيداع المحاسب في الصندوق')),
        FilledButton.icon(onPressed:saving?null:partnerPayoutDialog,icon:const Icon(Icons.handshake_outlined),label:const Text('تسجيل سداد شريك من مال المحاسب')),
        OutlinedButton.icon(onPressed:saving?null:movement,icon:const Icon(Icons.payments_outlined),label:const Text('استحقاق راتب أو صرف مستحق المحاسب')),
        OutlinedButton.icon(onPressed:pdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('طباعة كشف حساب المحاسب')),
      ]))),
      if(tab==2)reportsTab(),
    ],
  ])));
}
