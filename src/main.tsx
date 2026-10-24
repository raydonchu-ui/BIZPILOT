import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClientProvider } from '@tanstack/react-query';
import { App } from './App';
import { queryClient } from './lib/api';
import { I18nProvider } from './i18n';
import { AuthProvider } from './lib/auth';
import { ToastProvider } from './lib/toast';
import { applyTheme, getTheme } from './lib/theme';
import './index.css';

applyTheme(getTheme());

// After a deployment, an open tab may ask for a code file of the previous version that no
// longer exists. Reload once to pick up the current version (at most once every 30 seconds).
window.addEventListener('vite:preloadError', (e) => {
  try {
    const last = Number(sessionStorage.getItem('bp-chunk-reload') ?? 0);
    if (Date.now() - last < 30_000) return;
    sessionStorage.setItem('bp-chunk-reload', String(Date.now()));
  } catch { /* storage unavailable: still reload */ }
  e.preventDefault();
  window.location.reload();
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <QueryClientProvider client={queryClient}>
        <I18nProvider>
          <ToastProvider>
            <AuthProvider>
              <App />
            </AuthProvider>
          </ToastProvider>
        </I18nProvider>
      </QueryClientProvider>
    </BrowserRouter>
  </React.StrictMode>,
);
