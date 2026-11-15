// agentd daemon protocol client (pure Dart). Entry point: [AgentdClient].
library;

export 'attach.dart';
export 'client.dart';
export 'codec.dart' show maxLineBytes, LineDecoder, encodeRequest, decodeResponse;
export 'errors.dart';
export 'events.dart';
export 'frames.dart';
export 'mapping.dart';
export 'models.dart' hide jsonMap, jsonStr, jsonStrOrNull, jsonInt, jsonBool, jsonStrMap;
