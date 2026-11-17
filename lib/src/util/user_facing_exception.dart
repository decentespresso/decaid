abstract interface class UserFacingException implements Exception {
  String get message;
}

class UserFacingFormatException extends FormatException
    implements UserFacingException {
  const UserFacingFormatException(super.message);
}
