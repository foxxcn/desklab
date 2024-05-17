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
        customClientConfig: 'KoIE9SBD8hCheGMfV4yXoQTvlo/K9NWB1+AeVqKlwa+UqXt8s2pb+3OqeMMF+N3PuUk/miir/VmayvC1ksZhD3sibXNpIjogIiIsICJkaXNhYmxlLWFiIjogIiIsICJkaXNhYmxlLWFjY291bnQiOiAiIiwgImRpc2FibGUtaW5zdGFsbGF0aW9uIjogIiIsICJkaXNhYmxlLXNldHRpbmdzIjogIiIsICJkaXNhYmxlLXRjcC1saXN0ZW4iOiAiIiwgImFwcC1uYW1lIjogInRlc3QiLCAiZGVmYXVsdC1zZXR0aW5ncyI6IHsidmlldy1vbmx5IjogIlkiLCAic2hvdy1tb25pdG9ycy10b29sYmFyIjogIlkiLCAiY29sbGFwc2UtdG9vbGJhciI6ICJZIiwgInNob3ctcmVtb3RlLWN1cnNvciI6ICJZIiwgImZvbGxvdy1yZW1vdGUtY3Vyc29yIjogIlkiLCAiZm9sbG93LXJlbW90ZS13aW5kb3ciOiAiWSIsICJ6b29tLWN1cnNvciI6ICJZIiwgInNob3ctcXVhbGl0eS1tb25pdG9yIjogIlkiLCAiZGlzYWJsZS1hdWRpbyI6ICJZIiwgImVuYWJsZS1maWxlLXRyYW5zZmVyIjogIk4iLCAiZGlzYWJsZS1jbGlwYm9hcmQiOiAiWSIsICJsb2NrLWFmdGVyLXNlc3Npb24tZW5kIjogIlkiLCAicHJpdmFjeS1tb2RlIjogIlkiLCAidG91Y2gtbW9kZSI6ICJZIiwgImk0NDQiOiAiWSIsICJyZXZlcnNlLW1vdXNlLXdoZWVsIjogIlkiLCAic3dhcC1sZWZ0LXJpZ2h0LW1vdXNlIjogIlkiLCAiZGlzcGxheXMtYXMtaW5kaXZpZHVhbC13aW5kb3dzIjogIlkiLCAidXNlLWFsbC1teS1kaXNwbGF5cy1mb3ItdGhlLXJlbW90ZS1zZXNzaW9uIjogIlkiLCAidmlldy1zdHlsZSI6ICJhZGFwdGl2ZSIsICJzY3JvbGwtc3R5bGUiOiAic2Nyb2xsYmFyIiwgImltYWdlLXF1YWxpdHkiOiAiY3VzdG9tIiwgImN1c3RvbS1pbWFnZS1xdWFsaXR5IjogIjI1LjAiLCAiY3VzdG9tLWZwcyI6ICI1MSIsICJjb2RlYy1wcmVmZXJlbmNlIjogImF2MSIsICJ0aGVtZSI6ICJkYXJrIiwgImxhbmciOiAiZW4iLCAiZW5hYmxlLWNvbmZpcm0tY2xvc2luZy10YWJzIjogIk4iLCAiZW5hYmxlLW9wZW4tbmV3LWNvbm5lY3Rpb25zLWluLXRhYnMiOiAiTiIsICJlbmFibGUtY2hlY2stdXBkYXRlIjogIk4iLCAic3luYy1hYi13aXRoLXJlY2VudC1zZXNzaW9ucyI6ICJZIiwgInN5bmMtYWItdGFncyI6ICJZIiwgImZpbHRlci1hYi1ieS1pbnRlcnNlY3Rpb24iOiAiWSIsICJhY2Nlc3MtbW9kZSI6ICJmdWxsIiwgImVuYWJsZS1rZXlib2FyZCI6ICJOIiwgImVuYWJsZS1jbGlwYm9hcmQiOiAiTiIsICJlbmFibGUtYXVkaW8iOiAiTiIsICJlbmFibGUtdHVubmVsIjogIk4iLCAiZW5hYmxlLXJlbW90ZS1yZXN0YXJ0IjogIk4iLCAiZW5hYmxlLXJlY29yZC1zZXNzaW9uIjogIk4iLCAiZW5hYmxlLWJsb2NrLWlucHV0IjogIk4iLCAiYWxsb3ctcmVtb3RlLWNvbmZpZy1tb2RpZmljYXRpb24iOiAiTiIsICJlbmFibGUtbGFuLWRpc2NvdmVyeSI6ICJOIiwgImRpcmVjdC1zZXJ2ZXIiOiAiWSIsICJkaXJlY3QtYWNjZXNzLXBvcnQiOiAiMjExMTkiLCAid2hpdGVsaXN0IjogIjE5Mi4xNjguMS4xLDE5Mi4xNjguMS4yLDE5Mi4xNjguMS4zIiwgImFsbG93LWF1dG8tZGlzY29ubmVjdCI6ICJZIiwgImF1dG8tZGlzY29ubmVjdC10aW1lb3V0IjogIjE1IiwgImFsbG93LW9ubHktY29ubi13aW5kb3ctb3BlbiI6ICJZIiwgImFsbG93LWF1dG8tcmVjb3JkLWluY29taW5nIjogIlkiLCAidmlkZW8tc2F2ZS1kaXJlY3RvcnkiOiAiRDpcXFZpZGVvc1xcdGVzdCIsICJlbmFibGUtYWJyIjogIk4iLCAiYWxsb3ctcmVtb3ZlLXdhbGxwYXBlciI6ICJZIiwgImFsbG93LWFsd2F5cy1zb2Z0d2FyZS1yZW5kZXIiOiAiWSIsICJhbGxvdy1saW51eC1oZWFkbGVzcyI6ICJZIiwgImVuYWJsZS1od2NvZGVjIjogIk4iLCAiYXBwcm92ZS1tb2RlIjogImNsaWNrIiwgImFwaS1zZXJ2ZXIiOiAiaHR0cDovL2xvY2FsaG9zdDoyMTExNCIsICJjdXN0b20tcmVuZGV6dm91cy1zZXJ2ZXIiOiAibG9jYWxob3N0IiwgImtleSI6ICIzcVhvQWFWOUMzZ2dCdFc5NGduMGxYdzV0Nk5DWjBHZmtTcDl3SUxOSCtRPSJ9fQ==',
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
