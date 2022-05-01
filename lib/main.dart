import 'package:another_quickbooks/another_quickbooks.dart';
import 'package:another_quickbooks/quickbook_models.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

void main() {
  runApp(const MyApp());
}

const double kLabelWidth = 90.3;
const double kLabelHeight = 29;
const double kDefaultRatePerHour = 60.0;
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

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }

  Future<void> chargeClient() async {
    // TODO Scan Driver's license
    // TODO Extract License number, first name, last name.
    // TODO Get QuickBooks customer using license number.
    // TODO If customer does not exist, create it on QuickBooks.
    // TODO Create invoice with a line item for each selected item in service list
    // TODO Prompt user with invoice receipt and request email address if not present in customer.
    // TODO On return if customer email is different from provided on update customer.
    // TODO Send invoice to customer.
    // DONE
  }

}

mixin QuickBooksHelper {

  ///
  /// Helper for creating a QuickBooks customer.
  ///
  Future<Customer> _createCustomer(
      {required String driverLicenseNumber, required String firstName, required String lastName, required QuickbooksClient client}) async {
    Customer customerToCreate = Customer(
      givenName: firstName,
      familyName: lastName,
      resaleNum: driverLicenseNumber,
    );
    Customer createdCustomer = await client.getAccountingClient()
        .createCustomer(customer: customerToCreate);
    return createdCustomer;
  }

  ///
  /// Helper to find a QuickBooks customer from a driver's license number
  ///
  Future<Customer?> _getCustomerByDriverLicense(
      {required String driverLicenseNumber, required QuickbooksClient client}) async {
    List<Customer> foundCustomers;
    try {
      var queryBuffer = StringBuffer();
      queryBuffer.write("SELECT * FROM Customer ");
      queryBuffer.write("WHERE ResaleNum = '$driverLicenseNumber' ");

      String query = queryBuffer.toString();
      foundCustomers =
      await client.getAccountingClient().queryCustomer(query: query);
    }
    catch (e) {
      foundCustomers = List<Customer>.empty();
    }

    if (foundCustomers.isEmpty) {
      return null;
    }
    return foundCustomers.single;
  }

  ///
  /// Updates the customer on QuickBooks.
  ///
  Future<Customer> _updateCustomer({required Customer customer, required QuickbooksClient client}) async {
    return await client.getAccountingClient().updateCustomer(customer: customer);
  }

  ///
  /// Helper for creating an item.
  ///
  Future<Item> _createServiceItem({required String serviceName, required QuickbooksClient client, double serviceCost = 10.0, String accountName = "Design income"}) async {

    // We need account to associate the created product with.
    // Query account for item
    var queryBuffer = StringBuffer();
    queryBuffer.write("SELECT * FROM Account ");
    queryBuffer.write("WHERE Name = '$accountName' ");

    String query = queryBuffer.toString();
    Account account = (await client.getAccountingClient().queryAccount(query: query)).single;


    Item itemToCreate = Item(
      type: "Service",
      name: serviceName,
      incomeAccountRef: ReferenceType(
        value: "${account.id}",
        name: "${accountName}",
      ),
      unitPrice: serviceCost
    );

    Item createdItem = await client.getAccountingClient().createItem(item: itemToCreate);
    return createdItem;
  }
  ///
  /// Returns a page of services tracked on QuickBooks.
  ///
  Future<List<Item>> _getServiceItems(
      {required int start, required int pageSize, required QuickbooksClient client}) async {
    List<Item> foundItems;
      var queryBuffer = StringBuffer();
      queryBuffer.write("SELECT * FROM Item ");
      queryBuffer.write("WHERE TYPE = 'Service' ");
      queryBuffer.write("STARTPOSITION = $start ");
      queryBuffer.write("MAXRESULTS = $pageSize ");

      String query = queryBuffer.toString();
      foundItems =
      await client.getAccountingClient().queryItem(query: query);

      return foundItems;
  }

  ///
  /// Helper for creating a invoice for a given customer based on the
  /// list of items provided.
  ///
  Future<Invoice> _createInvoiceForItems({required Customer customer, required List<Item> items, required QuickbooksClient client}) async {

    Invoice invoiceToCreate = Invoice(
        customerRef: ReferenceType(
          value: customer.id!
        ),
      billEmail: customer.primaryEmailAddr,
      allowOnlineCreditCardPayment: true,
      line: items.map((item) => SalesItemLine(
        id: item.id,
        detailType: "SalesItemLineDetail",
        amount: item.unitPrice,
        description: item.description,
        salesItemLineDetail: SalesItemLineDetail(
          unitPrice: item.unitPrice,
          itemRef: ReferenceType(
            name: item.name,
            value: item.id!
          )
        )
      )).toList()
    );

    Invoice createdInvoice = await client.getAccountingClient().createInvoice(invoice: invoiceToCreate);

    return createdInvoice;
  }

  ///
  /// Sends the specified invoice to the specified email address.
  /// 
  Future<Invoice> _emailInvoice({required String invoiceId, required String emailTo, required QuickbooksClient client}) async {
    Invoice sentInvoice = await client.getAccountingClient().sendInvoice(invoiceId: invoiceId, emailTo: emailTo);
    return sentInvoice;
  }

}
