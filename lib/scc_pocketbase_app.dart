import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'services/pocketbase/scc_pocketbase_client.dart';

/// An explicit PocketBase-backed entry point for the VPS release.
//// It intentionally doesn't instantiate legacy Firebase/Firestore services.
/// Only enable with --dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com
class SccPocketBaseApp extends StatefulWidget {
  const SccPocketBaseApp({super.key, this.client});

  /// Inject an HTTP-mocked client in widget tests.
  final SccPocketBaseClient? client;

  @override
  State<SccPocketBaseApp> createState() => _SccPocketBaseAppState();
}

class _SccPocketBaseAppState extends State<SccPocketBaseApp> {
  late final SccPocketBaseClient _api;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _loginKey = GlobalKey<FormState>();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  SccUserSession? _user;
  List<SccProduct> _products = const [];
  List<SccMediaAsset> _media = const [];
  bool _restoring = true;
  bool _busy = false;
  bool _loading = false;
  int _tab = 0;
  int _page = 1;
  bool _hasMore = false;
  static const _pageSize = 30;

  @override
  void initState() {
    super.initState();
    _api = widget.client ??
        SccPocketBaseClient(baseUrl: SccPocketBaseClient.configuredUrl);
    _restore();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    if (widget.client == null) {
      _api.close();
    }
    super.dispose();
  }

  String _errorMessage(Object error) {
    if (error is SccApiException) {
      switch (error.statusCode) {
        case 400:
        case 422:
          return 'البيانات غير صحيحة. تحقق منها ثم أعد المحاولة.';
        case 401:
          return 'انتهت الجلسة أو لم يتم تسجيل الدخول.';
        case 403:
          return 'ليس لديك الإذن لهذه العملية.';
        case 404:
          return 'السجل غير موجود أو لا تملك صلاحية الوصول إليه.';
        case 429:
          return 'تم تجاوز عدد الطلبات. حاول لاحقًا.';
      }
    }
    return 'تعذر الاتصال بالخدمة. تحقق من الشبكة وحاول مجددًا.';
  }

