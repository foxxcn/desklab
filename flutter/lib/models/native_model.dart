import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:external_path/external_path.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../generated_bridge.dart';

final class RgbaFrame extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> data;
}

typedef F3 = Pointer<Uint8> Function(Pointer<Utf8>, int);
typedef F3Dart = Pointer<Uint8> Function(Pointer<Utf8>, Int32);
typedef HandleEvent = Future<void> Function(Map<String, dynamic> evt);

/// FFI wrapper around the native Rust core.
/// Hides the platform differences.
class PlatformFFI {
  String _dir = '';
  // _homeDir is only needed for Android and IOS.
  String _homeDir = '';
  final _eventHandlers = <String, Map<String, HandleEvent>>{};
  late RustdeskImpl _ffiBind;
  late String _appType;
  StreamEventHandler? _eventCallback;

  PlatformFFI._();

  static final PlatformFFI instance = PlatformFFI._();
  final _toAndroidChannel = const MethodChannel('mChannel');

  RustdeskImpl get ffiBind => _ffiBind;
  F3? _session_get_rgba;

  static get localeName => Platform.localeName;

  static get isMain => instance._appType == kAppTypeMain;

  static Future<String> getVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  bool registerEventHandler(
      String eventName, String handlerName, HandleEvent handler) {
    debugPrint('registerEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers == null) {
      _eventHandlers[eventName] = {handlerName: handler};
      return true;
    } else {
      if (handlers.containsKey(handlerName)) {
        return false;
      } else {
        handlers[handlerName] = handler;
        return true;
      }
    }
  }

  void unregisterEventHandler(String eventName, String handlerName) {
    debugPrint('unregisterEventHandler $eventName $handlerName');
    var handlers = _eventHandlers[eventName];
    if (handlers != null) {
      handlers.remove(handlerName);
    }
  }

  String translate(String name, String locale) =>
      _ffiBind.translate(name: name, locale: locale);

  Uint8List? getRgba(SessionID sessionId, int display, int bufSize) {
    if (_session_get_rgba == null) return null;
    final sessionIdStr = sessionId.toString();
    var a = sessionIdStr.toNativeUtf8();
    try {
      final buffer = _session_get_rgba!(a, display);
      if (buffer == nullptr) {
        return null;
      }
      final data = buffer.asTypedList(bufSize);
      return data;
    } finally {
      malloc.free(a);
    }
  }

  int getRgbaSize(SessionID sessionId, int display) =>
      _ffiBind.sessionGetRgbaSize(sessionId: sessionId, display: display);
  void nextRgba(SessionID sessionId, int display) =>
      _ffiBind.sessionNextRgba(sessionId: sessionId, display: display);
  void registerPixelbufferTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterPixelbufferTexture(
          sessionId: sessionId, display: display, ptr: ptr);
  void registerGpuTexture(SessionID sessionId, int display, int ptr) =>
      _ffiBind.sessionRegisterGpuTexture(
          sessionId: sessionId, display: display, ptr: ptr);

