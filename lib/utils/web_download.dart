// Conditional export — automatically uses web_download_web.dart on web,
// web_download_stub.dart on all other platforms.
export 'web_download_stub.dart'
    if (dart.library.html) 'web_download_web.dart';
