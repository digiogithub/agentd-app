// Host detection and installs over a RemoteShell.
export 'detect.dart' show DetectReport, detectScript, detectTools, parseDetect, cleanVersion;
export 'provision_service.dart';
export 'steps.dart' show buildPlan, npmPackages, installableClis, mcpHarnesses;
