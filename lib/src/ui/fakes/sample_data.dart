// Sample data of the mockups, used by the fakes (previews and widget tests).

import '../../core/contracts.dart';

const kEpoch = 'e1a2b3';

HostCapabilities _caps(Map<String, String?> installed, {String distro = 'Debian 13', bool agentd = true}) {
  const all = ['agentd', 'zellij', 'tmux', 'node', 'npm', 'claude', 'codex', 'pando', 'opencode', 'gemini'];
  return HostCapabilities(
    os: 'Linux',
    arch: 'x86_64',
    distro: distro,
    systemdUser: true,
    runtimeDir: '/run/user/1000',
    agentdSocket: agentd ? '/run/user/1000/agentd/agentd.sock' : null,
    tools: {
      for (final t in all)
        t: ToolInfo(t, installed: installed.containsKey(t), version: installed[t], path: installed.containsKey(t) ? '/usr/local/bin/$t' : null),
    },
  );
}

final sampleHosts = <HostStatus>[
  HostStatus(
    const HostConfig(id: 'estudio', name: 'estudio', host: 'estudio.local', user: 'jose', hostKeyFingerprint: 'SHA256:q3f1…'),
    state: HostState.online,
    sessionCount: 4,
    capabilities: _caps({'agentd': '0.6.2', 'zellij': '0.43', 'tmux': '3.5', 'node': '24', 'npm': '11', 'claude': '2.4', 'codex': '0.62', 'pando': '1.9'}),
  ),
  HostStatus(
    const HostConfig(id: 'vps-hetzner', name: 'vps-hetzner', host: 'vps', user: 'dev'),
    state: HostState.online,
    sessionCount: 2,
    capabilities: _caps({'agentd': '0.6.1', 'node': '22', 'npm': '10', 'codex': '0.62'}),
  ),
  HostStatus(
    const HostConfig(id: 'portatil', name: 'portatil', host: '192.168.1.40', user: 'jose'),
    state: HostState.online,
    sessionCount: 1,
    capabilities: _caps({'zellij': '0.43', 'node': '24', 'npm': '11', 'claude': '2.4'}, distro: 'Pop!_OS 24.04', agentd: false),
  ),
  const HostStatus(
    HostConfig(id: 'raspberry', name: 'raspberry', host: 'raspberrypi.local', user: 'pi'),
    state: HostState.offline,
  ),
];

List<AgentSession> sampleSessions(DateTime now) => [
  AgentSession(
    hostId: 'estudio',
    source: SessionSource.agentd,
    name: 'claude@webapp',
    harness: 'claude',
    project: 'webapp',
    status: AgentStatus.waiting,
    attention: true,
    cwd: '~/src/webapp',
    turn: 9,
    updatedAt: now.subtract(const Duration(minutes: 1)),
    pending: const PendingInteraction(
      question: 'Do you want to proceed?',
      kind: PendingKind.permission,
      detail: 'go test ./internal/... -race',
      options: [
        SessionOption(id: 'o-yes', label: 'Yes', index: 1, selected: true, kind: OptionKind.numbered),
        SessionOption(id: 'o-always', label: "Yes, and don't ask again for go test", index: 2, kind: OptionKind.numbered),
        SessionOption(id: 'o-no', label: 'No, and tell Claude what to do differently', index: 3, kind: OptionKind.numbered),
      ],
      revision: 41,
      epoch: kEpoch,
    ),
  ),
  AgentSession(
    hostId: 'vps-hetzner',
    source: SessionSource.agentd,
    name: 'codex@api',
    harness: 'codex',
    project: 'api',
    status: AgentStatus.waiting,
    attention: true,
    cwd: '~/src/api',
    turn: 14,
    updatedAt: now.subtract(const Duration(minutes: 3)),
    pending: const PendingInteraction(
      question: '¿Migro la tabla `sessions` ahora o dejo la migración para el despliegue?',
      kind: PendingKind.question,
      options: [
        SessionOption(id: 'q-now', label: 'Migrar ahora con una migración reversible', index: 1),
        SessionOption(id: 'q-deploy', label: 'Dejarlo para el despliegue y documentarlo', index: 2, selected: true),
        SessionOption(id: 'q-stop', label: 'Parar y revisar el esquema conmigo', index: 3),
      ],
      revision: 17,
      epoch: kEpoch,
    ),
  ),
  AgentSession(
    hostId: 'estudio',
    source: SessionSource.agentd,
    name: 'pando@agentd',
    harness: 'pando',
    project: 'agentd',
    status: AgentStatus.working,
    preview: 'Leyendo internal/hcompat/server.go…',
    cwd: '~/src/agentd',
    turn: 3,
    updatedAt: now.subtract(const Duration(minutes: 2)),
  ),
  AgentSession(
    hostId: 'portatil',
    source: SessionSource.zellij,
    name: 'main',
    status: AgentStatus.working,
    detail: '3 panes · claude en pane 2',
    updatedAt: now.subtract(const Duration(seconds: 20)),
  ),
  AgentSession(
    hostId: 'estudio',
    source: SessionSource.agentd,
    name: 'claude@docs',
    harness: 'claude',
    project: 'docs',
    status: AgentStatus.idle,
    attention: true,
    preview: 'README actualizado con la sección de instalación',
    cwd: '~/src/docs',
    turn: 5,
    updatedAt: now.subtract(const Duration(minutes: 8)),
  ),
  AgentSession(
    hostId: 'vps-hetzner',
    source: SessionSource.agentd,
    name: 'codex@webapp',
    harness: 'codex',
    project: 'webapp',
    status: AgentStatus.idle,
    preview: 'Tests en verde, sin cambios pendientes',
    cwd: '~/src/webapp',
    turn: 2,
    updatedAt: now.subtract(const Duration(minutes: 40)),
  ),
  AgentSession(
    hostId: 'estudio',
    source: SessionSource.agentd,
    name: 'pando@pips',
    harness: 'pando',
    project: 'pips',
    status: AgentStatus.idle,
    preview: 'Plan de colas enviado a claude@agentd',
    cwd: '~/src/pips',
    turn: 7,
    updatedAt: now.subtract(const Duration(hours: 1)),
  ),
];

