enum UsbDeviceModel { de1 }

typedef UsbIdPair = (int vid, int pid);

const List<UsbIdPair> de1UsbIds = [];

const Map<UsbDeviceModel, List<UsbIdPair>> usbDeviceTable = {
  UsbDeviceModel.de1: de1UsbIds,
};

UsbDeviceModel? matchUsbDevice(
  Map<UsbDeviceModel, List<UsbIdPair>> table, {
  required int? vid,
  required int? pid,
}) {
  if (vid == null || pid == null) return null;
  for (final entry in table.entries) {
    for (final pair in entry.value) {
      if (pair.$1 == vid && pair.$2 == pid) {
        return entry.key;
      }
    }
  }
  return null;
}

const int bengleEbusTapVid = 0x2e8a;
const int bengleEbusTapPid = 0x000a;

/// USB product name string of the Bengle machine and its EBus tap.
///
/// VID/PID are shared Pico SDK identifiers, so the exact product name is
/// required in addition to the IDs and interface before anything is treated
/// as the tap.
const String bengleUsbProductName = 'Bengle';

/// Logical USB interface of the Bengle EBus tap (Linux CDC control
/// interface). ReaPrime's identity, stable ID, and docs all use `if02`.
const int bengleEbusTapInterface = 2;

/// Android bulk-data interface for the Bengle EBus tap.
///
/// The installed usb_serial fork treats the requested interface as the CDC
/// bulk-data interface and derives the control interface as `iface - 1`.
/// The tap's Android bulk-data interface is therefore 3 (Linux control
/// interface 2). Do NOT change this back to 2 — interface 2 is the control
/// interface, which has no bulk endpoints and makes `UsbPort.open()` fail.
const int bengleEbusAndroidDataInterface = 3;

/// True only for the Bengle EBus tap: VID 0x2e8a, PID 0x000a, interface 2,
/// and the exact product name `Bengle`. Everything else — interface 0,
/// missing metadata, other products, and devices without interface 2 — is
/// false.
bool isBengleEbusTap({
  int? vid,
  int? pid,
  int? interfaceNumber,
  required String? productName,
}) {
  return vid == bengleEbusTapVid &&
      pid == bengleEbusTapPid &&
      interfaceNumber == bengleEbusTapInterface &&
      productName == bengleUsbProductName;
}

/// True when a Bengle composite device reports enough interfaces to contain
/// the EBus tap and carries the exact product name `Bengle`. Android exposes
/// the interface count, not a per-interface number, so presence of the tap's
/// bulk-data interface 3 is inferred from `interfaceCount > 3`.
bool isBengleCompositeWithTap({
  int? vid,
  int? pid,
  int? interfaceCount,
  required String? productName,
}) {
  return vid == bengleEbusTapVid &&
      pid == bengleEbusTapPid &&
      interfaceCount != null &&
      interfaceCount > bengleEbusAndroidDataInterface &&
      productName == bengleUsbProductName;
}
