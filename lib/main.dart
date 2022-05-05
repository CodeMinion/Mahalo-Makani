import 'dart:async';
import 'dart:ui';

import 'package:air_brother/air_brother.dart';
import 'package:another_quickbooks/another_quickbooks.dart';
import 'package:another_quickbooks/quickbook_models.dart' as qbModels;
import 'package:another_quickbooks/services/accounting/item_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:lottie/lottie.dart';
import 'package:mahalo_makani/app_keys.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:math' as math;

import 'event_notifier.dart';

void main() {
  runApp(const MyApp());
}

const double kLabelWidth = 90.3;
const double kLabelHeight = 40;
const double kDefaultRatePerHour = 60.0;
TextStyle kLabelTextStyle = GoogleFonts.vibur();
LottieComposition? kDefaultComposition;

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mahalo Makani',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Mahalo Makani'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with QuickBooksHelper, MahaloLogo, BrotherScanner, UsLicenseNumber {
  int _selectedIndex = 0;
  final int _recordsPerPage = 30;
  final PagingController<int, qbModels.Item> _pagingController =
      PagingController(firstPageKey: 0);
  final _formKey = GlobalKey<FormState>();
  final Completer<WebViewController> _controller =
  Completer<WebViewController>();

  final _selectedServices = List<qbModels.Item>.empty(growable: true);
  final ProgressModel _progressModel = ProgressModel(
      status: ProgressStatus.none, message: "Searching for customer...");
  String? realmId;

  qbModels.Customer? _activeCustomer;
  qbModels.Item? _activeService;


  bool _appIsReady = false;

  // Configured in Quickbooks Dashboard.
  final String redirectUrl =
      "https://developer.intuit.com/v2/OAuth2Playground/RedirectUrl";

  QuickbooksClient? quickClient;
  String? authUrl = "";
  qbModels.TokenResponse? token;

  @override
  void initState() {
    print("Init Called");
    initializeQuickbooks().then((value) {
      // TODO move this until after we have authorized
      _pagingController.addPageRequestListener((pageKey) {
        print("Requesting page");
        _fetchPage(pageKey);
      });

      //TODO Toggle when we are authenticated.  For now set it here.

      /*
      setState(() {
        _appIsReady = true;
      });*/

    });

    // Load the lottie ahead of time so by the time we need it there is no delay.
    rootBundle.load('assets/lottie/servishero_loading.json').then(
        (lottieData) => LottieComposition.fromByteData(lottieData)
            .then((composition) => kDefaultComposition = composition));
  }

  Future<void> _fetchPage(int pageKey) async {
    try {
      final newItems = await _getServiceItems(
          client: quickClient!, page: pageKey, pageSize: _recordsPerPage);
      final isLastPage = newItems.length < _recordsPerPage;
      if (isLastPage) {
        _pagingController.appendLastPage(newItems);
      } else {
        final nextPageKey = pageKey + newItems.length;
        _pagingController.appendPage(newItems, nextPageKey);
      }
    } catch (error) {
      print("Error: $error");
      _pagingController.error = error;
    }
  }

  ///
  /// Initialize Quickbooks Client
  ///
  Future<void> initializeQuickbooks() async {
    quickClient = QuickbooksClient(
        applicationId: AppKeys.quickBooksApplicationId,
        clientId: AppKeys.quickBooksClientId,
        clientSecret: AppKeys.quickBooksClientSecret,
        environmentType: EnvironmentType.Sandbox);

    await quickClient!.initialize();
    setState(() {
      authUrl = quickClient!.getAuthorizationPageUrl(
          scopes: [qbModels.Scope.Payments, qbModels.Scope.Accounting],
          redirectUrl: redirectUrl,
          state: "state123");
    });
  }

  Future<void> requestAccessToken(String code, String realmId) async {
    this.realmId = realmId;
    token = await quickClient!.getAuthToken(code: code,
        redirectUrl: redirectUrl,
        realmId: realmId);

    setState(() {
      _appIsReady = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: MahaloAppBar(
        title: widget.title,
      ),
      body: !_appIsReady ? _buildWebView(context) : _buildLargeServiceListView(context),
      // TODO Only show if authenticated
      floatingActionButton: !_appIsReady ? null : ExpandableFab(
        mainFabBody: const Icon(Icons.volunteer_activism),
        distance: 112.0,
        children: [
          Tooltip(
            message: "Charge",
            child: ActionButton(
              onPressed: () {
                // Call charge customer
                chargeClient();
              },
              icon: const Icon(Icons.volunteer_activism),
            ),
          ),

          if (_selectedServices.isNotEmpty)...[
            Tooltip(
              message: "Edit Service",
              child: ActionButton(
                onPressed: () {
                  // Call add item dialog.
                  if(_selectedServices.isEmpty) {
                    return;
                  }
                  _updateSelectedService(service: _selectedServices.single);
                },
                icon: const Icon(Icons.edit),
              ),
            )
          ]
          else ...[
            Tooltip(
              message: "Add Service",
              child: ActionButton(
                onPressed: () {
                  // Call add item dialog.
                  _addNewService();
                },
                icon: const Icon(Icons.add_business),
              ),
            )
          ]

        ],
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }

  Widget _buildWebView(BuildContext context) {
    return WebView(
      key: ObjectKey(authUrl),
      initialUrl: authUrl,
      javascriptMode: JavascriptMode.unrestricted,
      onWebViewCreated: (WebViewController webViewController) {
        _controller.complete(webViewController);
      },
      onProgress: (int progress) {
        print('WebView is loading (progress : $progress%)');
      },
      javascriptChannels: <JavascriptChannel>{},
      navigationDelegate: (NavigationRequest request) {
        if (request.url.startsWith(redirectUrl)) {
          print('blocking navigation to $request}');
          var url = Uri.parse(request.url);
          String code = url.queryParameters["code"]!;
          String realmId = url.queryParameters['realmId']!;
          // Request access token
          requestAccessToken(code, realmId);

          return NavigationDecision.prevent;
        }
        print('allowing navigation to $request');
        return NavigationDecision.navigate;
      },
      onPageStarted: (String url) {
        print('Page started loading: $url');
      },
      onPageFinished: (String url) {
        print('Page finished loading: $url');
      },
      gestureNavigationEnabled: true,
      backgroundColor: const Color(0x00000000),
    );
  }

  Widget _buildPage({required BuildContext context, required int page}) {
    return _buildLargeServiceListView(context);
  }

  Widget _buildLargeServiceListView(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          child: PagedGridView(
              padding: const EdgeInsets.only(left: 16, right: 16),
              pagingController: _pagingController,
              builderDelegate: PagedChildBuilderDelegate<qbModels.Item>(
                itemBuilder: (context, item, index) => _generateServiceCard(
                    index: index, service: item, context: context),
              ),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  mainAxisExtent: 300 * kLabelHeight / kLabelWidth,
                  maxCrossAxisExtent: 300,
                  childAspectRatio: kLabelWidth / kLabelHeight)),
        ),
        Positioned(
          child: ChangeNotifierProvider.value(
              value: _progressModel,
              child: Consumer<ProgressModel>(
                builder:
                    (BuildContext context, ProgressModel data, Widget? child) {
                  return ProgressOverlay();
                },
              )),
        )
      ],
    );
  }

  Widget _generateServiceCard(
      {required BuildContext context,
      required int index,
      required qbModels.Item service}) {
    // TODO Crate Check-In Card
    return ServiceCardView(
      service: service,
      isSelected: _selectedServices.contains(service),
      onLongPress: () {
        // Open update dialog
        _updateSelectedService(service: service);
      },
      onDeleteTap: () {
        // Consider opening a dialog.
        _deleteService(service: service);
      },
      onTap: () {
        setState(() {
          if (_selectedServices.contains(service)) {
            _selectedServices.remove(service);
          }
          else {
            // Add to selected list.
            _selectedServices.add(service);
          }
        });
      },
    );
  }

  void _showSnackBar({required String message}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Text(message),
      ),
    ));
  }

  Future<void> chargeClient() async {

    // Look for scanners.
    _progressModel.setData(
        status: ProgressStatus.loading,
        message: "Looking for network scanners...");
    // Find Scanners in the network.
    List<Connector> foundScanners = await _fetchWifiScanners();
    // If no scanner found return and show toast.
    if (foundScanners.isEmpty) {
      _progressModel.setData(status: ProgressStatus.none);
      _showSnackBar(message: "No scanners found. Try again");
      return;
    }

    // TODO Scan Driver's license
    _progressModel.setData(
        status: ProgressStatus.loading, message: "Scanning Driver License...");

    // Scan image.
    List<String> scannedPaths = await _scanFiles(foundScanners.single);

    if (scannedPaths.isEmpty) {
      _progressModel.setData(status: ProgressStatus.none);
      _showSnackBar(message: "Place Driver License in Scanner. Try again");
      return;
    }
    final scannedFilePath = scannedPaths.single;

    _progressModel.setData(
        status: ProgressStatus.loading,
        message: "Reading customer information...");

    // Extract License number, first name, last name.
    // Send it through the text recognizer.
    final inputImage = InputImage.fromFilePath(scannedFilePath);

    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final RecognizedText recognizedText =
    await textRecognizer.processImage(inputImage);
    String text = recognizedText.text;
    print("Recognized Tex: $text");
    for (TextBlock block in recognizedText.blocks) {
      final String text = block.text;
      print("Block Text: $text");
    }
    textRecognizer.close();

    if (recognizedText.blocks.length < 3 || getNumber(line: text) == null) {
      _progressModel.setData(status: ProgressStatus.none);
      _showSnackBar(message: "Unable to process Driver License. Try again");
      return;
    }

    // Extract license number
    String driverLicense = getNumber(line: text)!;
    String firstName = recognizedText.blocks[2].text;
    // Extract last name
    String lastName = recognizedText.blocks[3].text;

    _progressModel.setData(
        status: ProgressStatus.loading,
        message: "Looking up customer...");

    // Get QuickBooks customer using license number.
    qbModels.Customer? customer = await _getCustomerByDriverLicense(driverLicenseNumber: driverLicense, client: quickClient!);
    print("Found Customer: $customer");
    print ("Sync Token ${customer?.syncToken}");
    // If customer does not exist, create it on QuickBooks.
    customer ??= await _createCustomer(driverLicenseNumber: driverLicense, firstName: firstName, lastName: lastName, client: quickClient!);
    // Prompt user with invoice receipt and request email address if not present in customer.
    _activeCustomer = customer;

    String? email = await _showCustomerInvoiceDialog();
    if (email == null) {
      _progressModel.setData(status: ProgressStatus.none);
      return;
    }

    _progressModel.setData(
        status: ProgressStatus.loading,
        message: "Creating invoice...");

    // Create invoice with a line item for each selected item in service list
    qbModels.Invoice invoice = await _createInvoiceForItems(customer: customer, items: _selectedServices, client: quickClient!);
    // On return if customer email is different from provided on update customer.
    if (email != customer.primaryEmailAddr?.address) {
      try {
        print ("Sync Token ${customer.syncToken}");
        await _updateCustomer(customer: customer.copyWith(
            primaryEmailAddr: qbModels.EmailAddress(address: email)),
            client: quickClient!);
      }
      catch (e) {
        _progressModel.setData(status: ProgressStatus.none);
        _showSnackBar(message: "Unable to update customer. Try again");
        throw e;

      }
    }
    // Send invoice to customer by email.
    try {
      await _emailInvoice(
          invoiceId: invoice.id!, emailTo: email, client: quickClient!);
    }
    catch (e) {
      _showSnackBar(message: "Unable email invoice.");
    }
    finally {
      _progressModel.setData(status: ProgressStatus.none);
      setState(() {
        _selectedServices.clear();
      });
    }
    // DONE
  }

  Future _addNewService() async {
    _activeService = qbModels.Item(unitPrice: 10.0);
    qbModels.Item? service = await _showBaseServiceDialog();
    if (service == null) {
      return;
    }

    // Call insert item
    try {
      qbModels.Item insertedService = await _createServiceItem(serviceName: service.name!, serviceDescription: service.description!, client: quickClient! , serviceCost: service.unitPrice!);
      setState(() {
        _pagingController.itemList?.add(insertedService);
      });
    }
    on ItemException catch(e) {
      _showSnackBar(message: e.message ?? "Error creating item");
    }
  }

  Future _updateSelectedService({required qbModels.Item service}) async {
    _activeService = _selectedServices.single;
    qbModels.Item? updatedService = await _showBaseServiceDialog(isUpdate: true);
    if (updatedService == null) {
      return;
    }
    try {
      print ("Before Update: $service");
      print ("Updating: $updatedService");
      updatedService = await quickClient!.getAccountingClient().updateItem(item: updatedService);
      int index = _pagingController.itemList!.indexWhere((element) => element.id == updatedService!.id);
      int selectedIndex = _selectedServices.indexWhere((element) => element.id == updatedService!.id);
      setState(() {
        _selectedServices[selectedIndex] = updatedService!;
        _pagingController.itemList![index] = updatedService;
      });
    }
    on ItemException catch(e) {
      print(e);
      _showSnackBar(message: e.message ?? "Error updating service.");
    }
  }

  ///
  /// Deletes the specified service from QuickBooks.
  ///
  Future<void> _deleteService({required qbModels.Item service}) async {
    bool? delete = await _showBaseConfirmationDialogDialog(
      body: RichText(
        text: TextSpan(
          text: 'Delete service  ',
          style: Theme.of(context).textTheme.bodyText2,
          children: <TextSpan>[
            TextSpan(
                text: "${service.name} ",
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(text: "?"),
          ],
        ),
      ),
      positive: "Delete",
    );

    if (delete != true) {
      return;
    }

    try {
      qbModels.Item updatedService = await quickClient!.getAccountingClient().updateItem(item: service.copyWith(active: false));
      int index = _pagingController.itemList!.indexWhere((element) => element.id == updatedService.id);
      int selectedIndex = _selectedServices.indexWhere((element) => element.id == updatedService.id);

      print ("Deleted index: $index");
      setState(() {
        _selectedServices.removeAt(selectedIndex);
        _pagingController.itemList?.removeAt(index);
      });
    }
    on ItemException catch(e) {
      _showSnackBar(message: e.message ?? "Error updating service.");
    }
  }

  Future<qbModels.Item?> _showBaseServiceDialog({bool isUpdate = false}) {
    return showGeneralDialog<qbModels.Item?>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Barrier",
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (context, anim1, anim2) {
        return Container();
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final curvedValue = Curves.easeInOutBack.transform(anim1.value) - 1.0;
        return Transform(
            transform: Matrix4.translationValues(0.0, curvedValue * 200, 0.0),
            child: Opacity(
              opacity: anim1.value,
              child: _buildBaseDialogBody(
                  child: _createItemForm(
                      context: context,
                      setState: setState,
                      isUpdate: isUpdate)),
            ));
      },
    );
  }

  Widget _createCustomerEmailForm(
      {required BuildContext context, required StateSetter setState}) {
    return Form(
        key: _formKey,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            RichText(
              text: TextSpan(
                text: 'Name: ',
                style: kLabelTextStyle.copyWith(
                    fontWeight: FontWeight.bold, fontSize: 20),
                children: <TextSpan>[
                  TextSpan(
                      text: '${_activeCustomer?.displayName}',
                      style: kLabelTextStyle.copyWith(
                          fontWeight: FontWeight.normal))
                ],
              ),
            ),
            const SizedBox(
              height: 8,
            ),
            TextFormField(
              initialValue: "${_activeCustomer?.primaryEmailAddr?.address}",
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: "Customer Email:"),
              // The validator receives the text that the user has entered.
              validator: (value) {
                if (!isEmail(value)) {
                  return "Enter a valid email";
                }

                _activeCustomer = _activeCustomer?.copyWith(
                    primaryEmailAddr: qbModels.EmailAddress(address: value));
                return null;
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48), // NEW
                ),
                onPressed: () {
                  // Validate returns true if the form is valid, or false otherwise.
                  if (_formKey.currentState!.validate()) {
                    Navigator.pop(context, _activeCustomer!.primaryEmailAddr!.address);
                  }
                },
                child: const Text("Send Invoice"),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ));
  }

  bool isEmpty(String? s) => s == null || s.trim().isEmpty;

  bool isEmail(String? value) {
    if (isEmpty(value)) return false;
    return RegExp(
            r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9]+\.[a-zA-Z]+")
        .hasMatch(value!);
  }

  Widget _createItemForm(
      {required BuildContext context,
        bool isUpdate = false,
        required StateSetter setState}) {
    ThemeData mainTheme = Theme.of(context);
    return Form(
        key: _formKey,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              initialValue: _activeService?.name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: "Service Name"),
              // The validator receives the text that the user has entered.
              validator: (value) {
                if (!isValidEntry(value)) {
                  return 'Please enter a valid name';
                }
                _activeService = _activeService?.copyWith(name: value);
                return null;
              },
            ),
            const SizedBox(
              height: 8,
            ),
            TextFormField(
              initialValue: _activeService?.description,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: "Description"),
              // The validator receives the text that the user has entered.
              validator: (value) {
                if (!isValidEntry(value)) {
                  return 'Please enter a valid last name';
                }
                _activeService = _activeService?.copyWith(description: value);
                return null;
              },
            ),
            const SizedBox(
              height: 8,
            ),
            TextFormField(
              initialValue: "${_activeService?.unitPrice}",
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Rate"),
              // The validator receives the text that the user has entered.
              validator: (value) {
                double rate =
                parseRate(rateStr: value?.replaceAll("\$", " "));
                if (rate < 0) {
                  return 'Please enter a valid rate';
                }

                _activeService = _activeService?.copyWith(unitPrice: rate);
                return null;
              },
            ),
            const SizedBox(
              height: 8,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48), // NEW
                ),
                onPressed: () {
                  // Validate returns true if the form is valid, or false otherwise.
                  if (_formKey.currentState!.validate()) {
                    Navigator.pop(context, _activeService);
                  }
                },
                child: isUpdate
                    ? const Text('Update Service')
                    : const Text('Add Service'),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ));
  }

  Future<String?> _showCustomerInvoiceDialog() {
    return showGeneralDialog<String?>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Barrier",
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (context, anim1, anim2) {
        return Container();
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final curvedValue = Curves.easeInOutBack.transform(anim1.value) - 1.0;
        return Transform(
            transform: Matrix4.translationValues(0.0, curvedValue * 200, 0.0),
            child: Opacity(
              opacity: anim1.value,
              child: _buildBaseDialogBody(
                  child: LayoutBuilder(builder: (context, constraints) {
                bool hasMore = _selectedServices.length.toDouble() > 3;
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        height:
                            math.min(_selectedServices.length.toDouble(), 3) *
                                    constraints.maxWidth *
                                    kLabelHeight /
                                    kLabelWidth +
                                (hasMore ? 8 : 0),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        child: ListView.separated(
                            padding: const EdgeInsets.all(0),
                            separatorBuilder: (context, index) {
                              return const Divider(
                                height: 1,
                              );
                            },
                            itemCount: _selectedServices.length,
                            itemBuilder: (context, index) {
                              qbModels.Item service = _selectedServices[index];
                              return  AspectRatio(
                                aspectRatio: kLabelWidth / kLabelHeight,
                                child: Card(
                                  clipBehavior: Clip.antiAliasWithSaveLayer,
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            service.name ?? "No Name",
                                            style: kLabelTextStyle.copyWith(fontSize: 18),
                                            textAlign: TextAlign.center,
                                          ),

                                        ),
                                        Expanded(
                                          child: Text(
                                            service.description ?? "No Name",
                                            style: kLabelTextStyle.copyWith(fontSize: 14),
                                            textAlign: TextAlign.center,
                                          ),

                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );//ServiceCardView(service: _selectedServices[index]);
                            }),
                      ),
                    ),
                    RichText(
                      text: TextSpan(
                        text: 'Total: ',
                        style: kLabelTextStyle.copyWith(
                            fontWeight: FontWeight.bold, fontSize: 20),
                        children: <TextSpan>[
                          TextSpan(
                              text: '${_selectedServices.isEmpty ? 0.0 : _selectedServices.reduce((value, element) => element.copyWith(unitPrice: value.unitPrice! + element.unitPrice!)).unitPrice}',
                              style: kLabelTextStyle.copyWith(
                                  fontWeight: FontWeight.normal))
                        ],
                      ),
                    ),
                    _createCustomerEmailForm(
                        context: context, setState: setState)
                  ],
                );
              })),
            ));
      },
    );
  }

  Widget _buildBaseDialogBody({required Widget child}) {
    return Dialog(
        backgroundColor: Colors.transparent,
        child: StatefulBuilder(builder: (context, StateSetter setState) {
          ThemeData theme = Theme.of(context);
          return Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 50.0),
                child: Container(
                  decoration: BoxDecoration(
                      color: theme.colorScheme.background,
                      borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 16.0, right: 16.0, bottom: 16.0, top: 60),
                    child: SizedBox(
                        width: 400, child: SingleChildScrollView(child: child)),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                child: Center(
                  child: buildAppLogo(width: 100, height: 100),
                ),
              ),
            ],
          );
        }));
  }

  Future<bool?> _showBaseConfirmationDialogDialog(
      {required Widget body, required String positive}) {
    return showGeneralDialog<bool?>(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Barrier",
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (context, anim1, anim2) {
        return Container();
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final curvedValue = Curves.easeInOutBack.transform(anim1.value) - 1.0;
        return Transform(
          transform: Matrix4.translationValues(0.0, curvedValue * 200, 0.0),
          child: Opacity(
            opacity: anim1.value,
            child: _buildBaseDialogBody(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  body,
                  const SizedBox(
                    height: 16,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48), // NEW
                          ),
                          onPressed: () {
                            // Validate returns true if the form is valid, or false otherwise.
                            Navigator.pop(context, true);
                          },
                          child: Text(positive),
                        ),
                      )
                    ],
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  double parseRate({String? rateStr}) {
    print("Parsing $rateStr");
    if (rateStr == null) {
      return -1.0;
    }

    try {
      return double.parse(rateStr);
    } catch (e) {
      return -1.0;
    }
  }

  bool isValidEntry(String? value) {
    return value?.isNotEmpty == true;
  }
}

class ProgressOverlay extends StatelessWidget {
  const ProgressOverlay({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    ProgressModel progressModel = context.read();

    if (progressModel.status == ProgressStatus.loading) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Center(
                child: SizedBox(
                    width: 200,
                    child: kDefaultComposition == null
                        ? Lottie.asset(
                            'assets/lottie/van_morphing_animation.json')
                        : Lottie(composition: kDefaultComposition!))),
            if (progressModel.message != null) ...[
              AnimatedSwitcher(
                key: ValueKey<String>(progressModel.message!),
                duration: const Duration(microseconds: 600),
                child: Text(
                  progressModel.message!,
                  style: kLabelTextStyle.copyWith(fontSize: 20),
                ),
              ),
            ]
          ],
        ),
      );
    }

    return Container();
  }
}