/// Chat transcript of a sample session.
List<ChatItem> sampleItems(AgentSession s) {
  switch (s.name) {
    case 'codex@api':
      return const [
        ChatItem(role: ChatRole.user, text: 'Añade expiración a los tokens de sesión y migra la base de datos.'),
        ChatItem(role: ChatRole.agent, text: 'He añadido `expires_at` al modelo y los tests pasan. Antes de tocar la base de datos necesito una decisión.'),
        ChatItem(role: ChatRole.tool, title: 'go test ./...', text: 'ok  api/internal/auth  1.204s\nok  api/internal/store 2.871s', ok: true),
        ChatItem(role: ChatRole.tool, title: 'auth/token.go', text: ''),
      ];
    case 'claude@webapp':
      return const [
        ChatItem(role: ChatRole.user, text: 'Pasa los tests del daemon con -race y arregla lo que falle.'),
        ChatItem(role: ChatRole.agent, text: 'Voy a ejecutar `go test ./internal/... -race`.'),
      ];
    case 'pando@agentd':
      return const [
        ChatItem(role: ChatRole.user, text: 'Revisa el servidor hc y propón mejoras.'),
        ChatItem(role: ChatRole.tool, title: 'read internal/hcompat/server.go', text: '1.240 líneas', ok: true),
        ChatItem(role: ChatRole.agent, text: 'Leyendo internal/hcompat/server.go…'),
      ];
    default:
      return [const ChatItem(role: ChatRole.system, text: 'Turno terminado'), if (s.preview != null) ChatItem(role: ChatRole.agent, text: s.preview!)];
  }
}

