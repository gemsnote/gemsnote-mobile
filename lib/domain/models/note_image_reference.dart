/// Interpret stored image references only; these paths are never requested.
/// Historical bodies may contain legacy paths even when all requests use API2.
String? cachedImageFileId(Uri reference, Uri server) {
  final resolved = server.resolveUri(reference);
  if (!{'http', 'https'}.contains(resolved.scheme) ||
      resolved.host.isEmpty ||
      resolved.origin != server.origin ||
      resolved.userInfo.isNotEmpty ||
      resolved.hasFragment ||
      !{
        '/api2/file/getImage',
        '/api/file/getImage',
        '/file/outputImage',
      }.contains(resolved.path)) {
    return null;
  }
  final ids = resolved.queryParametersAll['fileId'];
  if (ids == null ||
      ids.length != 1 ||
      !RegExp(r'^[0-9a-fA-F]{24}$').hasMatch(ids.single)) {
    return null;
  }
  return ids.single;
}