  /// Init the FFI class, loads the native Rust core library.
  Future<void> init(String appType) async {
    _appType = appType;
    final dylib = isAndroid
        ? DynamicLibrary.open('librustdesk.so')
        : isLinux
            ? DynamicLibrary.open('librustdesk.so')
            : isWindows
                ? DynamicLibrary.open('librustdesk.dll')
                : isMacOS
                    ? DynamicLibrary.open("liblibrustdesk.dylib")
                    : DynamicLibrary.process();
    debugPrint('initializing FFI $_appType');
    try {
      _session_get_rgba = dylib.lookupFunction<F3Dart, F3>("session_get_rgba");
      try {
        // SYSTEM user failed
        _dir = (await getApplicationDocumentsDirectory()).path;
      } catch (e) {
        debugPrint('Failed to get documents directory: $e');
      }
      _ffiBind = RustdeskImpl(dylib);

      if (isLinux) {
        // Start a dbus service, no need to await
        _ffiBind.mainStartDbusServer();
        _ffiBind.mainStartPa();
      } else if (isMacOS && isMain) {
        // Start ipc service for uri links.
        _ffiBind.mainStartIpcUrlServer();
      }
      _startListenEvent(_ffiBind); // global event
      try {
        if (isAndroid) {
          // only support for android
          _homeDir = (await ExternalPath.getExternalStorageDirectories())[0];
        } else if (isIOS) {
          _homeDir = _ffiBind.mainGetDataDirIos();
        } else {
          // no need to set home dir
        }
      } catch (e) {
        debugPrintStack(label: 'initialize failed: $e');
      }
      String id = 'NA';
      String name = 'Flutter';
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        name = '${androidInfo.brand}-${androidInfo.model}';
        id = androidInfo.id.hashCode.toString();
        androidVersion = androidInfo.version.sdkInt;
      } else if (isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        name = iosInfo.utsname.machine;
        id = iosInfo.identifierForVendor.hashCode.toString();
      } else if (isLinux) {
        LinuxDeviceInfo linuxInfo = await deviceInfo.linuxInfo;
        name = linuxInfo.name;
        id = linuxInfo.machineId ?? linuxInfo.id;
      } else if (isWindows) {
        try {
          // request windows build number to fix overflow on win7
          windowsBuildNumber = getWindowsTargetBuildNumber();
          WindowsDeviceInfo winInfo = await deviceInfo.windowsInfo;
          name = winInfo.computerName;
          id = winInfo.computerName;
        } catch (e) {
          debugPrintStack(label: "get windows device info failed: $e");
          name = "unknown";
          id = "unknown";
        }
      } else if (isMacOS) {
        MacOsDeviceInfo macOsInfo = await deviceInfo.macOsInfo;
        name = macOsInfo.computerName;
        id = macOsInfo.systemGUID ?? '';
      }
      if (isAndroid || isIOS) {
        debugPrint(
            '_appType:$_appType,info1-id:$id,info2-name:$name,dir:$_dir,homeDir:$_homeDir');
      } else {
        debugPrint(
            '_appType:$_appType,info1-id:$id,info2-name:$name,dir:$_dir');
      }
      if (desktopType == DesktopType.cm) {
        await _ffiBind.cmInit();
      }
      await _ffiBind.mainDeviceId(id: id);
      await _ffiBind.mainDeviceName(name: name);
      await _ffiBind.mainSetHomeDir(home: _homeDir);
      await _ffiBind.mainInit(
        appDir: _dir,
        customClientConfig: 'DKMHJ4l+TNb1/4+PYCHGZQZue+D1CGIPFewYf4u+ymHSxPUKzQH2ExU/aJuI2WFCPzBMp0Kq+6Uv/RU+v3ELAXsibXNpIjogIiIsICJkaXNhYmxlLWFiIjogIiIsICJkaXNhYmxlLWFjY291bnQiOiAiIiwgImRpc2FibGUtaW5zdGFsbGF0aW9uIjogIiIsICJkaXNhYmxlLXNldHRpbmdzIjogIiIsICJkaXNhYmxlLXRjcC1saXN0ZW4iOiAiIiwgImFwcC1uYW1lIjogInRlc3QiLCAib3ZlcnJpZGUtc2V0dGluZ3MiOiB7InZpZXctb25seSI6ICJZIiwgInNob3ctbW9uaXRvcnMtdG9vbGJhciI6ICJZIiwgImNvbGxhcHNlLXRvb2xiYXIiOiAiWSIsICJzaG93LXJlbW90ZS1jdXJzb3IiOiAiWSIsICJmb2xsb3ctcmVtb3RlLWN1cnNvciI6ICJZIiwgImZvbGxvdy1yZW1vdGUtd2luZG93IjogIlkiLCAiem9vbS1jdXJzb3IiOiAiWSIsICJzaG93LXF1YWxpdHktbW9uaXRvciI6ICJZIiwgImRpc2FibGUtYXVkaW8iOiAiWSIsICJlbmFibGUtZmlsZS10cmFuc2ZlciI6ICJOIiwgImRpc2FibGUtY2xpcGJvYXJkIjogIlkiLCAibG9jay1hZnRlci1zZXNzaW9uLWVuZCI6ICJZIiwgInByaXZhY3ktbW9kZSI6ICJZIiwgInRvdWNoLW1vZGUiOiAiWSIsICJpNDQ0IjogIlkiLCAicmV2ZXJzZS1tb3VzZS13aGVlbCI6ICJZIiwgInN3YXAtbGVmdC1yaWdodC1tb3VzZSI6ICJZIiwgImRpc3BsYXlzLWFzLWluZGl2aWR1YWwtd2luZG93cyI6ICJZIiwgInVzZS1hbGwtbXktZGlzcGxheXMtZm9yLXRoZS1yZW1vdGUtc2Vzc2lvbiI6ICJZIiwgInZpZXctc3R5bGUiOiAiYWRhcHRpdmUiLCAic2Nyb2xsLXN0eWxlIjogInNjcm9sbGJhciIsICJpbWFnZS1xdWFsaXR5IjogImN1c3RvbSIsICJjdXN0b20taW1hZ2UtcXVhbGl0eSI6ICIyNS4wIiwgImN1c3RvbS1mcHMiOiAiNTEiLCAiY29kZWMtcHJlZmVyZW5jZSI6ICJhdjEiLCAidGhlbWUiOiAiZGFyayIsICJsYW5nIjogImVuIiwgImVuYWJsZS1jb25maXJtLWNsb3NpbmctdGFicyI6ICJOIiwgImVuYWJsZS1vcGVuLW5ldy1jb25uZWN0aW9ucy1pbi10YWJzIjogIk4iLCAiZW5hYmxlLWNoZWNrLXVwZGF0ZSI6ICJOIiwgInN5bmMtYWItd2l0aC1yZWNlbnQtc2Vzc2lvbnMiOiAiWSIsICJzeW5jLWFiLXRhZ3MiOiAiWSIsICJmaWx0ZXItYWItYnktaW50ZXJzZWN0aW9uIjogIlkiLCAiYWNjZXNzLW1vZGUiOiAiZnVsbCIsICJlbmFibGUta2V5Ym9hcmQiOiAiTiIsICJlbmFibGUtY2xpcGJvYXJkIjogIk4iLCAiZW5hYmxlLWF1ZGlvIjogIk4iLCAiZW5hYmxlLXR1bm5lbCI6ICJOIiwgImVuYWJsZS1yZW1vdGUtcmVzdGFydCI6ICJOIiwgImVuYWJsZS1yZWNvcmQtc2Vzc2lvbiI6ICJOIiwgImVuYWJsZS1ibG9jay1pbnB1dCI6ICJOIiwgImFsbG93LXJlbW90ZS1jb25maWctbW9kaWZpY2F0aW9uIjogIk4iLCAiZW5hYmxlLWxhbi1kaXNjb3ZlcnkiOiAiTiIsICJkaXJlY3Qtc2VydmVyIjogIlkiLCAiZGlyZWN0LWFjY2Vzcy1wb3J0IjogIjIxMTE5IiwgIndoaXRlbGlzdCI6ICIxOTIuMTY4LjEuMSwxOTIuMTY4LjEuMiwxOTIuMTY4LjEuMyIsICJhbGxvdy1hdXRvLWRpc2Nvbm5lY3QiOiAiWSIsICJhdXRvLWRpc2Nvbm5lY3QtdGltZW91dCI6ICIxNSIsICJhbGxvdy1vbmx5LWNvbm4td2luZG93LW9wZW4iOiAiWSIsICJhbGxvdy1hdXRvLXJlY29yZC1pbmNvbWluZyI6ICJZIiwgInZpZGVvLXNhdmUtZGlyZWN0b3J5IjogIkQ6XFxWaWRlb3NcXHRlc3QiLCAiZW5hYmxlLWFiciI6ICJOIiwgImFsbG93LXJlbW92ZS13YWxscGFwZXIiOiAiWSIsICJhbGxvdy1hbHdheXMtc29mdHdhcmUtcmVuZGVyIjogIlkiLCAiYWxsb3ctbGludXgtaGVhZGxlc3MiOiAiWSIsICJlbmFibGUtaHdjb2RlYyI6ICJOIiwgImFwcHJvdmUtbW9kZSI6ICJjbGljayJ9LCAiZGVmYXVsdC1zZXR0aW5ncyI6IHsiYXBpLXNlcnZlciI6ICJodHRwOi8vbG9jYWxob3N0OjIxMTE0IiwgImN1c3RvbS1yZW5kZXp2b3VzLXNlcnZlciI6ICJsb2NhbGhvc3QiLCAia2V5IjogIjNxWG9BYVY5QzNnZ0J0Vzk0Z24wbFh3NXQ2TkNaMEdma1NwOXdJTE5IK1E9In19',
      );
    } catch (e) {
      debugPrintStack(label: 'initialize failed: $e');
    }
    version = await getVersion();
  }

  Future<bool> tryHandle(Map<String, dynamic> evt) async {
    final name = evt['name'];
    if (name != null) {
      final handlers = _eventHandlers[name];
      if (handlers != null) {
        if (handlers.isNotEmpty) {
          for (var handler in handlers.values) {
            await handler(evt);
          }
          return true;
        }
      }
    }
    return false;
  }

  /// Start listening to the Rust core's events and frames.
  void _startListenEvent(RustdeskImpl rustdeskImpl) {
    final appType =
        _appType == kAppTypeDesktopRemote ? '$_appType,$kWindowId' : _appType;
    var sink = rustdeskImpl.startGlobalEventStream(appType: appType);
    sink.listen((message) {
      () async {
        try {
          Map<String, dynamic> event = json.decode(message);
          // _tryHandle here may be more flexible than _eventCallback
          if (!await tryHandle(event)) {
            if (_eventCallback != null) {
              await _eventCallback!(event);
            }
          }
        } catch (e) {
          debugPrint('json.decode fail(): $e');
        }
      }();
    });
  }

  void setEventCallback(StreamEventHandler fun) async {
    _eventCallback = fun;
  }

  void setRgbaCallback(void Function(int, Uint8List) fun) async {}

  void startDesktopWebListener() {}

  void stopDesktopWebListener() {}

  void setMethodCallHandler(FMethod callback) {
    _toAndroidChannel.setMethodCallHandler((call) async {
      callback(call.method, call.arguments);
      return null;
    });
  }

  invokeMethod(String method, [dynamic arguments]) async {
    if (!isAndroid) return Future<bool>(() => false);
    return await _toAndroidChannel.invokeMethod(method, arguments);
  }

  void syncAndroidServiceAppDirConfigPath() {
    invokeMethod(AndroidChannel.kSyncAppDirConfigPath, _dir);
  }
}
