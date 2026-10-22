export type Theme = 'light' | 'dark' | 'system';
const KEY = 'bizpilot.theme';

export function getTheme(): Theme {
  try {
    const t = localStorage.getItem(KEY);
    if (t === 'light' || t === 'dark' || t === 'system') return t;
  } catch { /* ignore */ }
  return 'light';
}

export function applyTheme(t: Theme) {
  try { localStorage.setItem(KEY, t); } catch { /* ignore */ }
  const dark = t === 'dark' || (t === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', dark);
}
