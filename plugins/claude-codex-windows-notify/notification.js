import { spawn } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const completedAt = new Map();
const notifyScript = path.join(path.dirname(fileURLToPath(import.meta.url)), 'scripts', 'notify.ps1');

export const NotificationPlugin = async (pluginArgs) => {

  return {
    event: async ({ event }) => {
      try {
        if (event.type !== 'session.idle') return;

        const cwd = pluginArgs.directory || pluginArgs.project || process.cwd();
        const sessionId = event.properties?.sessionID || path.basename(cwd);
        const now = Date.now();
        if (now - (completedAt.get(sessionId) || 0) < 10_000) return;
        completedAt.set(sessionId, now);

        const tempFile = path.join(os.tmpdir(), `notify-${Date.now()}.json`);
        fs.writeFileSync(tempFile, JSON.stringify({
          hook_event_name: 'Stop',
          session_id: sessionId,
          cwd,
          last_assistant_message: 'OpenCode session finished.'
        }));

        const fd = fs.openSync(tempFile, 'r');
        const ps = spawn('powershell.exe', [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy', 'Bypass',
          '-File', notifyScript,
          '-Event', 'TurnComplete',
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
      } catch (error) {
        console.error('Notification plugin error:', error.message);
      }
    }
  };
};