class ServiceCardView extends StatelessWidget {
  final qbModels.Item service;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDeleteTap;
  final bool isSelected;

  const ServiceCardView(
      {Key? key,
      required this.service,
      this.isSelected = false,
      this.onTap,
      this.onLongPress,
      this.onDeleteTap})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: onLongPress,
      onTap: onTap,
      child: TweenAnimationBuilder<Color?>(
        duration: const Duration(milliseconds: 1000),
        tween: ColorTween(
            begin: Colors.white,
            end: isSelected ? Colors.lightBlueAccent : Colors.white),
        builder: (context, color, child) {
          return ColorFiltered(
            child: child,
            colorFilter: ColorFilter.mode(color?? Colors.white, BlendMode.modulate),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Card(
              clipBehavior: Clip.antiAliasWithSaveLayer,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: Text(
                        service.name ?? "No Name",
                        style: kLabelTextStyle.copyWith(fontSize: 18),
                        textAlign: TextAlign.center,
                      ),

                    ),
                    Expanded(
                      child: Text(
                        service.description ?? "No Name",
                        style: kLabelTextStyle.copyWith(fontSize: 14),
                        textAlign: TextAlign.center,
                      ),

                    ),
                  ],
                ),
              ),
            ),
            if (isSelected) ...[
              Positioned(
                  right: 0,
                  child: GestureDetector(
                    onTap: onDeleteTap,
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Icon(
                        Icons.close,
                        color: Colors.black,
                      ),
                    ),
                  ))
            ]
          ],
        ),
      ),
    );
  }
}

