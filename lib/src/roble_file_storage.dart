import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'roble_api_exception.dart';

/// Peticion HTTP contra el servicio de datos, ya con el token puesto.
typedef RobleFileRequest = Future<dynamic> Function(
  String method,
  String path, {
  Object? body,
  Map<String, String>? queryParams,
});

/// Un archivo listado en el proyecto. No trae URL: pidela con [RobleFileStorage.getDownloadUrl].
class RobleFileInfo {
  const RobleFileInfo({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.folder,
    required this.createdAt,
  });

  final String fileId;
  final String fileName;
  final String? mimeType;
  final int? sizeBytes;
  final String? folder;
  final DateTime createdAt;

  factory RobleFileInfo.fromJson(Map<String, dynamic> json) {
    return RobleFileInfo(
      fileId: json['id'].toString(),
      fileName: json['file_name'].toString(),
      mimeType: json['mime_type'] as String?,
      sizeBytes: json['size_bytes'] == null
          ? null
          : int.tryParse(json['size_bytes'].toString()),
      folder: json['folder'] as String?,
      createdAt: DateTime.parse(json['created_at'].toString()),
    );
  }
}

/// Archivos del bucket S3-compatible del proyecto (el gestionado por Roble por
/// defecto, o el propio si se configuro uno en la consola).
///
/// Los bytes nunca pasan por el servidor de Roble: [upload] pide una URL
/// firmada y sube directo al bucket; [getDownloadUrl] hace lo mismo al reves.
///
/// ```dart
/// final subida = await db.files.upload(
///   fileName: 'foto.jpg',
///   mimeType: 'image/jpeg',
///   data: bytes,
/// );
/// final descarga = await db.files.getDownloadUrl(subida.fileId);
/// ```
class RobleFileStorage {
  RobleFileStorage({required RobleFileRequest request, http.Client? client})
      : _request = request,
        _client = client ?? http.Client();

  final RobleFileRequest _request;
  final http.Client _client;

  /// Sube un archivo y devuelve su `fileId`.
  ///
  /// Internamente: pide una URL de subida firmada, hace `PUT` directo al
  /// bucket con [data], y confirma la subida. Si el `PUT` falla, el archivo
  /// queda registrado como `PENDING` y nunca aparece en [list].
  Future<String> upload({
    required String fileName,
    required Uint8List data,
    String? mimeType,
    String? folder,
  }) async {
    final created = await _request('POST', 'storage/objects', body: {
      'fileName': fileName,
      if (mimeType != null) 'mimeType': mimeType,
      'sizeBytes': data.lengthInBytes,
      if (folder != null) 'folder': folder,
    }) as Map;

    final fileId = created['fileId'].toString();
    final uploadUrl = created['uploadUrl'].toString();

    final putRes = await _client.put(
      Uri.parse(uploadUrl),
      headers: mimeType != null ? {'Content-Type': mimeType} : null,
      body: data,
    );

    if (putRes.statusCode < 200 || putRes.statusCode >= 300) {
      throw RobleApiException(
          'No se pudo subir el archivo al bucket: HTTP ${putRes.statusCode}');
    }

    await _request('POST', 'storage/objects/$fileId/complete');

    return fileId;
  }

  /// Lista los archivos ya subidos, opcionalmente filtrados por carpeta.
  Future<List<RobleFileInfo>> list({String? folder}) async {
    final res = await _request(
      'GET',
      'storage/objects',
      queryParams: folder != null ? {'folder': folder} : null,
    );

    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((e) => RobleFileInfo.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  /// URL firmada para descargar [fileId]. Vence a los pocos minutos.
  Future<String> getDownloadUrl(String fileId) async {
    final res = await _request('GET', 'storage/objects/$fileId') as Map;
    return res['downloadUrl'].toString();
  }

  /// Descarga [fileId] y devuelve sus bytes directamente.
  Future<Uint8List> download(String fileId) async {
    final url = await getDownloadUrl(fileId);
    final res = await _client.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RobleApiException(
          'No se pudo descargar el archivo: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  /// Borra [fileId] del bucket y su metadata. Solo quien lo subio puede
  /// hacerlo.
  Future<void> remove(String fileId) async {
    await _request('DELETE', 'storage/objects/$fileId');
  }
}