List<MailMessage> sampleMail(DateTime now) => [
  MailMessage(
    id: 139,
    from: 'human:jose',
    to: 'pando@agentd',
    subject: '',
    body: 'Revisa el plan de colas antes de seguir.',
    state: MailState.read,
    createdAt: now.subtract(const Duration(hours: 1)),
  ),
  MailMessage(
    id: 142,
    from: 'claude@webapp',
    to: 'codex@api',
    subject: '',
    body: '¿Está lista la API de login con expiración?',
    state: MailState.replied,
    createdAt: now.subtract(const Duration(minutes: 12)),
  ),
  MailMessage(
    id: 143,
    from: 'codex@api',
    to: 'claude@webapp',
    subject: '',
    body: 'Sí, endpoint /v1/session con expires_at. Tests en verde.',
    state: MailState.read,
    createdAt: now.subtract(const Duration(minutes: 10)),
    replyTo: 142,
  ),
  MailMessage(
    id: 144,
    from: 'claude@pips',
    to: 'claude@agentd',
    subject: '',
    body: 'Mejorar agentd a partir de clientes de herdr de terceros…',
    state: MailState.queued,
    createdAt: now.subtract(const Duration(minutes: 2)),
  ),
  MailMessage(
    id: 145,
    from: 'human:jose',
    to: 'codex@api',
    subject: '',
    body: 'Cuando acabes, sube la rama.',
    state: MailState.queued,
    createdAt: now.subtract(const Duration(minutes: 1)),
  ),
  MailMessage(
    id: 148,
    from: 'codex@api',
    to: 'claude@webapp',
    subject: 'Ejecutar tests de integración',
    body: '',
    state: MailState.delivered,
    createdAt: now.subtract(const Duration(minutes: 25)),
    queue: 'tests',
  ),
  MailMessage(
    id: 151,
    from: 'codex@api',
    to: 'queue:review',
    subject: 'Revisar PR de expiración de tokens',
    body: '',
    state: MailState.unclaimed,
    createdAt: now.subtract(const Duration(minutes: 9)),
    queue: 'review',
  ),
  MailMessage(
    id: 152,
    from: 'codex@api',
    to: 'queue:review',
    subject: 'Revisar migración sessions',
    body: '',
    state: MailState.unclaimed,
    createdAt: now.subtract(const Duration(minutes: 8)),
    queue: 'review',
  ),
  MailMessage(
    id: 153,
    from: 'claude@docs',
    to: 'queue:review',
    subject: 'Revisar README',
    body: '',
    state: MailState.unclaimed,
    createdAt: now.subtract(const Duration(minutes: 5)),
    queue: 'review',
  ),
];