mixin QuickBooksHelper {
  ///
  /// Helper for creating a QuickBooks customer.
  ///
  Future<qbModels.Customer> _createCustomer(
      {required String driverLicenseNumber,
      required String firstName,
      required String lastName,
      required QuickbooksClient client}) async {
    qbModels.Customer customerToCreate = qbModels.Customer(
      givenName: firstName,
      familyName: lastName,
      companyName: driverLicenseNumber, // TODO Find a better way to link client license
    );
    qbModels.Customer createdCustomer = await client
        .getAccountingClient()
        .createCustomer(customer: customerToCreate);
    return createdCustomer;
  }

  ///
  /// Helper to find a QuickBooks customer from a driver's license number
  ///
  Future<qbModels.Customer?> _getCustomerByDriverLicense(
      {required String driverLicenseNumber,
      required QuickbooksClient client}) async {
    List<qbModels.Customer> foundCustomers;
    try {
      var queryBuffer = StringBuffer();
      queryBuffer.write("SELECT * FROM Customer ");
      queryBuffer.write("WHERE CompanyName = '$driverLicenseNumber' ");

      String query = queryBuffer.toString();
      foundCustomers =
          await client.getAccountingClient().queryCustomer(query: query);
    } catch (e) {
      foundCustomers = List<qbModels.Customer>.empty();
    }

    if (foundCustomers.isEmpty) {
      return null;
    }
    return foundCustomers.single;
  }

  ///
  /// Updates the customer on QuickBooks.
  ///
  Future<qbModels.Customer> _updateCustomer(
      {required qbModels.Customer customer,
      required QuickbooksClient client}) async {
    print ("Sync Token ${customer.syncToken}");
    return await client
        .getAccountingClient()
        .updateCustomer(customer: customer);
  }

  ///
  /// Helper for creating an item.
  ///
  Future<qbModels.Item> _createServiceItem(
      {required String serviceName,
        required String serviceDescription,
      required QuickbooksClient client,
      double serviceCost = 10.0,
      String accountName = "Design income"}) async {
    // We need account to associate the created product with.
    // Query account for item
    var queryBuffer = StringBuffer();
    queryBuffer.write("SELECT * FROM Account ");
    queryBuffer.write("WHERE Name = '$accountName' ");

    String query = queryBuffer.toString();
    qbModels.Account account =
        (await client.getAccountingClient().queryAccount(query: query)).single;

    qbModels.Item itemToCreate = qbModels.Item(
        type: "Service",
        name: serviceName,
        description: serviceDescription,
        sku: "MAKANI_",
        incomeAccountRef: qbModels.ReferenceType(
          value: "${account.id}",
          name: "${accountName}",
        ),
        unitPrice: serviceCost);

    qbModels.Item createdItem =
        await client.getAccountingClient().createItem(item: itemToCreate);
    return createdItem;
  }

  ///
  /// Returns a page of services tracked on QuickBooks.
  ///
  Future<List<qbModels.Item>> _getServiceItems(
      {required int page,
      required int pageSize,
      required QuickbooksClient client, 
      double unitPrice = 10.0}) async {
    List<qbModels.Item> foundItems;
    var queryBuffer = StringBuffer();
    queryBuffer.write("SELECT * FROM Item ");
    queryBuffer.write("WHERE TYPE = 'Service' ");
    queryBuffer.write("AND Sku LIKE 'MAKANI_%' ");
    queryBuffer.write("STARTPOSITION $page ");
    queryBuffer.write("MAXRESULTS $pageSize ");

    String query = queryBuffer.toString();
    foundItems = await client.getAccountingClient().queryItem(query: query);

    return foundItems;
  }

  ///
  /// Helper for creating a invoice for a given customer based on the
  /// list of items provided.
  ///
  Future<qbModels.Invoice> _createInvoiceForItems(
      {required qbModels.Customer customer,
      required List<qbModels.Item> items,
      required QuickbooksClient client}) async {
    qbModels.Invoice invoiceToCreate = qbModels.Invoice(
        customerRef: qbModels.ReferenceType(value: customer.id!),
        billEmail: customer.primaryEmailAddr,
        allowOnlineCreditCardPayment: true,
        allowOnlinePayment: true,
        allowIPNPayment: true,
        allowOnlineACHPayment: true,
        line: items
            .map((item) => qbModels.SalesItemLine(
                id: item.id,
                detailType: "SalesItemLineDetail",
                amount: item.unitPrice,
                description: item.description,
                salesItemLineDetail: qbModels.SalesItemLineDetail(
                    unitPrice: item.unitPrice,
                    itemRef: qbModels.ReferenceType(
                        name: item.name, value: item.id!))))
            .toList());

    qbModels.Invoice createdInvoice = await client
        .getAccountingClient()
        .createInvoice(invoice: invoiceToCreate);

    return createdInvoice;
  }

  ///
  /// Sends the specified invoice to the specified email address.
  ///
  Future<qbModels.Invoice> _emailInvoice(
      {required String invoiceId,
      required String emailTo,
      required QuickbooksClient client}) async {
    qbModels.Invoice sentInvoice = await client
        .getAccountingClient()
        .sendInvoice(invoiceId: invoiceId, emailTo: emailTo);
    return sentInvoice;
  }
}

