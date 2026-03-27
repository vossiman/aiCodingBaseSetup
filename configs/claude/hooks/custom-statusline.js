#!/usr/bin/env node
// Custom Powerline Statusline for Claude Code
// Two-line rainbow powerline with pipe-style bars

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

// Powerline arrow character
const PL = '\ue0b0';

// Color palette (R;G;B)
const COLORS = {
  violet:  '139;92;246',
  pink:    '236;72;153',
  orange:  '249;115;22',
  yellow:  '234;179;8',
  green:   '34;197;94',
  cyan:    '6;182;212',
  blue:    '59;130;246',
  indigo:  '99;102;241',
  purple:  '168;85;247',
  red:     '220;38;38',
  white:   '255;255;255',
  black:   '30;30;30',
};

function fg(color) { return `\x1b[38;2;${color}m`; }
function bg(color) { return `\x1b[48;2;${color}m`; }
const RESET = '\x1b[0m';

// Build a pipe-style bar: ▮▮▮▮▮▯▯▯▯▯
function pipeBar(pct, width = 10) {
  const filled = Math.round(pct / (100 / width));
  return '\u25ae'.repeat(filled) + '\u25af'.repeat(width - filled);
}

// Build a powerline string from an array of { bg, fg, text } segments
function renderPowerline(segments) {
  if (segments.length === 0) return '';
  let out = '';
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    if (i > 0) {
      out += fg(segments[i - 1].bg) + bg(seg.bg) + PL;
    }
    out += fg(seg.fg) + bg(seg.bg) + ` ${seg.text} `;
  }
  out += RESET + fg(segments[segments.length - 1].bg) + PL + RESET;
  return out;
}

// Read JSON from stdin
let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = data.model?.display_name || 'Claude';
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const sessionName = data.session_name || '';
    const remaining = data.context_window?.remaining_percentage;
    const version = data.version || '';
    const agentName = data.agent?.name || '';
    const rateFiveHour = data.rate_limits?.five_hour?.used_percentage;
    const rateSevenDay = data.rate_limits?.seven_day?.used_percentage;

    // --- Context window calculation ---
    const AUTO_COMPACT_BUFFER_PCT = 16.5;
    let ctxUsed = null;
    if (remaining != null) {
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      ctxUsed = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

      // Write context bridge file for context-monitor hook
      if (session) {
        try {
          const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
          fs.writeFileSync(bridgePath, JSON.stringify({
            session_id: session,
            remaining_percentage: remaining,
            used_pct: ctxUsed,
            timestamp: Math.floor(Date.now() / 1000)
          }));
        } catch (e) { /* silent */ }
      }
    }

    // --- Git branch ---
    let branch = '';
    try {
      branch = execSync('git rev-parse --abbrev-ref HEAD', {
        cwd: dir, timeout: 1000, stdio: ['pipe', 'pipe', 'pipe']
      }).toString().trim();
    } catch (e) { /* not a git repo */ }

    // --- GSD task (conditional) ---
    let gsdTask = '';
    const homeDir = os.homedir();
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const todosDir = path.join(claudeDir, 'todos');
    if (session && fs.existsSync(todosDir)) {
      try {
        const files = fs.readdirSync(todosDir)
          .filter(f => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
          .sort((a, b) => b.mtime - a.mtime);
        if (files.length > 0) {
          try {
            const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
            const inProgress = todos.find(t => t.status === 'in_progress');
            if (inProgress) gsdTask = inProgress.activeForm || '';
          } catch (e) {}
        }
      } catch (e) {}
    }

    // --- GSD update notice (conditional) ---
    let gsdUpdateAvailable = false;
    let gsdStaleHooks = false;
    const cacheFile = path.join(claudeDir, 'cache', 'gsd-update-check.json');
    if (fs.existsSync(cacheFile)) {
      try {
        const cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
        if (cache.update_available) gsdUpdateAvailable = true;
        if (cache.stale_hooks && cache.stale_hooks.length > 0) gsdStaleHooks = true;
      } catch (e) {}
    }

    // === LINE 1: Identity & navigation ===
    const line1 = [];

    // Model (violet)
    line1.push({ bg: COLORS.violet, fg: COLORS.white, text: model });

    // Session name (pink, conditional)
    if (sessionName) {
      line1.push({ bg: COLORS.pink, fg: COLORS.white, text: sessionName });
    }

    // Directory (orange)
    const dirname = path.basename(dir);
    line1.push({ bg: COLORS.orange, fg: COLORS.white, text: `\uf07b ${dirname}` });

    // Git branch (yellow, conditional)
    if (branch) {
      line1.push({ bg: COLORS.yellow, fg: COLORS.black, text: `\ue0a0 ${branch}` });
    }

    // Agent (purple, conditional)
    if (agentName) {
      line1.push({ bg: COLORS.purple, fg: COLORS.white, text: `\u26a1${agentName}` });
    }

    // GSD update notice (conditional)
    if (gsdUpdateAvailable) {
      line1.push({ bg: COLORS.pink, fg: COLORS.white, text: '\u2b06 /gsd:update' });
    } else if (gsdStaleHooks) {
      line1.push({ bg: COLORS.red, fg: COLORS.white, text: '\u26a0 stale hooks' });
    }

    // GSD task (conditional)
    if (gsdTask) {
      const maxLen = 30;
      const taskText = gsdTask.length > maxLen ? gsdTask.substring(0, maxLen - 1) + '\u2026' : gsdTask;
      line1.push({ bg: COLORS.purple, fg: COLORS.white, text: taskText });
    }

    // Version (indigo)
    if (version) {
      line1.push({ bg: COLORS.indigo, fg: COLORS.white, text: `v${version}` });
    }

    // === LINE 2: Meters ===
    const line2 = [];

    // Context bar (green → yellow → orange → red based on usage)
    if (ctxUsed != null) {
      let ctxBg = COLORS.green;
      let ctxFg = COLORS.white;
      let prefix = 'ctx';
      if (ctxUsed >= 80) {
        ctxBg = COLORS.red;
        prefix = '\ud83d\udc80 ctx';
      } else if (ctxUsed >= 65) {
        ctxBg = COLORS.orange;
      } else if (ctxUsed >= 50) {
        ctxBg = COLORS.yellow;
        ctxFg = COLORS.black;
      }
      line2.push({ bg: ctxBg, fg: ctxFg, text: `${prefix} ${pipeBar(ctxUsed)} ${ctxUsed}%` });
    }

    // 5h rate limit (cyan)
    if (rateFiveHour != null) {
      const pct = Math.round(rateFiveHour);
      line2.push({ bg: COLORS.cyan, fg: COLORS.white, text: `5h ${pipeBar(pct)} ${pct}%` });
    }

    // 7d rate limit (blue)
    if (rateSevenDay != null) {
      const pct = Math.round(rateSevenDay);
      line2.push({ bg: COLORS.blue, fg: COLORS.white, text: `7d ${pipeBar(pct)} ${pct}%` });
    }

    // Render both lines
    let output = renderPowerline(line1);
    if (line2.length > 0) {
      output += '\n' + renderPowerline(line2);
    }
    process.stdout.write(output);
  } catch (e) {
    // Silent fail - don't break statusline on parse errors
  }
});
