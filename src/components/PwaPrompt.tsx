import { useEffect, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useRegisterSW } from 'virtual:pwa-register/react';
import { RefreshCw } from 'lucide-react';
import { useI18n } from '../i18n';
import { Button } from './ui';

// Pages that can always reload safely (nothing typed into the app is lost there).
const isPublicPage = () => !/^\/(app|admin|onboarding)(\/|$)/.test(window.location.pathname);

// When a new version is deployed its service worker takes control right away (skipWaiting).
// Public, login and sign-up pages reload at once. Inside the app the new version is applied at the next
// safe moment: when the user switches to another tab or app, or moves to another page. A banner is the
// fallback if neither happens. A sale being typed is not interrupted while the user is looking at it.
// Devices also check for a new version every 30 minutes and when the app comes back into view.
const CHECK_EVERY_MS = 30 * 60_000;

export function PwaPrompt() {
  const { t } = useI18n();
  const location = useLocation();
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return;
      window.setInterval(() => { registration.update().catch(() => undefined); }, CHECK_EVERY_MS);
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') registration.update().catch(() => undefined);
      });
    },
  });
  const [updated, setUpdated] = useState(false);
  useEffect(() => {
    const sw = navigator.serviceWorker;
    if (!sw) return;
    const hadController = Boolean(sw.controller); // false on the very first install: nothing to refresh
    const onChange = () => {
      if (!hadController) return;
      if (isPublicPage()) window.location.reload(); else setUpdated(true);
    };
    sw.addEventListener('controllerchange', onChange);
    return () => sw.removeEventListener('controllerchange', onChange);
  }, []);
  // Inside the app, the waiting update is applied when the user leaves the tab (it is not being looked at)...
  useEffect(() => {
    if (!updated) return;
    const onHide = () => { if (document.visibilityState === 'hidden') window.location.reload(); };
    document.addEventListener('visibilitychange', onHide);
    return () => document.removeEventListener('visibilitychange', onHide);
  }, [updated]);
  // ...or when they move to another page, which is the point where unsaved input has already been left.
  useEffect(() => { if (updated) window.location.reload(); }, [location.pathname]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (needRefresh && isPublicPage()) updateServiceWorker(true); }, [needRefresh, updateServiceWorker]);
  if (!needRefresh && !updated) return null;
  const reload = () => (updated ? window.location.reload() : updateServiceWorker(true));
  return (
    <div className="fixed inset-x-4 bottom-24 z-[95] mx-auto flex max-w-md items-center gap-3 rounded-xl bg-gray-900 px-4 py-3 text-sm text-white shadow-xl lg:bottom-6">
      <RefreshCw className="h-4 w-4 shrink-0" />
      <span className="flex-1">{t('offline.updateAvailable')}</span>
      <Button size="sm" onClick={reload}>{t('offline.reload')}</Button>
      <button className="text-xs text-gray-300" onClick={() => { setNeedRefresh(false); setUpdated(false); }}>{t('common.close')}</button>
    </div>
  );
}