mixin MahaloLogo {
  Widget buildAppLogo({required double width, required double height}) {
    return Container(
        width: width,
        height: height,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(
              image: AssetImage("assets/images/handyman.png"),
              fit: BoxFit.fill),
        ));
  }
}

mixin BrotherScanner {
  ///
  /// Looks for scanners on the local network.
  ///
  Future<List<Connector>> _fetchWifiScanners({int timeout = 2000}) =>
      AirBrother.getNetworkDevices(timeout);

  ///
  /// Looks for usb scanners.
  //Future<List<Connector>> _fetchUsbScanners({int timeout = 3000}) => AirBrother.getUsbDevices(timeout);

  ///
  /// Scans the files using the Brother Scanner
  ///
  Future<List<String>> _scanFiles(Connector connector) async {
    List<String> outScannedPaths = [];
    ScanParameters scanParams = ScanParameters();
    scanParams.documentSize = MediaSize.C5Envelope;
    JobState jobState =
        await connector.performScan(scanParams, outScannedPaths);
    print("JobState: $jobState");
    print("Files Scanned: $outScannedPaths");
    return outScannedPaths;
  }
}

mixin UsLicenseNumber {
  final _licenseNumberRegEx = RegExp(
      r'^.*([A-Z0-9]{4}-[A-Z0-9]{3}-[A-Z0-9]{2}-[A-Z0-9]{3}-[A-Z0-9]).*$');

  String? getNumber({required String line}) {
    line = line.replaceAll("\n", " ");
    print(
        "Trying to match: $line --- ${_licenseNumberRegEx.stringMatch(line)}");

    if (_licenseNumberRegEx.hasMatch(line)) {
      print("HasMatch: ${_licenseNumberRegEx.firstMatch(line)}");
      return _licenseNumberRegEx.firstMatch(line)?.group(1);
    }
    return null;
  }
}