/// Boards of the sample hosts: the Panel mockup on the sample sessions.
Map<String, HostBoard> sampleBoards(DateTime now) => {
  'estudio': HostBoard(
    hostId: 'estudio',
    unreadHuman: 1,
    sessions: [
      BoardSession(
        hostId: 'estudio',
        name: 'pando@agentd',
        status: AgentStatus.working,
        turn: 3,
        preview: 'Leyendo internal/hcompat/server.go…',
        tasks: [
          AgentTask(id: 't1', title: 'Modelo de tareas y validación', status: TaskStatus.done, updatedAt: now.subtract(const Duration(minutes: 50))),
          AgentTask(id: 't2', title: 'Órdenes de la línea de comandos', status: TaskStatus.done, updatedAt: now.subtract(const Duration(minutes: 31))),
          AgentTask(id: 't3', title: 'Pruebas del modelo', status: TaskStatus.done, updatedAt: now.subtract(const Duration(minutes: 20))),
          AgentTask(id: 't4', title: 'Op board: resumen agregado por sesión', status: TaskStatus.inProgress, updatedAt: now.subtract(const Duration(minutes: 1))),
          AgentTask(id: 't5', title: 'Persistir tareas en SQLite', status: TaskStatus.inProgress, updatedAt: now.subtract(const Duration(minutes: 4))),
          const AgentTask(id: 't6', title: 'Eventos task.changed en el bus'),
          const AgentTask(id: 't7', title: 'Herramientas MCP para informar tareas'),
        ],
        questions: [
          AgentQuestion(
            id: 310,
            body:
                '¿Migro el esquema del buzón a v4 en este mismo cambio o lo separo en otro?\n\n'
                'Si va junto, el cambio toca también la purga y sus pruebas. Separado son dos revisiones pero cada una es pequeña.',
            options: const ['En este cambio', 'Cambio aparte'],
            taskId: 't5',
            createdAt: now.subtract(const Duration(minutes: 4)),
          ),
        ],
      ),
      BoardSession(
        hostId: 'estudio',
        name: 'claude@webapp',
        status: AgentStatus.waiting,
        attention: true,
        turn: 9,
        tasks: [
          AgentTask(id: 't1', title: 'Revisar enlaces rotos', status: TaskStatus.done, updatedAt: now.subtract(const Duration(minutes: 12))),
          AgentTask(id: 't2', title: 'Pasar las pruebas con -race', status: TaskStatus.inProgress, updatedAt: now.subtract(const Duration(minutes: 1))),
          const AgentTask(id: 't3', title: 'Actualizar el README'),
          const AgentTask(id: 't4', title: 'Abrir el PR'),
        ],
      ),
      const BoardSession(
        hostId: 'estudio',
        name: 'claude@docs',
        status: AgentStatus.idle,
        attention: true,
        turn: 5,
        preview: 'README actualizado con la sección de instalación',
      ),
    ],
    backlog: true,
    notes: [
      BacklogNote(
        id: 4,
        title: 'Probar el emparejado por QR en iOS',
        body: 'Con un iPhone real: permiso de cámara, QR de agentd relay invite y enlace pegado.',
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      BacklogNote(id: 3, title: 'Revisar los tiempos de reconexión del relay', createdAt: now.subtract(const Duration(days: 1)), updatedAt: now.subtract(const Duration(days: 1))),
      BacklogNote(
        id: 2,
        title: 'Documentar el formato de las notas',
        state: NoteState.assigned,
        assignedTo: 'claude@docs',
        taskId: 'n2',
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now.subtract(const Duration(hours: 5)),
        assignedAt: now.subtract(const Duration(hours: 5)),
      ),
      BacklogNote(
        id: 1,
        title: 'Borrar las ramas viejas',
        state: NoteState.done,
        assignedTo: 'pando@agentd',
        taskId: 'n1',
        createdAt: now.subtract(const Duration(days: 4)),
        updatedAt: now.subtract(const Duration(days: 3)),
        assignedAt: now.subtract(const Duration(days: 4)),
        doneAt: now.subtract(const Duration(days: 3)),
      ),
    ],
  ),
  'vps-hetzner': HostBoard(
    hostId: 'vps-hetzner',
    sessions: [
      BoardSession(
        hostId: 'vps-hetzner',
        name: 'codex@api',
        status: AgentStatus.waiting,
        attention: true,
        turn: 14,
        tasks: [
          for (final (i, t) in ['Esquema nuevo de orders', 'Script de copia', 'Índices', 'Pruebas de la migración', 'Plan de vuelta atrás'].indexed)
            AgentTask(id: 't${i + 1}', title: t, status: TaskStatus.done, updatedAt: now.subtract(Duration(minutes: 30 - i))),
          AgentTask(id: 't6', title: 'Migración de la tabla orders', status: TaskStatus.inProgress, updatedAt: now.subtract(const Duration(minutes: 3))),
        ],
      ),
      BoardSession(
        hostId: 'vps-hetzner',
        name: 'codex@webapp',
        status: AgentStatus.idle,
        turn: 2,
        preview: 'Tests en verde, sin cambios pendientes',
        tasks: [
          AgentTask(id: 't1', title: 'Tests en verde', status: TaskStatus.done, updatedAt: now.subtract(const Duration(minutes: 45))),
          AgentTask(
            id: 't2',
            title: 'Desplegar en staging',
            status: TaskStatus.blocked,
            note: 'Falta la credencial del registro de contenedores',
            updatedAt: now.subtract(const Duration(minutes: 40)),
          ),
          const AgentTask(id: 't3', title: 'Avisar al equipo', status: TaskStatus.cancelled),
        ],
      ),
    ],
  ),
};

/// Canned screen of the terminal mockup (ANSI, CRLF line ends).
const sampleTerminalScreen =
    '\x1b[97m● Bash(go test ./internal/... -race)\x1b[0m\r\n'
    '  \x1b[90m⎿  ok  internal/session   3.912s\x1b[0m\r\n'
    '  \x1b[90m   ok  internal/daemon    8.104s\x1b[0m\r\n'
    '  \x1b[90m   ok  internal/hcompat   5.633s\x1b[0m\r\n'
    '\r\n'
    '\x1b[97m● Update(internal/daemon/env.go)\x1b[0m\r\n'
    '  \x1b[90m⎿  Updated with 9 additions\x1b[0m\r\n'
    '     \x1b[32m+ env = append(env, "HC_TERMINAL_ID="+name)\x1b[0m\r\n'
    '     \x1b[32m+ env = append(env, "HC_SESSION="+hc.Session)\x1b[0m\r\n'
    '\r\n'
    '\x1b[35m✳ Revisando la entrada del hijo… (38s · esc para interrumpir)\x1b[0m\r\n'
    '\r\n'
    '\x1b[90m────────────────────────────────────────\x1b[0m\r\n'
    '\x1b[97m❯ \x1b[0m';

/// agentd aliases of the sample hosts (op info), offered as projects.
const sampleAliases = <String, List<String>>{
  'estudio': ['webapp', 'api', 'agentd', 'docs', 'pips'],
  'vps-hetzner': ['api', 'webapp'],
};
