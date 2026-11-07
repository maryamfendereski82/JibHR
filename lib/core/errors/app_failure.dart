class AppFailure implements Exception {
  const AppFailure(this.code);

  final String code;

  @override
  String toString() => code;
}