@immutable
class ExpandableFab extends StatefulWidget {
  const ExpandableFab({
    Key? key,
    this.initialOpen,
    this.mainFabBody,
    required this.distance,
    required this.children,
  }) : super(key: key);

  final bool? initialOpen;
  final double distance;
  final List<Widget> children;
  final Widget? mainFabBody;

  @override
  _ExpandableFabState createState() => _ExpandableFabState();
}

class _ExpandableFabState extends State<ExpandableFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _expandAnimation;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.initialOpen ?? false;
    _controller = AnimationController(
      value: _open ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeOutQuad,
      parent: _controller,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      if (_open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.bottomRight,
        clipBehavior: Clip.none,
        children: [
          _buildTapToCloseFab(),
          ..._buildExpandingActionButtons(),
          _buildTapToOpenFab(),
        ],
      ),
    );
  }

  Widget _buildTapToCloseFab() {
    return SizedBox(
      width: 56.0,
      height: 56.0,
      child: Center(
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          elevation: 4.0,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(
                Icons.close,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildExpandingActionButtons() {
    final children = <Widget>[];
    final count = widget.children.length;
    final step = 90.0 / (count - 1);
    for (var i = 0, angleInDegrees = 0.0;
        i < count;
        i++, angleInDegrees += step) {
      children.add(
        _ExpandingActionButton(
          directionInDegrees: angleInDegrees,
          maxDistance: widget.distance,
          progress: _expandAnimation,
          child: widget.children[i],
        ),
      );
    }
    return children;
  }

  Widget _buildTapToOpenFab() {
    return IgnorePointer(
      ignoring: _open,
      child: AnimatedContainer(
        transformAlignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          _open ? 0.7 : 1.0,
          _open ? 0.7 : 1.0,
          1.0,
        ),
        duration: const Duration(milliseconds: 250),
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        child: AnimatedOpacity(
          opacity: _open ? 0.0 : 1.0,
          curve: const Interval(0.25, 1.0, curve: Curves.easeInOut),
          duration: const Duration(milliseconds: 250),
          child: FloatingActionButton(
            onPressed: _toggle,
            child: widget.mainFabBody,
          ),
        ),
      ),
    );
  }
}

@immutable
class _ExpandingActionButton extends StatelessWidget {
  const _ExpandingActionButton({
    Key? key,
    required this.directionInDegrees,
    required this.maxDistance,
    required this.progress,
    required this.child,
  }) : super(key: key);

  final double directionInDegrees;
  final double maxDistance;
  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final offset = Offset.fromDirection(
          directionInDegrees * (math.pi / 180.0),
          progress.value * maxDistance,
        );
        return Positioned(
          right: 4.0 + offset.dx,
          bottom: 4.0 + offset.dy,
          child: Transform.rotate(
            angle: (1.0 - progress.value) * math.pi / 2,
            child: child!,
          ),
        );
      },
      child: FadeTransition(
        opacity: progress,
        child: child,
      ),
    );
  }
}

