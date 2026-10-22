import { useRegisterSW } from 'virtual:pwa-register/react';
import { RefreshCw } from 'lucide-react';
import { useI18n } from '../i18n';
import { Button } from './ui';

export function PwaPrompt() {
  const { t } = useI18n();
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW();
  if (!needRefresh) return null;
  return (
    <div className="fixed inset-x-4 bottom-24 z-[95] mx-auto flex max-w-md items-center gap-3 rounded-xl bg-gray-900 px-4 py-3 text-sm text-white shadow-xl lg:bottom-6">
      <RefreshCw className="h-4 w-4 shrink-0" />
      <span className="flex-1">{t('offline.updateAvailable')}</span>
      <Button size="sm" onClick={() => updateServiceWorker(true)}>{t('offline.reload')}</Button>
      <button className="text-xs text-gray-300" onClick={() => setNeedRefresh(false)}>{t('common.close')}</button>
    </div>
  );
}
