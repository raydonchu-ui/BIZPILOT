import { useCallback, useState } from 'react';
import { useI18n } from '../i18n';
import { errorMessage } from './errors';
import { useToast } from './toast';
import { queryClient } from './api';

/** Runs a mutation, refreshes cached data, and reports success/failure to the user. */
export function useAction() {
  const toast = useToast();
  const { t, has } = useI18n();
  const [busy, setBusy] = useState(false);
  const run = useCallback(async <T,>(fn: () => Promise<T>, success?: string): Promise<T | undefined> => {
    setBusy(true);
    try {
      const r = await fn();
      if (success) toast(success, 'success');
      await queryClient.invalidateQueries();
      return r;
    } catch (e: any) {
      const msg = e?.message === 'file_too_large' ? t('files.tooLarge') : e?.message === 'file_type_not_allowed' ? t('files.typeNotAllowed') : errorMessage(e, t, has);
      toast(msg, 'error');
      return undefined;
    } finally {
      setBusy(false);
    }
  }, [toast, t, has]);
  return { run, busy };
}