@immutable
class ActionButton extends StatelessWidget {
  const ActionButton({
    Key? key,
    this.onPressed,
    required this.icon,
  }) : super(key: key);

  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.secondary,
      elevation: 4.0,
      child: IconButton(
        onPressed: onPressed,
        icon: icon,
        color: theme.colorScheme.onPrimary,
      ),
    );
  }
}

class MahaloAppBar extends StatelessWidget
    with PreferredSizeWidget, MahaloLogo {
  final String title;

  const MahaloAppBar({Key? key, required this.title}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AppBar(
          centerTitle: true,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(180),
                  bottomLeft: Radius.circular(180))),
          title:
              Text(title, style: GoogleFonts.loveYaLikeASister(fontSize: 30)),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          child: Center(
            child: buildAppLogo(width: kToolbarHeight, height: kToolbarHeight),
          ),
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

enum ProgressStatus { none, loading, done, error }

class ProgressModel extends EasyNotifier {
  ProgressModel({required ProgressStatus status, String? message}) {
    _status = status;
    _message = message;
  }

  ProgressStatus _status = ProgressStatus.none;

  ProgressStatus get status => _status;

  String? _message;

  String? get message => _message;

  void setData({required ProgressStatus status, String? message}) {
    notify(() {
      _message = message;
      _status = status;
    });
  }
}
