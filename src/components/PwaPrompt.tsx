import { useEffect, useState } from 'react';
import { useRegisterSW } from 'virtual:pwa-register/react';
import { RefreshCw } from 'lucide-react';
import { useI18n } from '../i18n';
import { Button } from './ui';

// Pages that can always reload safely (nothing typed into the app is lost there).
const isPublicPage = () => !/^\/(app|admin|onboarding)(\/|$)/.test(window.location.pathname);

// When a new version is deployed its service worker takes control right away (skipWaiting).
// Public, login and sign-up pages then reload themselves so visitors never use an outdated
// sign-in; inside the app we only offer a reload, so a sale being entered is never interrupted.
export function PwaPrompt() {
  const { t } = useI18n();
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW();
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
