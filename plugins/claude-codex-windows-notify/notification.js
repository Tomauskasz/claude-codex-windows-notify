import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const completedAt = new Map();
const sessionTitles = new Map();
const childSessions = new Set();
const pluginRoot = path.dirname(fileURLToPath(import.meta.url));
const notifyCandidates = [
  path.join(pluginRoot, 'scripts', 'notify.ps1'),
  path.join(
    os.homedir(),
    '.codex',
    'plugins',
    'cache',
    'claude-codex-windows-notify',
    'claude-codex-windows-notify',
    '0.5.2',
    'scripts',
    'notify.ps1'
  ),
];

function resolveNotifyScript() {
  for (const candidate of notifyCandidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return notifyCandidates[0];
}

function spawnNotify(event, hookData) {
  const notifyScript = resolveNotifyScript();
  if (!fs.existsSync(notifyScript)) {
    console.error(`Notification plugin missing notify script: ${notifyScript}`);
    return;
  }

  const tempFile = path.join(os.tmpdir(), `notify-${Date.now()}-${Math.random().toString(16).slice(2)}.json`);
  fs.writeFileSync(tempFile, JSON.stringify(hookData));
  const fd = fs.openSync(tempFile, 'r');
  const ps = spawn('powershell.exe', [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', notifyScript,
    '-Event', event,
    '-ProductName', 'OpenCode'
  ], {
    stdio: [fd, 'ignore', 'ignore'],
    windowsHide: true
  });
  ps.unref();
  setTimeout(() => {
    try {
      fs.closeSync(fd);
      fs.unlinkSync(tempFile);
    } catch {}
  }, 5000);
}

export const NotificationPlugin = async () => {
  return {
    event: async ({ event }) => {
      try {
        const info = event.properties?.info;
        const sessionId = event.properties?.sessionID || info?.id;
        if (!sessionId) return;

        if (event.type === 'session.updated' || event.type === 'session.created') {
          if (info?.parentID) childSessions.add(sessionId);
          const title = info?.title;
          if (typeof title === 'string' && title.trim()) sessionTitles.set(sessionId, title.trim());
          return;
        }

        if (event.type === 'session.deleted') {
          sessionTitles.delete(sessionId);
          childSessions.delete(sessionId);
          completedAt.delete(sessionId);
          return;
        }

        if (event.type !== 'session.idle') return;
        if (childSessions.has(sessionId)) return;

        const now = Date.now();
        if (now - (completedAt.get(sessionId) || 0) < 10_000) return;
        completedAt.set(sessionId, now);

        spawnNotify('TurnComplete', {
          hook_event_name: 'Stop',
          session_id: sessionId,
          session_name: sessionTitles.get(sessionId) || sessionId,
          cwd: info?.directory || process.cwd(),
          last_assistant_message: 'OpenCode session finished.'
        });
      } catch (error) {
        console.error('Notification plugin error:', error.message);
      }
    }
  };
};
