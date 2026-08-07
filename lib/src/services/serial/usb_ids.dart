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