  void _notice(String value) {
    if (!mounted) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _restore() async {
    try {
      final session = await _api.refreshSession();
      if (!mounted) return;
      setState(() => _user = session);
      await _reloadProducts();
    } on SccApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        await _api.signOut();
      }
    } catch (_) {
      // If the network is temporarily unavailable, do not erase the saved token.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _login() async {
    if (!_loginKey.currentState!.validate() || _busy) return;
    setState(() => _busy = true);
    try {
      final session = await _api.signIn(_email.text.trim(), _password.text);
      _password.clear();
      if (!mounted) return;
      setState(() {
        _user = session;
        _tab = 0;
      });
      await _reloadProducts();
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await _api.signOut();
    if (!mounted) return;
    setState(() {
      _user = null;
      _products = const [];
      _media = const [];
      _page = 1;
      _hasMore = false;
      _tab = 0;
    });
  }

  Future<void> _reloadProducts({bool more = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final requestedPage = more ? _page + 1 : 1;
      final products = await _api.listProducts(
        page: requestedPage,
        perPage: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _products = more ? [..._products, ...products] : products;
        _page = requestedPage;
        _hasMore = products.length == _pageSize;
      });
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadMedia() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final records = await _api.listPrivateMedia(perPage: 100);
      if (mounted) setState(() => _media = records);
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onTab(int index) {
    if (_busy) return;
    setState(() => _tab = index);
    if (index == 1) _reloadMedia();
  }

  Future<void> _editProduct([SccProduct? existing]) async {
    if (_busy) return;
    final change = await showDialog<_SccProductDraft>(
      context: _navigatorKey.currentContext!,
      builder: (context) => _SccProductForm(existing: existing),
    );
    if (change == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (existing == null) {
        await _api.createProduct(
          title: change.title,
          priceMinor: change.priceMinor,
          currency: change.currency,
        );
      } else {
        await _api.updateProduct(
          id: existing.id,
          title: change.title,
          priceMinor: change.priceMinor,
          currency: change.currency,
        );
      }
      await _reloadProducts();
      _notice(existing == null ? 'تم حفظ المنتج' : 'تم تحديث المنتج');
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteProduct(SccProduct product) async {
    if (_busy) return;
    final approved = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('حذف المنتج؟'),
        content: Text('سيتم حذف «' + product.title + '» نهائيًا.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.deleteProduct(product.id);
      await _reloadProducts();
      _notice('تم حذف المنتج');
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadMedia() async {
    if (_busy) return;
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'mp4'],
      withData: true,
      allowMultiple: false,
    );
    if (selected == null || selected.files.isEmpty || !mounted) return;
    final file = selected.files.single;
    if (file.size == 0 || file.size > 26214400 || file.bytes == null) {
      _notice('حجم الملف غير صالح، أو تعذر قراءته. الحد 25 ميجابايت.');
      return;
    }
    final extension = file.extension?.toLowerCase();
    const types = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
    };
    final mimeType = types[extension];
    if (mimeType == null) {
      _notice('نوع الملف غير مدعوم.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.uploadPrivateMedia(
        bytes: file.bytes!,
        filename: file.name,
        mimeType: mimeType,
      );
      await _reloadMedia();
      _notice('تم رفع الملف إلى مساحة التخزين الخاصة بحسابك');
    } catch (e) {
      _notice(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _loginView() {
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Content Creator')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _loginKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.cloud_done_outlined, size: 52),
                      const SizedBox(height: 16),
                      const Text(
                        'الدخول إلى حساب صانع المحتوى',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        key: const Key('scc-login-email'),
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'البريد الإلكتروني',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v?.contains('@') ?? false)
                            ? null
                            : 'أدخل بريدًا إلكترونيًا صحيحًا',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('scc-login-password'),
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'كلمة المرور',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v?.isNotEmpty ?? false)
                            ? null
                            : 'أدخل كلمة المرور',
                        onFieldSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        key: const Key('scc-login-submit'),
                        onPressed: _busy ? null : _login,
                        icon: const Icon(Icons.login),
                        label: Text(_busy ? 'جارٍ الدخول...' : 'تسجيل الدخول'),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'التسجيل العام مغلق مؤقتًا. استخدم حساب مستخدم مُعتمَد؛ '
                        'حساب مدير PocketBase ليس حساب دخول للتطبيق.',
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

  Widget _productsView() {
    if (_loading && _products.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_products.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined, size: 56),
            const SizedBox(height: 10),
            const Text('لا توجد منتجات في حسابك'),
            TextButton(onPressed: () => _reloadProducts(), child: const Text('تحديث')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reloadProducts,
      child: ListView.builder(
        key: const Key('scc-products-list'),
        itemCount: _products.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _products.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _reloadProducts(more: true),
                  child: const Text('تحميل المزيد'),
                ),
              ),
            );
          }
          final item = _products[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(item.priceMinor.toString() + ' · ' + item.currency
                  + ' · ' + (item.status == 'draft' ? 'مسودة' : item.status)),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    _editProduct(item);
                  } else if (value == 'delete') {
                    _deleteProduct(item);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('تعديل')),
                  PopupMenuItem(value: 'delete', child: Text('حذف')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mediaView() {
    if (_loading && _media.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_media.isEmpty) {
      return const Center(child: Text('لا توجد صور أو فيديوهات محفوظة'));
    }
    return RefreshIndicator(
      onRefresh: _reloadMedia,
      child: ListView.builder(
        itemCount: _media.length,
        itemBuilder: (context, index) {
          final asset = _media[index];
          return ListTile(
            leading: const Icon(Icons.perm_media_outlined),
            title: Text(asset.label.isEmpty ? asset.filename : asset.label),
            subtitle: const Text('ملف خاص — لا يمكن الوصول إليه دون تصريح'),
          );
        },
      ),
    );
  }

  Widget _profileView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(radius: 30, child: Icon(Icons.person_outline)),
            const SizedBox(height: 12),
            Text(_user?.email ?? ''),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const Key('scc-signout'),
              onPressed: _busy ? null : _signOut,
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _workspace() {
    const titles = ['منتجاتي', 'الوسائط الخاصة', 'الحساب'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loading ? null : (_tab == 1 ? _reloadMedia : _reloadProducts),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [_productsView(), _mediaView(), _profileView()],
      ),
      floatingActionButton: _tab == 2
          ? null
          : FloatingActionButton.extended(
              key: Key(_tab == 0 ? 'scc-add-product' : 'scc-upload-media'),
              onPressed: _busy
                  ? null
                  : (_tab == 0 ? () => _editProduct() : _uploadMedia),
              icon: Icon(_tab == 0 ? Icons.add : Icons.upload_file),
              label: Text(_tab == 0 ? 'إضافة منتج' : 'رفع ملف'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _onTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'المنتجات'),
          NavigationDestination(icon: Icon(Icons.perm_media_outlined), label: 'الوسائط'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'الحساب'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      title: 'Smart Content Creator',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD12A3A)),
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: _restoring
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : (_user == null ? _loginView() : _workspace()),
      ),
    );
  }
}

class _SccProductDraft {
  const _SccProductDraft(this.title, this.priceMinor, this.currency);
  final String title;
  final int priceMinor;
  final String currency;
}

class _SccProductForm extends StatefulWidget {
  const _SccProductForm({this.existing});
  final SccProduct? existing;

  @override
  State<_SccProductForm> createState() => _SccProductFormState();
}

class _SccProductFormState extends State<_SccProductForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _price;
  late String _currency;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title);
    _price = TextEditingController(text: widget.existing?.priceMinor.toString());
    _currency = widget.existing?.currency.isNotEmpty == true
        ? widget.existing!.currency
        : 'YER';
  }

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'منتج جديد' : 'تعديل المنتج'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('scc-product-title'),
                controller: _title,
                decoration: const InputDecoration(labelText: 'اسم المنتج'),
                validator: (v) => (v?.trim().isNotEmpty ?? false)
                    ? null : 'اسم المنتج مطلوب',
              ),
              TextFormField(
                key: const Key('scc-product-price'),
                controller: _price,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'السعر (عدد صحيح بوحدة العملة الصغرى)',
                ),
                validator: (v) {
                  final amount = int.tryParse(v ?? '');
                  return amount != null && amount >= 0
                      ? null : 'أدخل قيمة صحيحة غير سالبة';
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                decoration: const InputDecoration(labelText: 'العملة'),
                items: const [
                  DropdownMenuItem(value: 'YER', child: Text('ريال يمني')),
                  DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي')),
                  DropdownMenuItem(value: 'USD', child: Text('دولار أمريكي')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _currency = value);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('scc-save-product'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, _SccProductDraft(
              _title.text.trim(),
              int.parse(_price.text),
              _currency,
            ));
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
